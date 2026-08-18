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
        "Total time budget for retries, in milliseconds. Retrying stops once exceeded. " <>
          "Defaults to no time budget; `:infinity` states that explicitly (see the note " <>
          "on unbounded retries below)."
    ],
    max_attempts: [
      type: {:or, [:pos_integer, {:in, [:infinity]}]},
      doc:
        "Maximum number of attempts (the initial attempt plus retries). " <>
          "Defaults to no limit; `:infinity` states that explicitly (see the note on " <>
          "unbounded retries below)."
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

  ## Unbounded retries

  Neither `:max_attempts` nor `:expiry` has a default, so options that set
  neither place **no bound on retrying**: a call that keeps returning `:retry`
  keeps retrying forever. The circuit breaker is not a reliable backstop for
  this — exponential backoff widens the gap between attempts until failures no
  longer accumulate fast enough to open it. Almost always, you want one of these
  set. See [Bounding retries](retries.md#bounding-retries) for the details.

  `ExternalService.start/2` logs a warning when a service's default retry
  options leave both unset. If unbounded retrying really is what you want — or
  every call site supplies its own bound — say so explicitly with `:infinity`,
  which behaves identically but silences the warning:

      ExternalService.start(:my_service, retry: [max_attempts: :infinity])
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
            max_attempts: nil,
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
    import Retry.DelayStreams

    base_stream =
      case retry_opts.backoff do
        :exponential -> exponential_backoff(retry_opts.base)
        :linear -> linear_backoff(retry_opts.base, retry_opts.factor)
      end

    base_stream
    |> apply_jitter(retry_opts.jitter)
    |> apply_if(retry_opts.cap, &cap/2)
    |> apply_expiry(retry_opts.expiry)
    |> apply_max_attempts(retry_opts.max_attempts)
  end

  # `jitter` accepts a boolean or an explicit proportion. Note that
  # `Retry.DelayStreams.randomize/2` expects a number, so a bare `true` must use
  # the arity-1 default rather than being passed through.
  defp apply_jitter(stream, proportion) when is_number(proportion),
    do: Retry.DelayStreams.randomize(stream, proportion)

  defp apply_jitter(stream, true), do: Retry.DelayStreams.randomize(stream)
  defp apply_jitter(stream, _falsy), do: stream

  defp apply_if(stream, nil, _fun), do: stream
  defp apply_if(stream, value, fun), do: fun.(stream, value)

  # Both bounds distinguish `nil` (never set) from `:infinity` (explicitly
  # unbounded) so that `start/2` can warn about the former, but the two behave
  # identically here: neither limits the delay stream.
  defp apply_expiry(stream, unbounded) when unbounded in [nil, :infinity], do: stream
  defp apply_expiry(stream, expiry), do: Retry.DelayStreams.expiry(stream, expiry)

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
