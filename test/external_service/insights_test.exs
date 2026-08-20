defmodule ExternalService.InsightsTest do
  # Not async: attaching is a global telemetry handler.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ExternalService.Insights
  alias ExternalService.Insights.Report

  @moduletag capture_log: true

  setup do
    on_exit(&Insights.detach/0)
    :ok
  end

  defp start_service(name, options \\ []) do
    options =
      Keyword.merge(
        [
          circuit_breaker: [tolerate: 100, within: 60_000],
          retry: [backoff: :linear, base: 0, max_attempts: 3],
          sleep_function: fn _ms -> :ok end
        ],
        options
      )

    :ok = ExternalService.start(name, options)
    on_exit(fn -> ExternalService.stop(name) end)
    name
  end

  defp fail(service, times \\ 1) do
    for _ <- 1..times, do: ExternalService.call(service, fn -> :retry end)
  end

  # Failing calls spread far enough apart that a narrow `:within` cannot hold two
  # of them at once. This is what an inert breaker actually looks like: melts that
  # arrive further apart than the window counting them, because the attempts got
  # slower than whoever sized the window expected.
  defp fail_slowly(service, times, attempt_ms) do
    for _ <- 1..times do
      ExternalService.call(service, fn ->
        Process.sleep(attempt_ms)
        :retry
      end)
    end
  end

  describe "counting what happens" do
    test "separates calls that failed, succeeded, and were never made" do
      service =
        start_service(:"insights-counting", circuit_breaker: [tolerate: 2, within: 60_000])

      Insights.attach(log: false)

      fail(service, 3)
      # The breaker is open now, so this one never reaches the dependency.
      fail(service, 1)

      assert %Report{calls: 4, failed: 3, rejected: 1, succeeded: 0} = Insights.report(service)
    end

    test "counts attempts, not just calls" do
      service = start_service(:"insights-attempts")
      Insights.attach(log: false)

      fail(service, 2)

      # Two calls of three attempts each.
      assert %Report{calls: 2, attempts: 6} = Insights.report(service)
    end

    test "notices a call that needed retries but succeeded" do
      service = start_service(:"insights-degraded")
      Insights.attach(log: false)

      Process.put(:attempt, 0)

      ExternalService.call(service, fn ->
        Process.put(:attempt, Process.get(:attempt) + 1)
        if Process.get(:attempt) < 3, do: :retry, else: :ok
      end)

      ExternalService.call(service, fn -> :ok end)

      assert %Report{succeeded: 2, degraded: 1, failed: 0} = Insights.report(service)
    end

    test "tracks the current and worst failure streak" do
      service = start_service(:"insights-streak")
      Insights.attach(log: false)

      fail(service, 3)
      ExternalService.call(service, fn -> :ok end)
      fail(service, 2)

      assert %Report{consecutive_failures: 2, worst_consecutive_failures: 3} =
               Insights.report(service)
    end

    test "a service that is not watched says so" do
      assert Insights.report(:"never-watched") == {:error, :not_attached}
    end

    test "detaching discards what was observed" do
      service = start_service(:"insights-detach")
      Insights.attach(log: false)
      fail(service, 2)

      assert %Report{calls: 2} = Insights.report(service)

      Insights.detach()
      assert Insights.report(service) == {:error, :not_attached}
    end
  end

  describe "the inert breaker finding" do
    # The detection no static check can make: the breaker tolerates a stated
    # number of failures, more than that have happened in a row, and it is still
    # closed. Whatever `:within` was sized against is not what is happening.

    test "fires when more consecutive failures than :tolerate leave it closed" do
      # `within: 1` is a stand-in for the real cause — a window that no longer fits
      # because attempts got slower — and reproduces its symptom exactly: melts
      # that never accumulate.
      service =
        start_service(:"insights-inert",
          circuit_breaker: [tolerate: 3, within: 2],
          retry: [backoff: :linear, base: 0, max_attempts: 1]
        )

      Insights.attach(log: false)
      fail_slowly(service, 6, 10)

      assert %Report{findings: findings} = Insights.report(service)
      assert [%{check: :inert_breaker, message: message}] = findings

      assert message =~ "has failed 6 consecutive calls"
      assert message =~ "still closed"
      assert message =~ "It tolerates 3 failures within"
      assert message =~ "circuit_breaker: [within:"
      refute ExternalService.blown?(service)
    end

    test "stays quiet while the breaker is doing its job" do
      service = start_service(:"insights-working", circuit_breaker: [tolerate: 2, within: 60_000])
      Insights.attach(log: false)

      fail(service, 5)

      assert ExternalService.blown?(service)
      assert %Report{findings: []} = Insights.report(service)
    end

    test "stays quiet below :tolerate" do
      service =
        start_service(:"insights-below",
          circuit_breaker: [tolerate: 10, within: 2],
          retry: [backoff: :linear, base: 0, max_attempts: 1]
        )

      Insights.attach(log: false)
      fail_slowly(service, 4, 10)

      assert %Report{findings: []} = Insights.report(service)
    end

    test "says nothing about a breaker that is not installed" do
      service = start_service(:"insights-no-breaker", circuit_breaker: [tolerate: :infinity])
      Insights.attach(log: false)

      fail(service, 20)

      assert %Report{findings: []} = Insights.report(service)
    end
  end

  describe "the degraded-but-succeeding finding" do
    test "fires when retrying is quietly absorbing a fault" do
      # Exactly what per-call melting hides from the breaker, on purpose: the calls
      # work, so nothing melts, so no breaker reacts. Someone should still know.
      service = start_service(:"insights-absorbing")
      Insights.attach(log: false)

      for n <- 1..30 do
        Process.put(:attempt, 0)

        ExternalService.call(service, fn ->
          Process.put(:attempt, Process.get(:attempt) + 1)
          # Half the calls need a retry; all of them succeed.
          if rem(n, 2) == 0 and Process.get(:attempt) == 1, do: :retry, else: :ok
        end)
      end

      assert %Report{succeeded: 30, failed: 0, findings: findings} = Insights.report(service)
      assert [%{check: :degraded_but_succeeding, message: message}] = findings

      assert message =~ "50% of its successful calls needed at least one retry"
      assert message =~ "will not react to this and should not"
      refute ExternalService.blown?(service)
    end

    test "stays quiet when retries are rare" do
      service = start_service(:"insights-healthy")
      Insights.attach(log: false)

      for _ <- 1..30, do: ExternalService.call(service, fn -> :ok end)

      assert %Report{findings: []} = Insights.report(service)
    end
  end

  describe "the slow-attempts finding" do
    test "fires when a call takes much longer than its backoff accounts for" do
      # A 0ms retry window with calls taking 15ms each: whatever the time is going
      # on, it is not backoff.
      service =
        start_service(:"insights-slow",
          circuit_breaker: [tolerate: 1000, within: 600_000],
          retry: [backoff: :linear, base: 2, max_attempts: 2]
        )

      Insights.attach(log: false)

      for _ <- 1..25 do
        ExternalService.call(service, fn ->
          Process.sleep(15)
          :ok
        end)
      end

      assert %Report{findings: findings} = Insights.report(service)

      assert %{check: :attempt_time_dominates, message: message} =
               Enum.find(findings, &(&1.check == :attempt_time_dominates))

      assert message =~ "per call on average"
      assert message =~ "Most of a call is the attempts themselves"
      assert message =~ "retry: [expiry:"
    end

    test "is suppressed while the breaker is reported inert, being its cause" do
      service =
        start_service(:"insights-both",
          circuit_breaker: [tolerate: 2, within: 2],
          retry: [backoff: :linear, base: 0, max_attempts: 1]
        )

      Insights.attach(log: false)
      fail_slowly(service, 25, 10)

      # Both conditions hold; only the acute one is reported, and its message
      # already explains that attempt time is the cause.
      assert %Report{findings: [%{check: :inert_breaker, message: message}]} =
               Insights.report(service)

      assert message =~ "however long its attempts run for"
    end

    test "needs a sample before it says anything" do
      service =
        start_service(:"insights-small-sample",
          retry: [backoff: :linear, base: 0, max_attempts: 1]
        )

      Insights.attach(log: false)

      for _ <- 1..3, do: ExternalService.call(service, fn -> Process.sleep(15) end)

      assert %Report{findings: []} = Insights.report(service)
    end
  end

  describe "logging" do
    test "logs a finding, and then holds its tongue" do
      service =
        start_service(:"insights-logging",
          circuit_breaker: [tolerate: 2, within: 2],
          retry: [backoff: :linear, base: 0, max_attempts: 1]
        )

      Insights.attach(log: true, log_every: 60_000)

      log = capture_log(fn -> fail_slowly(service, 8, 10) end)

      # Eight failing calls, one log line: a diagnostic that fires on every call is
      # one people detach.
      assert log =~ "[ExternalService.Insights]"
      assert length(String.split(log, "[ExternalService.Insights]")) == 2
    end

    test "log: false stays silent" do
      service =
        start_service(:"insights-quiet",
          circuit_breaker: [tolerate: 2, within: 2],
          retry: [backoff: :linear, base: 0, max_attempts: 1]
        )

      Insights.attach(log: false)

      log = capture_log(fn -> fail_slowly(service, 8, 10) end)

      refute log =~ "[ExternalService.Insights]"
    end

    test "says nothing at all when there is nothing to say" do
      service = start_service(:"insights-nothing-to-say")
      Insights.attach(log: true, log_every: 0)

      log =
        capture_log(fn -> for _ <- 1..30, do: ExternalService.call(service, fn -> :ok end) end)

      refute log =~ "[ExternalService.Insights]"
    end
  end

  describe "attaching" do
    test "watches only the services asked for" do
      watched = start_service(:"insights-watched")
      ignored = start_service(:"insights-ignored")

      Insights.attach(services: [watched], log: false)

      fail(watched, 1)
      fail(ignored, 1)

      assert %Report{calls: 1} = Insights.report(watched)
      assert Insights.report(ignored) == {:error, :not_attached}
    end

    test "costs nothing when it was never attached" do
      service = start_service(:"insights-unattached")

      fail(service, 2)

      assert Insights.report(service) == {:error, :not_attached}
    end
  end
end
