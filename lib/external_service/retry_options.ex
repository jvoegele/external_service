defmodule ExternalService.RetryOptions do
  @schema [
    backoff: [
      type: {:in, [:exponential, :linear]},
      default: :exponential,
      doc: "The backoff strategy used to grow the delay between retries."
    ],
    base: [
      type: :non_neg_integer,
      default: 10,
      doc: "The initial delay between retries, in milliseconds (`0` for no delay)."
    ],
    factor: [
      type: :pos_integer,
      default: 1,
      doc: "Growth factor applied on each retry. Only used for `:linear` backoff."
    ],
    cap: [
      type: :pos_integer,
      doc: "Caps the delay between retries to at most this many milliseconds."
    ],
    expiry: [
      type: {:or, [:pos_integer, {:in, [:infinity]}]},
      doc:
        "Time budget for the retrying, in milliseconds. Delays that fit are used as-is; the " <>
          "delay that would overshoot the budget is trimmed instead, so the last attempt starts " <>
          "exactly at the deadline rather than past it. " <>
          "Defaults to no time budget; `:infinity` states that explicitly (see the note " <>
          "on unbounded retries below)."
    ],
    max_attempts: [
      type: {:or, [:pos_integer, {:in, [:infinity]}]},
      default: 5,
      doc:
        "Maximum number of attempts, counting the initial attempt — so the default of `5` " <>
          "is one try plus four retries. Use `:infinity` to retry without a count bound " <>
          "(see the note on unbounded retries below)."
    ],
    jitter: [
      type: {:or, [:boolean, :float]},
      default: false,
      doc:
        "Random jitter applied to delays. `true` applies +/- 10%; a float (e.g. `0.25`) " <>
          "applies that proportion. Helps avoid retrying in lockstep (thundering herd)."
    ],
    retry_on: [
      type: {:fun, 1},
      doc:
        "A predicate run on the *return value* of the call. When it returns a truthy value " <>
          "the call is retried, exactly as if the function had returned `:retry` (the result " <>
          "itself is used as the retry reason, and the circuit breaker melts). Lets you drive " <>
          "retries from a function that was not written to return `:retry`/`{:retry, reason}`. " <>
          "Defaults to no predicate. An explicit `:retry`/`{:retry, reason}` return always takes " <>
          "precedence over the predicate. A predicate that fails — raising, throwing, or " <>
          "exiting rather than answering — is treated as no match, leaving the result untouched, " <>
          "and logs a warning."
    ],
    retry_exceptions: [
      type: {:or, [{:list, :atom}, {:fun, 1}]},
      default: [],
      doc:
        "Which raised exceptions should trigger a retry, as either a list of exception modules " <>
          "or a predicate run on the exception itself. A predicate can decide per *instance* " <>
          "rather than per type — useful when the same exception type is sometimes transient " <>
          "and sometimes not. Defaults to `[]`, meaning raised exceptions are not retried; use " <>
          "`:retry`/`{:retry, reason}` return values, or the `:retry_on` predicate, to drive " <>
          "retries instead. An exception that is not matched also does not melt the circuit " <>
          "breaker, and once retries are spent the original exception is re-raised with its " <>
          "original stacktrace. A predicate that fails — raising, throwing, or exiting rather " <>
          "than answering — is treated as no match, so the exception it was asked to classify " <>
          "reaches the caller unchanged, and a warning is logged."
    ]
  ]

  @moduledoc """
  Options that control retry logic for calls to external services.

  Retry options can be given either as this struct or as a plain keyword list
  (which is validated and converted with `new/1`). The available options are:

  #{NimbleOptions.docs(@schema)}

  ## Bounds

  `:max_attempts` defaults to `5`, so retrying always stops on its own. With the
  default `:base` of `10` and exponential backoff that is a bound of four retries
  across roughly 150ms of waiting — deliberately a safety net rather than a tuned
  policy. If your dependency needs a longer retry window, raise `:base` (`100` is
  the usual choice for an HTTP service) rather than the attempt count.

  Note that this bound and the circuit breaker's `:tolerate` interact: every
  failing attempt melts the breaker, so five attempts melt five of the ten a
  default breaker tolerates, and two fully-failing calls open it.

  `:expiry` adds a time budget alongside the count; whichever is reached first
  stops the retrying. See [Bounding retries](retries.md#bounding-retries).

  ## Unbounded retries

  Retrying without a count bound is available, but it has to be asked for:

      ExternalService.start(:my_service, retry: [max_attempts: :infinity])

  Be deliberate about it. A call that keeps returning `:retry` then keeps
  retrying forever, and the circuit breaker is not a reliable backstop —
  exponential backoff widens the gap between attempts until failures no longer
  accumulate fast enough to open it. Pair it with an `:expiry`, or reserve it for
  work that genuinely has nowhere else to go.
  """

  @validated_schema NimbleOptions.new!(@schema)

  @type t :: %__MODULE__{
          backoff: :exponential | :linear,
          base: non_neg_integer(),
          factor: pos_integer(),
          cap: pos_integer() | nil,
          expiry: pos_integer() | :infinity | nil,
          max_attempts: pos_integer() | :infinity | nil,
          jitter: boolean() | float(),
          retry_on: (term() -> as_boolean(term())) | nil,
          retry_exceptions: [module()] | (Exception.t() -> as_boolean(term()))
        }

  defstruct backoff: :exponential,
            base: 10,
            factor: 1,
            cap: nil,
            expiry: nil,
            max_attempts: 5,
            jitter: false,
            retry_on: nil,
            retry_exceptions: []

  @doc """
  Builds a validated `RetryOptions` struct from a keyword list (or returns an
  existing struct unchanged).

  Raises `NimbleOptions.ValidationError` if the options are invalid.
  """
  @spec new(t() | keyword()) :: t()
  def new(%__MODULE__{} = retry_options), do: retry_options

  def new(opts) when is_list(opts) do
    validated = NimbleOptions.validate!(opts, @validated_schema)
    struct(__MODULE__, validated)
  end

  @doc false
  # The stream of delays, in milliseconds, that these options describe — one
  # element per retry, so an `n`-element stream means at most `n + 1` attempts.
  # The retry loop sleeps for each element in turn and stops when the stream is
  # exhausted.
  #
  # This is not part of the public API, but it is the seam the delay behavior is
  # tested through: the sequence can be inspected without waiting for it.
  @spec delay_stream(t()) :: Enumerable.t()
  def delay_stream(%__MODULE__{} = retry_opts) do
    retry_opts
    |> backoff_stream()
    |> apply_jitter(retry_opts.jitter)
    |> apply_cap(retry_opts.cap)
    |> apply_expiry(retry_opts.expiry)
    |> apply_max_attempts(retry_opts.max_attempts)
  end

  # The delay-stream builders below were originally provided by
  # `Retry.DelayStreams` from ElixirRetry (https://github.com/safwank/ElixirRetry,
  # Copyright 2014 Safwan Kamarrudin, Apache License 2.0), and are reimplemented
  # here so that the retry loop — and the sleeping it does — belongs to this
  # library. `delay_stream_test.exs` pins the sequences.
  #
  # They were ported behavior-for-behavior, and the backoff, jitter and cap
  # builders still are. `:expiry` has since diverged deliberately: it no longer
  # floors its final delay at 100ms, so a budget smaller than that is honored
  # rather than rounded up (issue #70).

  # Exponential backoff doubles the previous delay. `:factor` is not consulted:
  # it belongs to linear backoff, where it is the increment.
  defp backoff_stream(%__MODULE__{backoff: :exponential, base: base}) do
    Stream.unfold(base, fn previous -> {previous, previous * 2} end)
  end

  # Linear backoff adds `:factor` to the base delay once per retry taken.
  defp backoff_stream(%__MODULE__{backoff: :linear, base: base, factor: factor}) do
    Stream.unfold(0, fn retries -> {base + retries * factor, retries + 1} end)
  end

  # `jitter` accepts a boolean or an explicit proportion, with `true` meaning the
  # conventional +/- 10%.
  defp apply_jitter(stream, proportion) when is_number(proportion),
    do: randomize(stream, proportion)

  defp apply_jitter(stream, true), do: randomize(stream, 0.1)
  defp apply_jitter(stream, _falsy), do: stream

  # The shift spans `1 - max_delta` to `max_delta` rather than being symmetric
  # about zero, because `:rand.uniform/1` starts at 1. Delays are clamped at zero
  # so that jitter can never turn a short delay negative.
  defp randomize(stream, proportion) do
    Stream.map(stream, fn delay ->
      max_delta = round(delay * proportion)
      shift = random_uniform(2 * max_delta) - max_delta

      max(delay + shift, 0)
    end)
  end

  defp random_uniform(n) when n <= 0, do: 0
  defp random_uniform(n), do: :rand.uniform(n)

  # A cap clamps each delay without ending the stream — retrying continues, just
  # never further apart than this.
  defp apply_cap(stream, nil), do: stream
  defp apply_cap(stream, cap), do: Stream.map(stream, &min(&1, cap))

  # Both bounds distinguish `nil` (never set) from `:infinity` (explicitly
  # unbounded) so that `start/2` can warn about the former, but the two behave
  # identically here: neither limits the delay stream.
  defp apply_expiry(stream, unbounded) when unbounded in [nil, :infinity], do: stream

  defp apply_expiry(stream, expiry) do
    Stream.resource(
      fn -> {stream, now_ms() + expiry} end,
      fn
        :at_end -> {:halt, :at_end}
        {remaining, deadline} -> next_delay_within(remaining, deadline)
      end,
      fn _ -> :ok end
    )
  end

  # The budget is measured from the first time a delay is asked for — that is,
  # after the initial attempt has already run — so it bounds the retrying rather
  # than the call as a whole.
  #
  # The budget is spent, never overshot, and never abandoned early. A preferred
  # delay that still fits is used as-is; one that would overshoot is trimmed to
  # whatever is left, which places the final attempt exactly at the deadline. Only
  # a budget with nothing left in it stops without a further attempt.
  #
  # Trimming rather than halting matters more than it looks: halting on the first
  # delay that would overshoot abandons most of the budget under exponential
  # backoff — 630ms of a 1000ms budget, 2550ms of 5000ms — because the delay that
  # does not fit is roughly as large as everything before it combined.
  defp next_delay_within(remaining, deadline) do
    case Enum.take(remaining, 1) do
      [preferred] ->
        left = deadline - now_ms()

        cond do
          left <= 0 -> {:halt, :at_end}
          preferred >= left -> {[left], :at_end}
          true -> {[preferred], {Stream.drop(remaining, 1), deadline}}
        end

      [] ->
        {:halt, :at_end}
    end
  end

  # Monotonic rather than system time, so that a clock adjustment mid-call cannot
  # stretch or collapse a retry budget.
  defp now_ms, do: System.monotonic_time(:millisecond)

  # `max_attempts` counts the initial attempt plus retries, so the delay stream
  # (one delay per retry) is limited to `max_attempts - 1` elements.
  defp apply_max_attempts(stream, unbounded) when unbounded in [nil, :infinity], do: stream

  defp apply_max_attempts(stream, max_attempts)
       when is_integer(max_attempts) and max_attempts > 0,
       do: Stream.take(stream, max_attempts - 1)

  @doc """
  Layers a keyword list of per-call overrides onto a `base` struct.

  Only the keys actually present in `opts` are overridden; every other field is
  taken from `base`. This is how per-call retry options tweak — rather than
  reset — a service's configured defaults. A `%RetryOptions{}` given in place of
  the keyword list replaces `base` wholesale, since a struct is already a
  complete set of options.

  Raises `NimbleOptions.ValidationError` if `opts` is invalid.
  """
  @spec merge(t(), t() | keyword()) :: t()
  def merge(_base, %__MODULE__{} = retry_options), do: retry_options

  def merge(%__MODULE__{} = base, opts) when is_list(opts) do
    validated = NimbleOptions.validate!(opts, @validated_schema)
    overrides = Keyword.take(validated, Keyword.keys(opts))
    struct(base, overrides)
  end
end
