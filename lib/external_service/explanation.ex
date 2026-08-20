defmodule ExternalService.Explanation do
  @moduledoc false

  # Renders what a configuration will do, for `ExternalService.explain/1`.
  #
  # Everything here is derived rather than measured: the retry window comes from
  # `RetryOptions.window/1`, and how many failing calls open the breaker follows
  # from `:tolerate` and what one melt counts. That the numbers *can* be derived is
  # the point of the 3.0 tuning work — before it, this report would have had to say
  # "it depends" about most of its own lines.

  alias ExternalService.ConfigCheck
  alias ExternalService.RetryOptions

  @indent "  "

  @spec render(ExternalService.service(), keyword()) :: String.t()
  def render(service, options) do
    retry = RetryOptions.new(Keyword.get(options, :retry, []))
    breaker = Keyword.get(options, :circuit_breaker, [])

    [
      inspect(service),
      "",
      section("retry", retry_lines(retry)),
      section("circuit breaker", breaker_lines(breaker, retry)),
      section("rate limit", rate_limit_lines(Keyword.get(options, :rate_limit))),
      section("concurrency", concurrency_lines(Keyword.get(options, :concurrency))),
      section("a fully-failing call", call_lines(retry)),
      warnings(service, options)
    ]
    |> Enum.reject(&(&1 == nil))
    |> Enum.join("\n")
  end

  @doc false
  # Shared with `ConfigCheck` so that a duration reads the same in a warning as it
  # does in a report.
  @spec duration(non_neg_integer() | :infinity) :: String.t()
  def duration(:infinity), do: "unbounded"
  def duration(0), do: "none"
  def duration(milliseconds) when milliseconds < 1_000, do: "#{milliseconds}ms"

  def duration(milliseconds) do
    seconds = Float.round(milliseconds / 1_000, 1)

    seconds
    |> :erlang.float_to_binary(decimals: 1)
    |> String.replace_suffix(".0", "")
    |> Kernel.<>("s")
  end

  defp retry_lines(retry) do
    window = RetryOptions.window(retry)

    [
      {"window", "#{duration(window)}#{jittered(retry, window)}"},
      {"delays", delays(retry)},
      {"attempts", attempts(retry)},
      {"time budget", if(retry.expiry, do: duration(retry.expiry), else: "none (:expiry unset)")}
    ]
  end

  defp jittered(%RetryOptions{jitter: false}, _window), do: ""
  defp jittered(_retry, :infinity), do: ""

  defp jittered(%RetryOptions{jitter: jitter}, _window) do
    proportion = if jitter == true, do: 0.1, else: jitter
    " nominal, +/- #{round(proportion * 100)}% with jitter"
  end

  defp delays(retry) do
    case RetryOptions.window(retry) do
      :infinity ->
        "unbounded"

      _window ->
        # Nominal, for the same reason `RetryOptions.window/1` is: a report whose
        # numbers differ every time it is asked for is not a report.
        %RetryOptions{retry | jitter: false}
        |> ExternalService.Retry.plan()
        |> Enum.take(6)
        |> Enum.map(&duration/1)
        |> summarize(retry)
    end
  end

  defp summarize([], _retry), do: "none — a single attempt, never retried"

  defp summarize(delays, retry) do
    more = if retry.max_attempts == :infinity or retry.max_attempts > 7, do: ", ...", else: ""
    Enum.join(delays, ", ") <> more
  end

  defp attempts(%RetryOptions{max_attempts: :infinity}),
    do: "unbounded (:max_attempts is :infinity)"

  defp attempts(%RetryOptions{max_attempts: max_attempts}), do: "up to #{max_attempts}"

  defp breaker_lines(breaker, retry) do
    tolerate = Keyword.get(breaker, :tolerate, 10)
    melt = Keyword.get(breaker, :melt, :per_call)

    [
      {"opens after", opens_after(tolerate, melt, retry)},
      {"counting window", counting_window(breaker, tolerate, melt, retry)},
      {"resets after", duration(Keyword.get(breaker, :reset, 60_000))},
      {"backend", inspect(Keyword.get(breaker, :backend, ExternalService.CircuitBreaker.Fuse))}
    ]
  end

  defp opens_after(:infinity, _melt, _retry),
    do: "never — `tolerate: :infinity` installs no breaker"

  defp opens_after(tolerate, :per_call, _retry),
    do: "#{pluralize(tolerate + 1, "failing call")}"

  defp opens_after(tolerate, :per_attempt, %RetryOptions{max_attempts: max_attempts}) do
    calls =
      case max_attempts do
        :infinity ->
          "possibly the first call, part-way through its own retry loop"

        attempts ->
          "as few as #{pluralize(ceil((tolerate + 1) / attempts), "call")} at #{attempts} attempts each"
      end

    "#{tolerate + 1} failing attempts — #{calls}"
  end

  # `:within` is resolved by `start/2`, so a report for a started service shows the
  # number actually installed. A report for a proposed configuration may still say
  # `:auto`, which is honest: it is what that configuration says.
  defp counting_window(breaker, tolerate, melt, retry) do
    case Keyword.get(breaker, :within, :auto) do
      :auto -> ":auto — sized from the retry options"
      within -> "#{duration(within)}#{window_verdict(within, tolerate, melt, retry)}"
    end
  end

  defp window_verdict(within, tolerate, melt, retry) do
    case RetryOptions.window(retry) do
      :infinity ->
        ""

      0 ->
        ""

      window when melt == :per_call and within < window * tolerate ->
        " — narrower than #{tolerate} failing calls take; see below"

      window when melt == :per_attempt and within < window ->
        " — narrower than one call's retry window; see below"

      _window ->
        ""
    end
  end

  defp rate_limit_lines(nil), do: [{"none", "calls are not throttled"}]

  defp rate_limit_lines(rate_limit) do
    [
      {"limit",
       "#{inspect(Keyword.fetch!(rate_limit, :limit))} per #{duration(Keyword.fetch!(rate_limit, :per))}"},
      {"waits up to", wait(Keyword.get(rate_limit, :wait, :derived))}
    ]
  end

  defp wait(:derived), do: "one window, capped at 5s (the default)"
  defp wait(false), do: "nothing — a throttled call returns RateLimited immediately"
  defp wait(:infinity), do: "as long as it takes"
  defp wait(milliseconds), do: duration(milliseconds)

  defp concurrency_lines(nil), do: [{"none", "calls are not limited in flight"}]

  defp concurrency_lines(concurrency) do
    [
      {"limit", "#{Keyword.fetch!(concurrency, :limit)} in flight"},
      {"waits up to", wait(Keyword.get(concurrency, :wait, false))},
      {"reclaims after", duration(Keyword.fetch!(concurrency, :reclaim_after))}
    ]
  end

  # The distinction the tuning guide keeps having to restate: the retry window is
  # time spent *waiting between* attempts, and a call also spends however long its
  # attempts take, which nothing here bounds.
  defp call_lines(retry) do
    [
      {"spends", "#{duration(RetryOptions.window(retry))} waiting between attempts"},
      {"plus",
       "however long #{attempts_phrase(retry)} take — nothing here bounds a single attempt"}
    ]
  end

  defp attempts_phrase(%RetryOptions{max_attempts: :infinity}), do: "its attempts"

  defp attempts_phrase(%RetryOptions{max_attempts: max_attempts}),
    do: "its #{max_attempts} attempts"

  defp pluralize(1, noun), do: "1 #{noun}"
  defp pluralize(count, noun), do: "#{count} #{noun}s"

  defp section(title, lines) do
    width = lines |> Enum.map(fn {label, _value} -> String.length(label) end) |> Enum.max()

    body =
      Enum.map_join(lines, "\n", fn {label, value} ->
        "#{@indent}#{@indent}#{String.pad_trailing(label, width)}  #{value}"
      end)

    "#{@indent}#{title}\n#{body}\n"
  end

  defp warnings(service, options) do
    case ConfigCheck.run(service, options) do
      [] ->
        nil

      findings ->
        body = Enum.map_join(findings, "\n\n", &indent(&1.message))
        "#{@indent}warnings\n\n#{body}\n"
    end
  end

  defp indent(message) do
    message
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> ""
      line -> @indent <> @indent <> line
    end)
  end
end
