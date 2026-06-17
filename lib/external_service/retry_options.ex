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
      type: :pos_integer,
      doc: "Total time budget for retries, in milliseconds. Retrying stops once exceeded."
    ],
    max_attempts: [
      type: :pos_integer,
      doc:
        "Maximum number of attempts (the initial attempt plus retries). " <>
          "Defaults to no limit, bounded only by `:expiry` and/or the circuit breaker."
    ],
    jitter: [
      type: {:or, [:boolean, :float]},
      default: false,
      doc:
        "Random jitter applied to delays. `true` applies +/- 10%; a float (e.g. `0.25`) " <>
          "applies that proportion. Helps avoid retrying in lockstep (thundering herd)."
    ],
    retry_on: [
      type: {:list, :atom},
      default: [],
      doc:
        "Exception modules that should trigger a retry when raised. Defaults to `[]`, " <>
          "meaning raised exceptions are not retried; use `:retry`/`{:retry, reason}` return " <>
          "values to drive retries instead."
    ]
  ]

  @moduledoc """
  Options that control retry logic for calls to external services.

  Retry options can be given either as this struct or as a plain keyword list
  (which is validated and converted with `new/1`). The available options are:

  #{NimbleOptions.docs(@schema)}
  """

  @validated_schema NimbleOptions.new!(@schema)

  @type t :: %__MODULE__{
          backoff: :exponential | :linear,
          base: non_neg_integer(),
          factor: pos_integer(),
          cap: pos_integer() | nil,
          expiry: pos_integer() | nil,
          max_attempts: pos_integer() | nil,
          jitter: boolean() | float(),
          retry_on: [module()]
        }

  defstruct backoff: :exponential,
            base: 10,
            factor: 1,
            cap: nil,
            expiry: nil,
            max_attempts: nil,
            jitter: false,
            retry_on: []

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
end
