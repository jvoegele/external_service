defmodule ExternalService.RetryOptions do
  @moduledoc """
  Options used for controlling retry logic.
  See the [retry docs](https://hexdocs.pm/retry/Retry.html) for information about the available
  retry options.
  """

  @typedoc """
  A tuple describing the backoff strategy for increasing delay between retries.

  The first element of the tuple must be one of the atoms `:exponential` or `:linear`.
  In both cases, the second element of the tuple is an integer representing the initial delay
  between retries, in milliseconds.
  For linear delay, there is also a third element in the tuple, which is a number representing
  the factor that the initial delay will be multiplied by on each successive retry.
  """
  @type backoff ::
          {:exponential, initial_delay :: pos_integer()}
          | {:linear, initial_delay :: pos_integer(), factor :: pos_integer()}

  @typedoc """
  Controls how much random jitter is applied to the delay between retries.

    * `false` (the default) applies no jitter.
    * `true` applies the default jitter of +/- 10%.
    * a number between `0.0` and `1.0` applies that proportion of jitter
      (for example `0.25` for +/- 25%).

  Jitter helps avoid the "thundering herd" problem, where many clients that
  failed at the same time would otherwise retry in lockstep.
  """
  @type randomize :: boolean() | float()

  @typedoc """
  Struct representing the retry options to apply to calls to external services.

    * `backoff`: tuple describing the backoff strategy (see `t:backoff/0`)
    * `randomize`: how much random jitter to apply to delays (see `t:randomize/0`)
    * `expiry`: limit the total length of time to allow for retries to the
        specified time budget, in milliseconds
    * `max_attempts`: limit the total number of attempts (the initial attempt
        plus any retries) to the specified number; defaults to `nil` (no limit,
        bounded only by `expiry` and/or the circuit breaker)
    * `cap`: limit maximum amount of time between retries to the specified number of milliseconds
    * `rescue_only`: retry only on exceptions matching one of the list of provided exception types,
        (defaults to `[RuntimeError]`)
  """
  @type t :: %__MODULE__{
          backoff: backoff(),
          randomize: randomize(),
          expiry: pos_integer() | nil,
          max_attempts: pos_integer() | nil,
          cap: pos_integer() | nil,
          rescue_only: list(module())
        }

  defstruct backoff: {:exponential, 10},
            randomize: false,
            expiry: nil,
            max_attempts: nil,
            cap: nil,
            rescue_only: [RuntimeError]

  def new(opts) do
    struct(__MODULE__, opts)
  end
end
