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
          "precedence over the predicate."
    ],
    retry_exceptions: [
      type: {:list, :atom},
      default: [],
      doc:
        "Exception modules that should trigger a retry when raised. Defaults to `[]`, " <>
          "meaning raised exceptions are not retried; use `:retry`/`{:retry, reason}` return " <>
          "values, or the `:retry_on` predicate, to drive retries instead."
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
          retry_exceptions: [module()]
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
