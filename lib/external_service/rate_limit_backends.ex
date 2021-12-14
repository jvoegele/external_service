defmodule ExternalService.RateLimitBackends do
  @type bucket() :: String.t()
  @type window() :: pos_integer()
  @type limit() :: pos_integer()
  @type count() :: integer()

  @callback check_rate(bucket(), window(), limit()) :: {:ok, count()} | {:error, limit()}
  @callback inspect_bucket(bucket(), window(), limit()) ::
              {count :: integer(), count_remaining :: integer(), ms_to_next_bucket :: integer(),
               created_at :: integer() | nil, updated_at :: integer() | nil}
end
