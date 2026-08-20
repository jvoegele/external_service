defmodule ExternalService.Simulation do
  @moduledoc """
  The result of `ExternalService.simulate/3`.

    * `:opens_after` — how many failing calls it took to open the circuit breaker,
      or `:never` if it stayed closed for the whole simulation.
    * `:worst_call` — the longest call, in milliseconds.
    * `:attempts` — how many attempts reached the dependency, in total. This is the
      load a failing dependency takes before you stop calling it.
    * `:calls` — how many calls were simulated.
    * `:elapsed` — simulated time, in milliseconds.
    * `:scenario` — the scenario that was run.
  """

  @type t :: %__MODULE__{
          opens_after: pos_integer() | :never,
          worst_call: non_neg_integer(),
          attempts: non_neg_integer(),
          calls: pos_integer(),
          elapsed: non_neg_integer(),
          scenario: ExternalService.scenario()
        }

  defstruct [:opens_after, :worst_call, :attempts, :calls, :elapsed, :scenario]
end

defmodule ExternalService.Simulator do
  @moduledoc false

  # Runs a configuration against a fake dependency on a virtual clock.
  #
  # What is modelled here is exactly one thing: `:fuse`'s sliding failure window.
  # Everything else uses the library's own code — the delays come from
  # `Retry.plan/1`, the options are resolved through the same path `start/2` uses,
  # and what counts as a melt follows the service's `:melt` setting. So this is a
  # predictor with one small model in it, not a second implementation of the
  # library.
  #
  # That model is pinned against measured behavior in `simulate_test.exs`, using
  # figures taken from real services in `guides/tuning.md` — including the case
  # where a breaker stays closed through twelve consecutive failing calls, which is
  # the one a window model has to get right to be worth having.
  #
  # Not modelled: the rate limiter and the concurrency limit. Neither melts the
  # breaker, and both are about the traffic reaching a service rather than what a
  # service does with a failure.

  alias ExternalService.RetryOptions
  alias ExternalService.Simulation

  defstruct [:now, :melts, :tolerate, :within, :melt, :attempts, :worst_call, :calls]

  @spec run(ExternalService.service(), keyword(), ExternalService.scenario(), keyword()) ::
          Simulation.t()
  def run(_service, options, scenario, opts) do
    max_calls = Keyword.get(opts, :max_calls, 100)

    # Nominal delays, for the same reason `RetryOptions.window/1` and
    # `ExternalService.explain/1` report nominal figures: the three functions that
    # answer "what does this configuration do" should agree with each other, and a
    # simulation meant to be asserted in a test must not vary between runs. Jitter
    # does not change whether a breaker opens, only the exact `:worst_call`.
    %RetryOptions{} = configured = RetryOptions.new(Keyword.get(options, :retry, []))
    retry = %RetryOptions{configured | jitter: false}
    breaker = Keyword.get(options, :circuit_breaker, [])

    state = %__MODULE__{
      now: 0,
      melts: [],
      tolerate: Keyword.get(breaker, :tolerate, 10),
      within: Keyword.fetch!(breaker, :within),
      melt: Keyword.get(breaker, :melt, :per_call),
      attempts: 0,
      worst_call: 0,
      calls: 0
    }

    simulate_calls(state, retry, scenario, max_calls)
  end

  defp simulate_calls(state, retry, scenario, max_calls) do
    Enum.reduce_while(1..max_calls, state, fn call, state ->
      state = simulate_call(state, retry, scenario)

      if blown?(state), do: {:halt, %{state | calls: call}}, else: {:cont, %{state | calls: call}}
    end)
    |> into_result(scenario, max_calls)
  end

  # One call: the initial attempt, then one more per planned delay. It ends in one
  # of three ways, and only one of them charges the breaker under `:per_call`.
  defp simulate_call(state, retry, scenario) do
    started_at = state.now
    delays = retry |> ExternalService.Retry.plan() |> Enum.to_list()

    {state, ending} =
      Enum.reduce_while([0 | delays], {state, :exhausted}, fn delay, {state, _ending} ->
        state = %{state | now: state.now + delay}

        if blown?(state) do
          # The breaker opened, either before this call or part-way through its
          # retry loop under `:per_attempt`. The attempt never ran, so it neither
          # reaches the dependency nor counts as a failure.
          {:halt, {state, :rejected}}
        else
          run_attempt(state, scenario)
        end
      end)

    state = if ending == :exhausted, do: finish_failed_call(state), else: state

    %{state | worst_call: max(state.worst_call, state.now - started_at)}
  end

  defp run_attempt(state, scenario) do
    {outcome, duration} = outcome(scenario, state.now)
    state = %{state | now: state.now + duration, attempts: state.attempts + 1}

    case outcome do
      :ok ->
        {:halt, {state, :succeeded}}

      :fail ->
        # Under `:per_attempt` every failing attempt melts. Under `:per_call` the
        # melt belongs to the call and is recorded when its retrying gives up.
        state = if state.melt == :per_attempt, do: melt(state), else: state
        {:cont, {state, :exhausted}}
    end
  end

  # The call gave up. Under `:per_call` that is the moment it charges the breaker;
  # a call that succeeded on a later attempt never reaches here and melts nothing.
  defp finish_failed_call(%{melt: :per_call} = state), do: melt(state)
  defp finish_failed_call(state), do: state

  defp melt(state), do: %{state | melts: [state.now | state.melts]}

  # `:fuse` tolerates `:tolerate` failures inside the window and opens on the next.
  # A true sliding window, which is what measurement says the real breaker behaves
  # like: melts at 0, 30, 60 and 90 seconds against a 90-second window leave three
  # inside it at t=90, not four, and the breaker stays closed — as measured.
  defp blown?(%{tolerate: :infinity}), do: false

  defp blown?(state) do
    Enum.count(state.melts, &(&1 > state.now - state.within)) > state.tolerate
  end

  defp into_result(state, scenario, max_calls) do
    %Simulation{
      opens_after: if(blown?(state), do: state.calls, else: :never),
      worst_call: state.worst_call,
      attempts: state.attempts,
      calls: min(state.calls, max_calls),
      elapsed: state.now,
      scenario: scenario
    }
  end

  # Scenarios answer, for an attempt at a given moment: did it fail, and how long
  # did it take?
  defp outcome(:always_failing, _now), do: {:fail, 0}
  defp outcome({:always_failing, attempt_ms}, _now), do: {:fail, attempt_ms}
  defp outcome({:slow, attempt_ms}, _now), do: {:ok, attempt_ms}

  defp outcome({:failing_for, ms}, now) do
    if now < ms, do: {:fail, 0}, else: {:ok, 0}
  end

  defp outcome({:intermittent, rate}, _now) do
    if :rand.uniform() < rate, do: {:fail, 0}, else: {:ok, 0}
  end
end
