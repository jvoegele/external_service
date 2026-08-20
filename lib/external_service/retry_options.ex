defmodule ExternalService.RetryOptions do
  # This schema lives here while `:circuit_breaker`, `:rate_limit` and
  # `:concurrency` live in `external_service.ex`, which looks arbitrary and is not.
  # Those three are only ever given to `start/2`, and are documented there by
  # `NimbleOptions.docs/1`. Retry options are additionally passed *per call*, so
  # this module is public and renders its own schema into its own moduledoc — which
  # needs the schema local to it.
  #
  # The behavior these options describe lives in `ExternalService.Retry`; this
  # module is configuration only.
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

  @doc """
  Total time a fully-failing call spends *waiting between* attempts, in
  milliseconds.

  This is the number to compare against the latency budget of whoever is calling,
  and the one the circuit breaker's `:within` window has to be at least as wide as.
  Accepts a struct or the same keyword list `new/1` does.

      iex> RetryOptions.window(base: 100, max_attempts: 5)
      1500

      iex> RetryOptions.window(base: 100, max_attempts: 10)
      51100

      iex> RetryOptions.window(base: 100, max_attempts: 10, cap: 1_000)
      6500

  Note what it is *not*: the time the call takes. Nothing here bounds a single
  attempt, so a call's real duration is this plus however long its attempts run
  for — see [Nothing here bounds a single
  attempt](retries.md#nothing-here-bounds-a-single-attempt).

  ## Bounds

  With `:max_attempts` set (it defaults to `5`) the window is what the delays add
  up to. Without it, an `:expiry` is the answer, because unbounded retrying spends
  that budget exactly:

      iex> RetryOptions.window(base: 500, max_attempts: :infinity, expiry: 30_000)
      30000

  With neither bound there is no window to report:

      iex> RetryOptions.window(base: 500, max_attempts: :infinity)
      :infinity

  ## Jitter

  The window is reported nominally: `:jitter` is deliberately not sampled, so that
  the same configuration always reports the same window. A jittered call waits
  within that option's proportion of this figure — `true` meaning +/- 10% — rather
  than exactly it.

      iex> RetryOptions.window(base: 100, max_attempts: 5, jitter: true)
      1500
  """
  @spec window(t() | keyword()) :: non_neg_integer() | :infinity
  def window(retry_options), do: retry_options |> new() |> ExternalService.Retry.window()

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
