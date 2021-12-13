if Code.ensure_loaded?(ExRated) do
  defmodule ExternalService.RateLimitBackends.ExRated do
    @behaviour ExternalService.RateLimitBackends

    @impl true
    def check_rate(bucket, window, limit) do
      ExRated.check_rate(bucket, window, limit)
    end

    @impl true
    def inspect_bucket(bucket, window, limit) do
      ExRated.inspect_bucket(bucket, window, limit)
    end
  end
end
