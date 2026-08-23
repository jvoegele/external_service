defmodule ExternalService.TestHelpersTest do
  # Deliberately async: the point of `record_events/0` generating a per-process
  # handler ID is that these are safe to run concurrently.
  use ExUnit.Case, async: true
  use ExternalService.Test

  alias ExternalService.CircuitBreakerOpen
  alias ExternalService.RateLimited

  setup :record_events

  setup context do
    service = {__MODULE__, context.test}
    on_exit(fn -> ExternalService.stop(service) end)
    %{service: service}
  end

  describe "trip_breaker/1" do
    test "opens the breaker without a failing call", %{service: service} do
      start(service, circuit_breaker: [tolerate: 2, within: :timer.seconds(10)])

      refute ExternalService.blown?(service)
      assert trip_breaker(service) == service
      assert ExternalService.blown?(service)

      assert {:error, %CircuitBreakerOpen{}} =
               ExternalService.call(service, fn -> flunk("should not run") end)
    end

    test "reads :tolerate off the service rather than assuming one", %{service: service} do
      start(service, circuit_breaker: [tolerate: 25, within: :timer.seconds(10)])

      trip_breaker(service)

      assert ExternalService.blown?(service)
    end

    test "melts exactly one more than :tolerate", %{service: service} do
      # The off-by-one is the whole reason this helper exists, so pin it from
      # both sides: `:tolerate` melts leave it closed, and one more opens it.
      start(service, circuit_breaker: [tolerate: 3, within: :timer.seconds(10)])

      Enum.each(1..3, fn _ -> ExternalService.CircuitBreaker.melt(service) end)
      refute ExternalService.blown?(service)

      ExternalService.reset(service)
      trip_breaker(service)
      assert ExternalService.blown?(service)
    end

    test "counts the same under melt: :per_attempt", %{service: service} do
      # Melting is direct, so the attempt-based melt mode changes nothing here.
      start(service,
        circuit_breaker: [tolerate: 12, melt: :per_attempt],
        retry: [max_attempts: 3, base: 0]
      )

      trip_breaker(service)

      assert ExternalService.blown?(service)
    end

    test "raises for a service with no breaker to open", %{service: service} do
      start(service, circuit_breaker: [tolerate: :infinity])

      assert_raise ArgumentError, ~r/tolerate: :infinity.*nothing to open/s, fn ->
        trip_breaker(service)
      end
    end

    test "raises for a service that was never started" do
      assert_raise ArgumentError, ~r/has not been started/, fn ->
        trip_breaker(:never_started_breaker)
      end
    end
  end

  describe "exhaust_rate_limit/1" do
    test "spends the budget so the next call is throttled", %{service: service} do
      start(service,
        rate_limit: [limit: 3, per: :timer.minutes(1), wait: false],
        circuit_breaker: [tolerate: 100, within: :timer.seconds(10)],
        retry: [max_attempts: 1]
      )

      assert exhaust_rate_limit(service) == service

      assert {:error, %RateLimited{}} =
               ExternalService.call(service, fn -> flunk("should not run") end)
    end

    test "spends exactly :limit, leaving the budget available up to that point", %{
      service: service
    } do
      start(service,
        rate_limit: [limit: 2, per: :timer.minutes(1), wait: false],
        circuit_breaker: [tolerate: 100, within: :timer.seconds(10)],
        retry: [max_attempts: 1]
      )

      assert ExternalService.call(service, fn -> :first end) == :first
      assert ExternalService.call(service, fn -> :second end) == :second

      assert {:error, %RateLimited{}} =
               ExternalService.call(service, fn -> flunk("should not run") end)
    end

    test "raises for a service started without a rate limit", %{service: service} do
      start(service, circuit_breaker: [tolerate: 5, within: :timer.seconds(10)])

      assert_raise ArgumentError, ~r/without a `:rate_limit`/, fn ->
        exhaust_rate_limit(service)
      end
    end

    test "raises for a service that was never started" do
      assert_raise ArgumentError, ~r/has not been started/, fn ->
        exhaust_rate_limit(:never_started_limiter)
      end
    end
  end

  describe "assert_retried/2 and refute_retried/2" do
    setup %{service: service} do
      start(service,
        circuit_breaker: [tolerate: 100, within: :timer.seconds(10)],
        retry: [max_attempts: 3, base: 0]
      )

      :ok
    end

    test "sees a retry that the return value cannot show", %{service: service} do
      # This call succeeds, so its return value is identical to one that never
      # retried. The event is the only difference.
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      result =
        ExternalService.call(service, fn ->
          case Agent.get_and_update(counter, &{&1, &1 + 1}) do
            0 -> {:retry, :service_unavailable}
            _ -> :recovered
          end
        end)

      assert result == :recovered
      assert_retried(service)
    end

    test "matches on metadata and returns it", %{service: service} do
      ExternalService.call(service, fn -> {:retry, :service_unavailable} end)

      metadata = assert_retried(service, reason: :service_unavailable)

      assert metadata.service == service
      assert metadata.reason == :service_unavailable
    end

    test "matches a Regex against the string form of a field", %{service: service} do
      ExternalService.call(service, fn -> {:retry, :service_unavailable} end)

      assert_retried(service, reason: ~r/unavailable/)
    end

    test "fails when the expectation does not match", %{service: service} do
      ExternalService.call(service, fn -> {:retry, :service_unavailable} end)

      assert_raise ExUnit.AssertionError, ~r/expected a retry for/, fn ->
        assert_retried(service, reason: :something_else)
      end
    end

    test "fails when a named field is absent from the metadata", %{service: service} do
      ExternalService.call(service, fn -> {:retry, :service_unavailable} end)

      assert_raise ExUnit.AssertionError, ~r/expected a retry for/, fn ->
        assert_retried(service, no_such_field: :anything)
      end
    end

    test "refute_retried passes for a call that succeeded first time", %{service: service} do
      assert ExternalService.call(service, fn -> :fine end) == :fine

      assert refute_retried(service) == :ok
    end

    test "refute_retried fails when a retry did happen", %{service: service} do
      ExternalService.call(service, fn -> {:retry, :boom} end)

      assert_raise ExUnit.AssertionError, ~r/expected no retry for/, fn ->
        refute_retried(service)
      end
    end

    test "an unmatched expectation leaves the event for a later assertion", %{service: service} do
      ExternalService.call(service, fn -> {:retry, :service_unavailable} end)

      assert_raise ExUnit.AssertionError, fn -> assert_retried(service, reason: :wrong) end

      # The event was put back rather than consumed by the failed match.
      assert_retried(service, reason: :service_unavailable)
    end

    test "one service's events do not satisfy another's assertion", %{service: service} do
      other = {__MODULE__, :other_service}
      start(other, circuit_breaker: [tolerate: 100], retry: [])
      on_exit(fn -> ExternalService.stop(other) end)

      ExternalService.call(service, fn -> {:retry, :boom} end)

      assert refute_retried(other) == :ok
      assert_retried(service)
    end
  end

  describe "assert_breaker_blown/2" do
    test "sees a call rejected by an open breaker", %{service: service} do
      start(service,
        circuit_breaker: [tolerate: 1, within: :timer.seconds(10)],
        retry: [max_attempts: 1]
      )

      trip_breaker(service)

      assert {:error, %CircuitBreakerOpen{}} =
               ExternalService.call(service, fn -> flunk("should not run") end)

      metadata = assert_breaker_blown(service)
      assert metadata.service == service
    end

    test "fails when no call was rejected", %{service: service} do
      start(service,
        circuit_breaker: [tolerate: 1, within: :timer.seconds(10)],
        retry: [max_attempts: 1]
      )

      # Tripped, but nothing has called through it, so nothing was rejected.
      trip_breaker(service)

      assert_raise ExUnit.AssertionError, ~r/circuit breaker rejection/, fn ->
        assert_breaker_blown(service)
      end
    end
  end

  describe "assert_throttled/2" do
    test "sees a call that waited for the limiter", %{service: service} do
      start(service,
        rate_limit: [limit: 1, per: 100, wait: :infinity],
        circuit_breaker: [tolerate: 100, within: :timer.seconds(10)],
        retry: [max_attempts: 1],
        sleep_function: fn _ -> :ok end
      )

      ExternalService.call(service, fn -> :first end)
      ExternalService.call(service, fn -> :second end)

      metadata = assert_throttled(service)
      assert metadata.service == service
    end
  end

  describe "recording_sleep/1 and assert_slept/1" do
    test "records the real backoff sequence without waiting for it", %{service: service} do
      start(service,
        circuit_breaker: [tolerate: 100],
        retry: [max_attempts: 4, backoff: :exponential, base: 100],
        sleep_function: recording_sleep()
      )

      {elapsed, _result} =
        :timer.tc(fn -> ExternalService.call(service, fn -> :retry end) end)

      assert assert_slept([100, 200, 400]) == [100, 200, 400]
      # 700ms of configured backoff, none of it actually spent.
      assert elapsed < 500_000
    end

    test "asserts on the whole sequence, so a wrong backoff fails", %{service: service} do
      start(service,
        circuit_breaker: [tolerate: 100],
        retry: [max_attempts: 3, backoff: :linear, base: 100],
        sleep_function: recording_sleep()
      )

      ExternalService.call(service, fn -> :retry end)

      assert_raise ExUnit.AssertionError, ~r/expected the recorded sleep delays to be/, fn ->
        assert_slept([100, 200])
      end
    end

    test "an empty list asserts that nothing slept", %{service: service} do
      start(service,
        circuit_breaker: [tolerate: 100],
        retry: [max_attempts: 3, backoff: :exponential, base: 100],
        sleep_function: recording_sleep()
      )

      ExternalService.call(service, fn -> :fine end)

      assert assert_slept([]) == []
    end

    test "says so when nothing was recorded at all" do
      error =
        assert_raise ExUnit.AssertionError, fn -> assert_slept([100]) end

      assert error.message =~ "Nothing was recorded"
      assert error.message =~ "recording_sleep()"
    end

    test "records to another process when given one", %{service: service} do
      collector = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(collector, :kill) end)

      start(service,
        circuit_breaker: [tolerate: 100],
        retry: [max_attempts: 2, backoff: :linear, base: 50],
        sleep_function: recording_sleep(collector)
      )

      ExternalService.call(service, fn -> :retry end)

      # Nothing arrived here; it went to the collector.
      assert assert_slept([]) == []
      assert Process.info(collector, :message_queue_len) == {:message_queue_len, 1}
    end
  end

  describe "record_events/0" do
    test "an assertion without it says what is missing", %{service: service} do
      # A fresh process has no recorder and no events, which is the state a test
      # that forgot `setup :record_events` is in.
      task =
        Task.async(fn ->
          assert_raise ExUnit.AssertionError, fn -> assert_retried(service) end
        end)

      error = Task.await(task)
      assert error.message =~ "record_events"
    end

    test "lists what it did record when the assertion looked for something else", %{
      service: service
    } do
      start(service,
        circuit_breaker: [tolerate: 100, within: :timer.seconds(10)],
        retry: [max_attempts: 2, base: 0]
      )

      ExternalService.call(service, fn -> {:retry, :boom} end)

      error = assert_raise ExUnit.AssertionError, fn -> assert_breaker_blown(service) end

      assert error.message =~ "Recorded instead:"
      assert error.message =~ ":retry"
    end
  end

  defp start(service, options) do
    :ok = ExternalService.start(service, options)
    service
  end
end
