defmodule ExternalService.ConfigCheck do
  @moduledoc false

  # Checks a service's options against each other.
  #
  # `NimbleOptions` validates every key in isolation, which is why every trap in
  # `guides/tuning.md` is a pair of keys that are individually valid and jointly
  # wrong. `ExternalService.validate!/2`, `validate_breaker_combination!/2` and
  # `validate_melt_bound!/3` already reject three such pairs — but only ones that
  # contradict each other outright. This module is for the ones that need a number
  # computed first, and that are wrong rather than impossible: they warn.
  #
  # Findings are returned as data. How they are reported belongs to the caller,
  # because the two callers report differently: `use ExternalService` raises them
  # through `IO.warn/2` at compile time, where they carry a file and line and fail
  # a `--warnings-as-errors` build, and `start/2` logs them for the functional API
  # and for child-spec overrides, which are runtime values no compile-time check
  # can see.

  alias ExternalService.RetryOptions

  require Logger

  @type finding :: %{check: atom(), message: String.t()}

  @default_tolerate 10
  @default_melt :per_call

  # Past this many attempts each one costs about as much as everything before it
  # combined, so an uncapped delay stops being a backoff and becomes an outage.
  @cap_advisable_above 6

  @doc """
  How to report a suspicious configuration: `:warn` (the default), `:raise`, or
  `:ignore`.

      config :external_service, on_suspicious_config: :raise
  """
  @spec reporting() :: :warn | :raise | :ignore
  def reporting, do: Application.get_env(:external_service, :on_suspicious_config, :warn)

  @doc """
  Logs any findings for `options`, as `start/2` does.

  Reports on every call rather than once per service: `start/2` runs once per
  service in normal operation, and a boot log is where the 3.0 migration guide
  already sends people looking.
  """
  @spec report(ExternalService.service(), keyword()) :: :ok
  def report(service, options) do
    case {reporting(), run(service, options)} do
      {:ignore, _findings} ->
        :ok

      {_reporting, []} ->
        :ok

      {:raise, findings} ->
        raise ArgumentError, joined(findings)

      {:warn, findings} ->
        Enum.each(findings, &Logger.warning(&1.message))
    end
  end

  @doc """
  Findings for `options`, as data.

  Deliberately total: a configuration this cannot make sense of yields no findings
  rather than an error. It runs at compile time against options that may still be
  completed by a child-spec override, and a diagnostic that breaks the build it
  was meant to inform is worse than one that stays quiet.
  """
  @spec run(ExternalService.service(), keyword()) :: [finding()]
  def run(service, options) when is_list(options) do
    breaker = Keyword.get(options, :circuit_breaker, [])
    retry = Keyword.get(options, :retry, [])

    with true <- Keyword.keyword?(breaker) and (Keyword.keyword?(retry) or is_struct(retry)),
         {:ok, retry_options} <- retry_options(retry) do
      config = %{
        service: service,
        melt: Keyword.get(breaker, :melt, @default_melt),
        tolerate: Keyword.get(breaker, :tolerate, @default_tolerate),
        within: Keyword.get(breaker, :within, :auto),
        retry: retry_options,
        window: RetryOptions.window(retry_options)
      }

      # Ordered root cause first, and `narrow_window/1` is suppressed when
      # `uncapped_backoff/1` fires. The two compound: an uncapped 51-second retry
      # window makes every breaker window look too narrow, and the honest advice
      # there is to cap the backoff — not to widen the breaker to 154 seconds to
      # accommodate it. Fix the cause, recompile, and the second finding appears
      # if it still applies.
      uncapped = uncapped_backoff(config)

      Enum.concat([
        uncapped,
        self_tripping_call(config),
        unbounded_retrying(config),
        if(uncapped == [], do: narrow_window(config), else: [])
      ])
    else
      _ -> []
    end
  end

  def run(_service, _options), do: []

  defp retry_options(retry) do
    {:ok, RetryOptions.new(retry)}
  rescue
    _ -> :error
  end

  # The counting window has to be wide enough for the failures it counts to land
  # inside it. `:auto` sizes itself (and is the default), so this is only for a
  # window someone set by hand.
  #
  # Note what this can and cannot claim. Under `:per_attempt` it is a proof: a
  # single call's melts are spread across its own retry window, so a narrower
  # window cannot accumulate even one call's worth. Under `:per_call` it is a
  # heuristic — opening the breaker takes several calls, and how fast those arrive
  # is traffic rather than configuration. Sequential callers cannot open it;
  # concurrent ones can. The message says so rather than overclaiming.
  defp narrow_window(%{within: :auto}), do: []
  defp narrow_window(%{window: :infinity}), do: []
  defp narrow_window(%{window: 0}), do: []
  defp narrow_window(%{tolerate: :infinity}), do: []

  defp narrow_window(%{within: within} = config) when is_integer(within) do
    needed = needed_window(config)

    if within < needed do
      [
        finding(:narrow_window, """
        #{inspect(config.service)} has a circuit breaker window narrower than the failures it \
        has to count. Its retry window is #{ms(config.window)} per call#{narrow_window_because(config)}, \
        but `within: #{within}` counts failures over a narrower span, so #{narrow_window_effect(config)}

            circuit_breaker: [within: #{suggested_window(needed)}]

        Or leave `:within` unset, which sizes it from the retry options.\
        """)
      ]
    else
      []
    end
  end

  defp narrow_window(_config), do: []

  defp needed_window(%{melt: :per_attempt, window: window}), do: window

  defp needed_window(%{melt: :per_call, window: window, tolerate: tolerate}),
    do: window * tolerate

  defp narrow_window_because(%{melt: :per_attempt}), do: ", across which that call's melts land"

  defp narrow_window_because(%{melt: :per_call, tolerate: tolerate}),
    do: ", and it takes #{tolerate} failing calls to open the breaker"

  defp narrow_window_effect(%{melt: :per_attempt, tolerate: tolerate}),
    do: "a call's melts never accumulate to the #{tolerate} it tolerates."

  defp narrow_window_effect(%{melt: :per_call}),
    do:
      "a caller making these calls one after another never opens it. " <>
        "Concurrent callers still can, so this is a question of your traffic rather than a certainty."

  # Under `:per_attempt` a call's own melts can exceed the breaker's whole budget,
  # so the first failing call opens the breaker part-way through its own retry loop
  # and has the rest of its attempts rejected by it. Raising `:max_attempts` then
  # makes the service give up *sooner*, which is the least intuitive thing this
  # library used to do. `:per_call` is the fix, and it is the default.
  defp self_tripping_call(%{melt: :per_call}), do: []
  defp self_tripping_call(%{tolerate: :infinity}), do: []

  defp self_tripping_call(%{retry: %{max_attempts: max_attempts}, tolerate: tolerate} = config)
       when is_integer(max_attempts) and is_integer(tolerate) and max_attempts > tolerate do
    [
      finding(:self_tripping_call, """
      #{inspect(config.service)} sets `melt: :per_attempt` with `max_attempts: #{max_attempts}` \
      against `tolerate: #{tolerate}`, so a single failing call melts the breaker more times than \
      it tolerates: the first call opens the breaker part-way through its own retry loop, and its \
      remaining attempts are rejected by the breaker it just opened. Raising `:max_attempts` makes \
      this service give up sooner, not later.

          circuit_breaker: [melt: :per_call, tolerate: #{tolerate}]

      Under `:per_call` — the default since 3.0 — a call melts once when its retrying gives up, so \
      `:tolerate` counts calls and is independent of `:max_attempts`.\
      """)
    ]
  end

  defp self_tripping_call(_config), do: []

  # `:per_call` rejects this outright in `ExternalService.validate_melt_bound!/3`,
  # because there it hangs. Under `:per_attempt` it does terminate, eventually,
  # and only by accident.
  defp unbounded_retrying(%{melt: :per_call}), do: []

  defp unbounded_retrying(%{retry: %{max_attempts: :infinity, expiry: expiry}} = config)
       when expiry in [nil, :infinity] do
    [
      finding(:unbounded_retrying, """
      #{inspect(config.service)} retries without any bound: `max_attempts: :infinity` with no \
      `:expiry`. Under `melt: :per_attempt` the circuit breaker is what eventually halts such a \
      call, and it is not a reliable backstop — exponential backoff widens the gap between \
      attempts until failures no longer accumulate fast enough inside `:within` to open it.

          retry: [max_attempts: :infinity, expiry: :timer.seconds(30)]

      A time budget bounds the case an attempt count cannot: a dependency that is slow rather \
      than failing.\
      """)
    ]
  end

  defp unbounded_retrying(_config), do: []

  # Exponential backoff doubles, so the last delay is worth everything before it
  # combined. That is fine at the default of five attempts and ruinous at ten.
  defp uncapped_backoff(%{retry: %{cap: cap}}) when not is_nil(cap), do: []
  defp uncapped_backoff(%{retry: %{backoff: :linear}}), do: []

  defp uncapped_backoff(%{retry: %{max_attempts: max_attempts}} = config)
       when is_integer(max_attempts) and max_attempts > @cap_advisable_above do
    [
      finding(:uncapped_backoff, """
      #{inspect(config.service)} makes up to #{max_attempts} attempts with uncapped exponential \
      backoff, so a failing call waits #{ms(config.window)} — most of it in the last attempt or \
      two, since each delay is worth all the previous ones combined.

          retry: [cap: :timer.seconds(2)]

      A cap clamps each delay without ending the retrying, which is what keeps a high attempt \
      count from becoming a minutes-long call.\
      """)
    ]
  end

  defp uncapped_backoff(_config), do: []

  defp finding(check, message), do: %{check: check, message: String.trim_trailing(message)}

  defp joined(findings), do: findings |> Enum.map_join("\n\n", & &1.message) |> String.trim()

  defp ms(milliseconds) when milliseconds < 1_000, do: "#{milliseconds}ms"
  defp ms(milliseconds), do: "#{Float.round(milliseconds / 1_000, 1)}s"

  # Suggested windows are rounded up to something a person would have typed.
  defp suggested_window(needed) when needed <= 10_000, do: ":timer.seconds(10)"

  defp suggested_window(needed) do
    ":timer.seconds(#{needed |> Kernel./(1_000) |> Float.ceil() |> trunc()})"
  end
end
