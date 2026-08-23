defmodule ExternalService.CoverageTest do
  # Not async: the counter table and the telemetry handler are global, and these
  # assert on exact counts.
  use ExUnit.Case, async: false

  alias ExternalService.Test.Coverage

  @moduletag capture_log: true

  setup context do
    service = {__MODULE__, context.test}

    Coverage.attach()
    Coverage.reset()

    on_exit(fn ->
      Coverage.detach()
      Coverage.reset()
      ExternalService.stop(service)
    end)

    %{service: service}
  end

  describe "counting calls" do
    test "a happy-path service is called and exercises nothing", %{service: service} do
      start(service)

      assert ExternalService.call(service, fn -> :fine end) == :fine
      assert ExternalService.call(service, fn -> :fine end) == :fine

      assert [entry] = Coverage.entries()

      assert entry.service == service
      assert entry.calls == 2
      assert entry.retried == 0
      assert entry.failed == 0
      refute entry.exercised?
    end

    test "counts calls, not events: a call that retried four times counts once", %{
      service: service
    } do
      start(service, retry: [max_attempts: 5, base: 0])

      ExternalService.call(service, fn -> {:retry, :nope} end)

      assert [%{calls: 1, retried: 1, failed: 1}] = Coverage.entries()
    end

    test "a call that retried and then succeeded is retried but not failed", %{service: service} do
      start(service, retry: [max_attempts: 3, base: 0])
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      result =
        ExternalService.call(service, fn ->
          case Agent.get_and_update(counter, &{&1, &1 + 1}) do
            0 -> {:retry, :nope}
            _ -> :recovered
          end
        end)

      assert result == :recovered
      assert [%{calls: 1, retried: 1, failed: 0, exercised?: true}] = Coverage.entries()
    end

    test "an exception counts as a failed call", %{service: service} do
      start(service, retry: [max_attempts: 1])

      assert_raise RuntimeError, fn ->
        ExternalService.call(service, fn -> raise "boom" end)
      end

      assert [%{calls: 1, failed: 1, exercised?: true}] = Coverage.entries()
    end

    test "tracks each service separately", %{service: service} do
      other = {__MODULE__, :second_service}
      on_exit(fn -> ExternalService.stop(other) end)

      start(service, retry: [max_attempts: 2, base: 0])
      start(other, retry: [max_attempts: 2, base: 0])

      ExternalService.call(service, fn -> {:retry, :nope} end)
      ExternalService.call(other, fn -> :fine end)

      entries = Map.new(Coverage.entries(), &{&1.service, &1})

      assert %{calls: 1, retried: 1} = entries[service]
      assert %{calls: 1, retried: 0} = entries[other]
    end
  end

  describe "the paths a result reports but no partial event does" do
    # This is the case the issue's event list would have missed. `wait: false` and
    # `tolerate: :infinity`-style shortcuts are what `guides/testing.md`
    # recommends for tests, and under them the limiter never sleeps and the
    # concurrency limiter never waits — the call is simply refused, so the
    # closing result is the only signal that the path was taken.

    test "a wait: false rate limit is counted although nothing ever slept", %{service: service} do
      start(service,
        retry: [max_attempts: 1],
        rate_limit: [limit: 1, per: :timer.minutes(1), wait: false]
      )

      assert ExternalService.call(service, fn -> :first end) == :first

      assert {:error, %ExternalService.RateLimited{}} =
               ExternalService.call(service, fn -> flunk("should not run") end)

      assert [%{calls: 2, throttled: 1, exercised?: true}] = Coverage.entries()
    end

    test "a rejected call is counted", %{service: service} do
      start(service, circuit_breaker: [tolerate: 1, within: :timer.seconds(10)])

      Enum.each(1..2, fn _ -> ExternalService.CircuitBreaker.melt(service) end)

      assert {:error, %ExternalService.CircuitBreakerOpen{}} =
               ExternalService.call(service, fn -> flunk("should not run") end)

      assert [%{calls: 1, rejected: 1, exercised?: true}] = Coverage.entries()
    end

    test "a saturated call is counted", %{service: service} do
      start(service,
        retry: [max_attempts: 1],
        concurrency: [limit: 1, reclaim_after: 30_000, wait: false]
      )

      parent = self()

      task =
        Task.async(fn ->
          ExternalService.call(service, fn ->
            send(parent, :in_flight)
            receive do: (:release -> :done)
          end)
        end)

      assert_receive :in_flight

      assert {:error, %ExternalService.ServiceSaturated{}} =
               ExternalService.call(service, fn -> flunk("should not run") end)

      send(task.pid, :release)
      Task.await(task)

      assert [%{saturated: 1, exercised?: true}] = Coverage.entries()
    end

    test "a sleeping rate limit counts the call once, not once per sleep", %{service: service} do
      start(service,
        retry: [max_attempts: 1],
        rate_limit: [limit: 1, per: 50, wait: :infinity],
        sleep_function: fn _ -> :ok end
      )

      assert ExternalService.call(service, fn -> :first end) == :first
      assert ExternalService.call(service, fn -> :second end) == :second

      assert [%{calls: 2, throttled: 1}] = Coverage.entries()
    end
  end

  describe "report/0" do
    test "renders a table and flags a service that exercised nothing", %{service: service} do
      start(service)

      Enum.each(1..3, fn _ -> ExternalService.call(service, fn -> :fine end) end)

      report = Coverage.report()

      assert report =~ "external_service coverage"
      assert report =~ "service"
      assert report =~ "retried"
      assert report =~ "saturated"
      assert report =~ inspect(service)
      assert report =~ "⚠"
      assert report =~ "was called 3 times and never once"
      assert report =~ "not covered by this suite"
    end

    test "does not flag a service that took a failure path", %{service: service} do
      start(service, retry: [max_attempts: 2, base: 0])

      ExternalService.call(service, fn -> {:retry, :nope} end)

      refute Coverage.report() =~ "⚠"
    end

    test "says so rather than printing an empty table" do
      assert Coverage.report() =~ "No guarded calls were recorded"
    end

    test "pluralizes a single call", %{service: service} do
      start(service)
      ExternalService.call(service, fn -> :fine end)

      assert Coverage.report() =~ "was called 1 time and never once"
    end
  end

  describe "lifecycle" do
    test "records nothing once detached", %{service: service} do
      start(service)

      ExternalService.call(service, fn -> :fine end)
      Coverage.detach()
      ExternalService.call(service, fn -> :fine end)

      assert [%{calls: 1}] = Coverage.entries()
    end

    test "reset/0 clears the counts and recording continues", %{service: service} do
      start(service)

      ExternalService.call(service, fn -> :fine end)
      assert Coverage.reset() == :ok
      assert Coverage.entries() == []

      ExternalService.call(service, fn -> :fine end)
      assert [%{calls: 1}] = Coverage.entries()
    end

    test "attaching twice does not double count", %{service: service} do
      start(service)

      Coverage.attach()
      ExternalService.call(service, fn -> :fine end)

      assert [%{calls: 1}] = Coverage.entries()
    end
  end

  defp start(service, options \\ []) do
    defaults = [circuit_breaker: [tolerate: 100], retry: [max_attempts: 1]]
    :ok = ExternalService.start(service, Keyword.merge(defaults, options))
    service
  end
end
