defmodule ExternalService.SimulateTest do
  use ExUnit.Case, async: true

  alias ExternalService.Simulation

  @moduletag capture_log: true

  doctest ExternalService, only: [simulate: 3]

  describe "against measured behavior" do
    # The simulator models exactly one thing — `:fuse`'s sliding failure window —
    # and the whole of its value rests on that model being right. These are not
    # invented expectations: every figure was measured against a running service
    # while writing guides/tuning.md and guides/circuit-breakers.md. If the
    # simulator and the real breaker ever disagree, one of these fails.

    test "the circuit-breakers.md transcript: opens on the 11th failing call" do
      assert %Simulation{opens_after: 11} =
               simulate(circuit_breaker: [tolerate: 10], retry: [max_attempts: 5])
    end

    test "the same configuration under :per_attempt: opens during the 3rd call" do
      assert %Simulation{opens_after: 3} =
               simulate(
                 circuit_breaker: [tolerate: 10, melt: :per_attempt, within: 10_000],
                 retry: [max_attempts: 5]
               )
    end

    test "the tuning guide's request path: opens on the 4th, 700ms per call" do
      assert %Simulation{opens_after: 4, worst_call: 700} =
               simulate(
                 circuit_breaker: [tolerate: 3, reset: 5_000],
                 retry: [backoff: :exponential, base: 100, max_attempts: 4, expiry: 1_000]
               )
    end

    test "the tuning guide's background job: opens on the 4th, 30s per call" do
      assert %Simulation{opens_after: 4, worst_call: 30_000, elapsed: 120_000} =
               simulate(
                 circuit_breaker: [tolerate: 3, reset: 30_000],
                 retry: [
                   backoff: :exponential,
                   base: 500,
                   cap: 5_000,
                   max_attempts: :infinity,
                   expiry: 30_000
                 ]
               )
    end

    test "the window that was too narrow: never opens" do
      # This is the bug that `within: :auto`'s headroom exists to prevent, and the
      # case a window model has to get right to be worth having. Measured against a
      # real service: twelve consecutive fully-failing calls, breaker still closed.
      assert %Simulation{opens_after: :never} =
               simulate(
                 [
                   circuit_breaker: [tolerate: 6, within: 12_000],
                   retry: [
                     backoff: :exponential,
                     base: 100,
                     cap: 500,
                     max_attempts: :infinity,
                     expiry: 2_000
                   ]
                 ],
                 max_calls: 12
               )
    end

    test "the same window with headroom: opens on the 7th" do
      assert %Simulation{opens_after: 7} =
               simulate(
                 circuit_breaker: [tolerate: 6, within: 24_000],
                 retry: [
                   backoff: :exponential,
                   base: 100,
                   cap: 500,
                   max_attempts: :infinity,
                   expiry: 2_000
                 ]
               )
    end
  end

  describe "what it reports" do
    test "the load a dead dependency absorbs before the breaker stops it" do
      # Four calls of five attempts each. This is the number `:max_attempts`
      # multiplies and `:tolerate` does not.
      assert %Simulation{attempts: 20, calls: 4} =
               simulate(circuit_breaker: [tolerate: 3], retry: [max_attempts: 5, base: 10])
    end

    test "raising :max_attempts multiplies the load without moving the breaker" do
      for max_attempts <- [3, 5, 10] do
        assert %Simulation{opens_after: 4, attempts: attempts} =
                 simulate(
                   circuit_breaker: [tolerate: 3],
                   retry: [max_attempts: max_attempts, base: 10, cap: 100]
                 )

        assert attempts == 4 * max_attempts
      end
    end

    test "does not vary between runs" do
      options = [
        circuit_breaker: [tolerate: 3],
        retry: [base: 100, max_attempts: 5, jitter: true]
      ]

      assert simulate(options) == simulate(options)
    end

    test "agrees with window/1 about how long a failing call waits" do
      options = [circuit_breaker: [tolerate: 3], retry: [base: 100, max_attempts: 5]]

      assert %Simulation{worst_call: worst} = simulate(options)
      assert worst == ExternalService.RetryOptions.window(options[:retry])
    end
  end

  describe "scenarios" do
    test ":always_failing with slow attempts charges the call for them" do
      # Attempt duration is the one thing a configuration cannot state, and what
      # makes a hand-sized window too narrow. Five attempts at 3s each on top of a
      # 1.5s retry window.
      assert %Simulation{worst_call: 16_500} =
               simulate(
                 [circuit_breaker: [tolerate: 3], retry: [base: 100, max_attempts: 5]],
                 scenario: {:always_failing, 3_000}
               )
    end

    test "a slow but working dependency never opens the breaker" do
      assert %Simulation{opens_after: :never, worst_call: 5_000} =
               simulate([circuit_breaker: [tolerate: 3]], scenario: {:slow, 5_000}, max_calls: 20)
    end

    test "a dependency that recovers stops melting" do
      assert %Simulation{opens_after: :never} =
               simulate([circuit_breaker: [tolerate: 3], retry: [base: 10, max_attempts: 3]],
                 scenario: {:failing_for, 100},
                 max_calls: 20
               )
    end

    test "an intermittent dependency is driven by :rand, so seed it to reproduce" do
      :rand.seed(:exsss, {1, 2, 3})
      first = simulate([circuit_breaker: [tolerate: 3]], scenario: {:intermittent, 0.9})

      :rand.seed(:exsss, {1, 2, 3})
      assert simulate([circuit_breaker: [tolerate: 3]], scenario: {:intermittent, 0.9}) == first
    end
  end

  describe "the two ways of naming a configuration" do
    test "simulates a started service, including its overrides" do
      ExternalService.start(:"simulated-service",
        circuit_breaker: [tolerate: 2],
        retry: [base: 10, max_attempts: 3]
      )

      on_exit(fn -> ExternalService.stop(:"simulated-service") end)

      assert %Simulation{opens_after: 3} =
               ExternalService.simulate(:"simulated-service", :always_failing)
    end

    test "raises for a service that was never started" do
      assert_raise ExternalService.ServiceNotStarted, fn ->
        ExternalService.simulate(:"never-started", :always_failing)
      end
    end

    test "rejects a configuration that could not be started" do
      assert_raise ArgumentError, ~r/never give up/, fn ->
        ExternalService.simulate([retry: [max_attempts: :infinity]], :always_failing)
      end
    end
  end

  defp simulate(options, opts \\ []) do
    {scenario, opts} = Keyword.pop(opts, :scenario, :always_failing)
    ExternalService.simulate(options, scenario, opts)
  end
end
