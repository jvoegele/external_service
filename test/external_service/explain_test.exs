defmodule ExternalService.ExplainTest do
  use ExUnit.Case, async: true

  @moduletag capture_log: true

  describe "explaining a proposed configuration" do
    test "reports the retry window and the delays that make it up" do
      report = ExternalService.explain(retry: [base: 100, max_attempts: 5])

      assert report =~ "window       1.5s"
      assert report =~ "delays       100ms, 200ms, 400ms, 800ms"
      assert report =~ "attempts     up to 5"
    end

    test "reports how many failing calls open the breaker" do
      report = ExternalService.explain(circuit_breaker: [tolerate: 3])

      # `:tolerate` is what is tolerated; the next failure is the one that opens it.
      assert report =~ "opens after      4 failing calls"
    end

    test "counts attempts under :per_attempt, and says how few calls that can be" do
      report =
        ExternalService.explain(
          circuit_breaker: [tolerate: 5, melt: :per_attempt],
          retry: [max_attempts: 3]
        )

      assert report =~
               "opens after      6 failing attempts — as few as 2 calls at 3 attempts each"
    end

    test "singularizes the call that trips its own breaker" do
      report =
        ExternalService.explain(
          circuit_breaker: [tolerate: 3, melt: :per_attempt],
          retry: [max_attempts: 8]
        )

      assert report =~ "as few as 1 call at 8 attempts each"
    end

    test "says a breaker that never opens never opens" do
      report = ExternalService.explain(circuit_breaker: [tolerate: :infinity])

      assert report =~ "never — `tolerate: :infinity` installs no breaker"
    end

    test "resolves :within rather than echoing the symbol back" do
      report =
        ExternalService.explain(
          circuit_breaker: [tolerate: 3],
          retry: [max_attempts: :infinity, expiry: 30_000]
        )

      # `:auto` against three failing calls of 30s each, with headroom for the
      # attempt time no configuration states.
      assert report =~ "counting window  180s"
      refute report =~ ":auto"
    end

    test "flags a hand-set window that is narrower than what it has to count" do
      report =
        ExternalService.explain(
          circuit_breaker: [tolerate: 3, within: 1_000],
          retry: [base: 100, max_attempts: 5]
        )

      assert report =~ "counting window  1s — narrower than 3 failing calls take; see below"
      # ...and "below" is really there.
      assert report =~ "narrower than the failures it has to count"
    end

    test "reports the window nominally when jitter is on, and says so" do
      report = ExternalService.explain(retry: [base: 100, max_attempts: 5, jitter: true])

      assert report =~ "window       1.5s nominal, +/- 10% with jitter"
      # The delays are nominal too, so the report does not change between calls.
      assert report =~ "delays       100ms, 200ms, 400ms, 800ms"
      assert report == ExternalService.explain(retry: [base: 100, max_attempts: 5, jitter: true])
    end

    test "separates waiting from the attempt time nothing here bounds" do
      report = ExternalService.explain(retry: [base: 100, max_attempts: 5])

      assert report =~ "spends  1.5s waiting between attempts"
      assert report =~ "nothing here bounds a single attempt"
    end

    test "describes a service that never retries" do
      report = ExternalService.explain(retry: [max_attempts: 1])

      assert report =~ "window       none"
      assert report =~ "delays       none — a single attempt, never retried"
    end

    test "describes the rate limit and the concurrency limit when present" do
      report =
        ExternalService.explain(
          rate_limit: [limit: 100, per: 1_000, wait: :infinity],
          concurrency: [limit: 25, reclaim_after: 30_000, wait: 50]
        )

      assert report =~ "limit        100 per 1s"
      assert report =~ "waits up to  as long as it takes"
      assert report =~ "limit           25 in flight"
      assert report =~ "reclaims after  30s"
    end

    test "says plainly when a mechanism is not configured" do
      report = ExternalService.explain([])

      assert report =~ "none  calls are not throttled"
      assert report =~ "none  calls are not limited in flight"
    end

    test "includes the configuration warnings, so the report explains itself" do
      report = ExternalService.explain(retry: [base: 100, max_attempts: 10])

      assert report =~ "warnings"
      assert report =~ "uncapped exponential backoff"
      assert report =~ "retry: [cap: :timer.seconds(2)]"
    end

    test "a sound configuration has no warnings section" do
      report = ExternalService.explain(circuit_breaker: [tolerate: 3], retry: [max_attempts: 5])

      refute report =~ "warnings"
    end

    test "rejects a configuration that could not be started" do
      assert_raise ArgumentError, ~r/never give up/, fn ->
        ExternalService.explain(retry: [max_attempts: :infinity])
      end
    end
  end

  describe "explaining a started service" do
    test "reports the options the service is actually running with" do
      ExternalService.start(:"explain-started",
        circuit_breaker: [tolerate: 3, reset: 5_000],
        retry: [base: 100, max_attempts: 5]
      )

      on_exit(fn -> ExternalService.stop(:"explain-started") end)

      report = ExternalService.explain(:"explain-started")

      assert report =~ ~s(:"explain-started")
      assert report =~ "opens after      4 failing calls"
      assert report =~ "resets after     5s"
      assert report =~ "window       1.5s"
    end

    test "reports the overridden options, not the ones written at compile time" do
      # Child-spec overrides are runtime values. A report that showed what was
      # written rather than what is running would be worse than none during an
      # incident.
      defmodule OverriddenService do
        use ExternalService,
          name: :"explain-overridden",
          circuit_breaker: [tolerate: 20],
          retry: [base: 100, max_attempts: 5]
      end

      start_supervised!({OverriddenService, circuit_breaker: [tolerate: 2]})

      assert ExternalService.explain(:"explain-overridden") =~ "opens after      3 failing calls"
    end

    test "says so for a service that was never started" do
      assert ExternalService.explain(:"never-started-service") =~ "has not been started"
    end
  end
end
