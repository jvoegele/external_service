defmodule ExternalService.TestingGuideExamplesTest do
  @moduledoc """
  The examples from `guides/testing.md`, kept executable.

  The Testing guide is the one guide whose whole value is that its examples
  actually run — an adopter copies them into their own suite. Keeping them here
  means a change to the public API breaks this file rather than silently rotting
  the guide.

  When you change an example here, change it in the guide too, and vice versa.
  """

  use ExUnit.Case, async: true
  use ExternalService.Test

  alias ExternalService.CircuitBreaker
  alias ExternalService.CircuitBreakerOpen
  alias ExternalService.RateLimited
  alias ExternalService.RateLimiter
  alias ExternalService.RetriesExhausted

  # Every test gets its own service term, so nothing here shares a breaker or a
  # rate-limit bucket with anything else. This is the guide's central point about
  # `async: true`.
  setup :record_events

  setup context do
    service = :"#{context.module}.#{context.test}"
    on_exit(fn -> ExternalService.stop(service) end)
    {:ok, service: service}
  end

  describe "making a service deterministic" do
    test "retries take no real time with base: 0", %{service: service} do
      ExternalService.start(service,
        circuit_breaker: [tolerate: 100, within: :timer.seconds(10)],
        retry: [max_attempts: 3, backoff: :linear, base: 0]
      )

      {elapsed, result} =
        :timer.tc(fn ->
          ExternalService.call(service, fn -> :retry end)
        end)

      assert {:error, %RetriesExhausted{}} = result

      # Generous on purpose. What this separates is "the backoff was removed" from
      # "production backoff is still on" — an HTTP service's 1.5s retry window,
      # not a millisecond of scheduling. A tight bound here measures the machine:
      # at 50ms this failed on a loaded CI runner at 68ms, with nothing wrong.
      assert elapsed < 500_000
    end

    test "a sleep function records the real backoff without waiting for it",
         %{service: service} do
      ExternalService.start(service,
        circuit_breaker: [tolerate: 100],
        retry: [max_attempts: 4, backoff: :exponential, base: 100],
        sleep_function: recording_sleep()
      )

      ExternalService.call(service, fn -> :retry end)

      assert_slept([100, 200, 400])
    end

    test "wait: false keeps a rate limited test off the clock", %{service: service} do
      ExternalService.start(service,
        retry: [max_attempts: 1],
        rate_limit: [limit: 1, per: :timer.minutes(1), wait: false]
      )

      assert ExternalService.call(service, fn -> :first end) == :first

      # The second call is throttled. `wait: false` turns that into an immediate
      # error instead of a wait, so the test never touches the clock.
      {elapsed, result} =
        :timer.tc(fn -> ExternalService.call(service, fn -> flunk("should not run") end) end)

      assert {:error, %RateLimited{}} = result

      # Loose for the same reason as above: this separates "returned immediately"
      # from "waited for the window", and the window here is a minute.
      assert elapsed < 500_000
    end

    test "a no-op :sleep_function does NOT skip the wait — it busy-waits", %{service: service} do
      # This is the trap. `sleep_function: fn _ -> :ok end` looks like it makes
      # throttled calls instant. It does not: the limiter is asked again
      # immediately, still says wait, and the loop spins until real time has
      # passed. The call takes just as long and burns a core doing it.
      {:ok, spy} = Agent.start_link(fn -> 0 end)

      ExternalService.start(service,
        retry: [max_attempts: 1],
        rate_limit: [limit: 1, per: 100, wait: :infinity],
        sleep_function: fn _ms -> Agent.update(spy, &(&1 + 1)) end
      )

      ExternalService.call(service, fn -> :first end)
      {elapsed, :second} = :timer.tc(fn -> ExternalService.call(service, fn -> :second end) end)

      # Still waited out the window in real time...
      assert elapsed >= 50_000

      # ...having called the no-op sleep function over and over to do it. The
      # bound is deliberately far below what any real spin produces: the count
      # is a function of how fast the machine spins, not of the behavior under
      # test, and a contended runner has measured as low as 453. What separates
      # busy-waiting from a sleep that actually sleeps is re-entering the loop
      # at all, not the rate.
      assert Agent.get(spy, & &1) > 50
    end
  end

  describe "forcing failure paths" do
    test "melt/1 opens the breaker without needing a failing call", %{service: service} do
      ExternalService.start(service,
        circuit_breaker: [tolerate: 2, within: :timer.seconds(10)],
        retry: [max_attempts: 1]
      )

      assert ExternalService.available?(service)

      # Melts `:tolerate` + 1 times: `:tolerate` melts are tolerated, and the
      # next one opens the breaker.
      trip_breaker(service)

      assert ExternalService.blown?(service)

      assert {:error, %CircuitBreakerOpen{}} =
               ExternalService.call(service, fn -> flunk("should not have run") end)
    end

    test "reset/1 closes it again", %{service: service} do
      ExternalService.start(service,
        circuit_breaker: [tolerate: 1, within: :timer.seconds(10)],
        retry: [max_attempts: 1]
      )

      Enum.each(1..2, fn _ -> CircuitBreaker.melt(service) end)
      assert ExternalService.blown?(service)

      ExternalService.reset(service)

      assert ExternalService.available?(service)
      assert ExternalService.call(service, fn -> :ok end) == :ok
    end

    test "wait: false makes RateLimited reachable", %{service: service} do
      ExternalService.start(service,
        retry: [max_attempts: 1],
        rate_limit: [limit: 1, per: :timer.minutes(1), wait: false]
      )

      assert ExternalService.call(service, fn -> :admitted end) == :admitted

      assert {:error, %RateLimited{context: %{retry_after: retry_after}}} =
               ExternalService.call(service, fn -> flunk("should not have run") end)

      assert is_integer(retry_after)
    end

    test "request/1 spends the budget without running anything", %{service: service} do
      ExternalService.start(service,
        retry: [max_attempts: 1],
        rate_limit: [limit: 2, per: :timer.minutes(1), wait: false]
      )

      # Put the service right at its limit before the code under test runs.
      exhaust_rate_limit(service)

      assert {:error, %RateLimited{}} =
               ExternalService.call(service, fn -> flunk("should not have run") end)
    end

    test "fault_injection fails a fraction of calls", %{service: service} do
      ExternalService.start(service,
        circuit_breaker: [tolerate: 100, within: :timer.seconds(10), fault_injection: 1.0],
        retry: [max_attempts: 1]
      )

      assert {:error, %CircuitBreakerOpen{}} =
               ExternalService.call(service, fn -> flunk("should not have run") end)
    end
  end

  describe "asserting on telemetry" do
    test "a retry emits [:external_service, :call, :retry]", %{service: service} do
      ExternalService.start(service,
        circuit_breaker: [tolerate: 100, within: :timer.seconds(10)],
        retry: [max_attempts: 2, backoff: :linear, base: 0]
      )

      ExternalService.call(service, fn -> {:retry, :service_unavailable} end)

      assert_retried(service, reason: :service_unavailable)
    end

    test "the metadata comes back for further assertions", %{service: service} do
      ExternalService.start(service,
        circuit_breaker: [tolerate: 100, within: :timer.seconds(10)],
        retry: [max_attempts: 2, backoff: :linear, base: 0]
      )

      ExternalService.call(service, fn -> {:retry, :service_unavailable} end)

      metadata = assert_retried(service)
      assert metadata.reason == :service_unavailable
    end
  end

  describe "resetting shared state between tests" do
    test "reset_all/1 clears the breaker and the rate limit budget", %{service: service} do
      ExternalService.start(service,
        circuit_breaker: [tolerate: 1, within: :timer.seconds(10)],
        rate_limit: [limit: 1, per: :timer.minutes(1), wait: false],
        retry: [max_attempts: 1]
      )

      # Leave the service in the state a messy test would leave it in.
      Enum.each(1..2, fn _ -> CircuitBreaker.melt(service) end)
      assert RateLimiter.request(service) == :ok

      assert ExternalService.blown?(service)
      assert ExternalService.rate_limited?(service)

      assert ExternalService.reset_all(service) == :ok

      assert ExternalService.available?(service)
      refute ExternalService.rate_limited?(service)
    end

    test "reset/1 deliberately leaves the rate limiter alone", %{service: service} do
      ExternalService.start(service,
        circuit_breaker: [tolerate: 1, within: :timer.seconds(10)],
        rate_limit: [limit: 1, per: :timer.minutes(1), wait: false],
        retry: [max_attempts: 1]
      )

      assert RateLimiter.request(service) == :ok
      assert ExternalService.rate_limited?(service)

      assert ExternalService.reset(service) == :ok

      # Still throttled — which is why a test setup wants reset_all/1.
      assert ExternalService.rate_limited?(service)
    end
  end

  describe "making a service inert" do
    test "the three :infinity/1 keys leave nothing that can interfere", %{service: service} do
      ExternalService.start(service,
        circuit_breaker: [tolerate: :infinity],
        rate_limit: [limit: :infinity, per: :timer.seconds(1)],
        retry: [max_attempts: 1]
      )

      # Neither mechanism accumulates anything, so no volume of calls or melts
      # changes what the next test sees.
      for n <- 1..200 do
        assert ExternalService.call(service, fn -> n end) == n
      end

      Enum.each(1..200, fn _ -> CircuitBreaker.melt(service) end)

      assert ExternalService.available?(service)
      refute ExternalService.rate_limited?(service)
    end

    test "one attempt turns a :retry return into RetriesExhausted", %{service: service} do
      ExternalService.start(service,
        circuit_breaker: [tolerate: :infinity],
        retry: [max_attempts: 1]
      )

      # The guarded call is inert, not transparent: the :retry sentinel belongs
      # to the library and does not reach the caller.
      assert {:error, %RetriesExhausted{}} = ExternalService.call(service, fn -> :retry end)
    end
  end

  describe "shared service state" do
    test "a service term is global, so two names are two independent breakers" do
      one = :"#{__MODULE__}.independent_one"
      two = :"#{__MODULE__}.independent_two"

      on_exit(fn ->
        ExternalService.stop(one)
        ExternalService.stop(two)
      end)

      for service <- [one, two] do
        ExternalService.start(service,
          circuit_breaker: [tolerate: 1, within: :timer.seconds(10)],
          retry: [max_attempts: 1]
        )
      end

      Enum.each(1..2, fn _ -> CircuitBreaker.melt(one) end)

      assert ExternalService.blown?(one)
      refute ExternalService.blown?(two)
    end

    test "a front door module's service name is fixed at compile time" do
      defmodule FixedNameService do
        use ExternalService,
          name: :"#{__MODULE__}.fixed",
          circuit_breaker: [tolerate: 1, within: :timer.seconds(10)],
          retry: [max_attempts: 1]
      end

      on_exit(fn -> ExternalService.stop(:"#{FixedNameService}.fixed") end)

      # Child spec overrides tune everything else, but `:name` is not a start/2
      # option at all -- it is consumed by the `use` macro -- so trying to
      # override it per test is rejected rather than silently ignored. The start
      # happens inside the generated Agent, so the failure arrives as an exit.
      Process.flag(:trap_exit, true)

      assert {:error, {%NimbleOptions.ValidationError{message: message}, _stacktrace}} =
               FixedNameService.start_link(name: :some_other_name)

      assert message =~ "unknown options [:name]"
    end

    test "stop/1 is idempotent, so on_exit teardown is always safe" do
      service = :"#{__MODULE__}.never_started"
      assert ExternalService.stop(service) == :ok
      assert ExternalService.stop(service) == :ok
    end
  end
end
