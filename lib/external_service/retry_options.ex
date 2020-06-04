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
  Struct representing the retry options to apply to calls to external services.

    * `backoff`: tuple describing the backoff strategy (see `t:backoff/0`)
    * `randomize`: boolean indicating whether or not delays between retries should be randomized
    * `expiry`: limit total length of time to allow for retries to the specified time budget
    *   milliseconds
    * `cap`: limit maximum amount of time between retries to the specified number of milliseconds
    * `rescue_only`: retry only on exceptions matching one of the list of provided exception types,
        (defaults to `[RuntimeError]`)
  """
  @type t :: %__MODULE__{
          backoff: backoff(),
          randomize: boolean(),
          expiry: pos_integer() | nil,
          cap: pos_integer() | nil,
          rescue_only: list(module())
        }

  defstruct backoff: {:exponential, 10},
            randomize: false,
            expiry: nil,
            cap: nil,
            rescue_only: [RuntimeError]

  def new(opts) do
    struct(__MODULE__, opts)
  end
end
