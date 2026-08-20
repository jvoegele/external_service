defmodule ExternalService.ConfigurationAgreementTest do
  use ExUnit.Case, async: true

  alias ExternalService.CircuitBreaker
  alias ExternalService.ConfigCheck
  alias ExternalService.RetryOptions
  alias ExternalService.Simulation

  # `ConfigCheck` and `simulate/3` are two independent answers to one question:
  # will this configuration work? One reasons about the options, the other runs
  # them. Where they disagree, one of them is wrong — and neither can be checked
  # against the other by an example, because every example anyone writes by hand
  # picks values they already understand.
  #
  # This sweeps a grid instead. It is the test that found issue #112: `:auto` and
  # the narrow-window check both sized a `:per_attempt` window for one call's
  # melts, when the defaults need three calls' worth. Fifty-two of these
  # configurations were silently inert, one of them confirmed against a live
  # service as 75 seconds of total failure with the breaker still closed.
  #
  # It costs a couple of seconds because nothing sleeps: simulation runs on a
  # virtual clock.

  defp configurations do
    for tolerate <- [1, 3, 6, 10, 20],
        within <- [:auto, 1_000, 10_000, 60_000],
        base <- [10, 100, 500],
        max_attempts <- [1, 3, 5, 8],
        cap <- [nil, 2_000],
        expiry <- [nil, 2_000, 30_000],
        melt <- [:per_call, :per_attempt] do
      retry =
        [backoff: :exponential, base: base, max_attempts: max_attempts]
        |> then(&if cap, do: Keyword.put(&1, :cap, cap), else: &1)
        |> then(&if expiry, do: Keyword.put(&1, :expiry, expiry), else: &1)

      [circuit_breaker: [tolerate: tolerate, within: within, melt: melt], retry: retry]
    end
  end

  test "a configuration whose breaker never opens is always reported" do
    inert_and_unreported =
      Enum.filter(configurations(), fn options ->
        %Simulation{opens_after: opens} =
          ExternalService.simulate(options, :always_failing, max_calls: 60)

        opens == :never and ConfigCheck.run(:probe, options) == []
      end)

    assert inert_and_unreported == [],
           """
           #{length(inert_and_unreported)} of #{length(configurations())} configurations never open \
           their circuit breaker under sustained total failure, and no configuration check says so:

           #{Enum.map_join(Enum.take(inert_and_unreported, 5), "\n", &"    #{inspect(&1)}")}
           """
  end

  test "a window sized by :auto is never one the checks would reject" do
    # `:auto` skips the narrow-window check by construction — it is the value that
    # check would suggest. That is only sound if `:auto` really is wide enough.
    too_narrow =
      Enum.filter(configurations(), fn options ->
        breaker = options[:circuit_breaker]
        retry = RetryOptions.new(options[:retry])
        tolerate = breaker[:tolerate]

        CircuitBreaker.auto_window(tolerate, breaker[:melt], retry) <
          CircuitBreaker.minimum_window(tolerate, breaker[:melt], retry)
      end)

    assert too_narrow == []
  end

  test "the checks and :auto agree about how many calls it takes to open a breaker" do
    # Both are derived from `calls_to_open/3`. This pins the arithmetic itself
    # against the simulator, which counts calls rather than computing them.
    for tolerate <- [1, 3, 10], max_attempts <- [1, 3, 5, 8], melt <- [:per_call, :per_attempt] do
      retry = [backoff: :linear, base: 0, max_attempts: max_attempts]

      options = [
        circuit_breaker: [tolerate: tolerate, within: 600_000, melt: melt],
        retry: retry
      ]

      %Simulation{opens_after: opens} =
        ExternalService.simulate(options, :always_failing, max_calls: 200)

      expected = CircuitBreaker.calls_to_open(tolerate, melt, RetryOptions.new(retry))

      # `calls_to_open/3` counts the calls that produce the melts; the breaker
      # opens on the last of them, or the one after under `:per_call`.
      assert opens in [expected, expected + 1],
             "#{melt}, tolerate: #{tolerate}, max_attempts: #{max_attempts} — " <>
               "simulate opened on #{inspect(opens)}, arithmetic said #{expected}"
    end
  end
end
