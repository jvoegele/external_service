if Code.ensure_loaded?(Hammer) do
  defmodule ExternalService.RateLimitBackends.Hammer do
    @behaviour ExternalService.RateLimitBackends

    @impl true
    def check_rate(bucket, window, limit) do
      case Hammer.check_rate(bucket, window, limit) do
        {:allow, count} -> {:ok, count}
        {:deny, limit} -> {:error, limit}
        {:error, reason} -> raise reason
      end
    end

    @impl true
    def inspect_bucket(bucket, window, limit) do
      case Hammer.inspect_bucket(bucket, window, limit) do
        {:ok, info} -> info
        {:error, reason} -> raise reason
      end
    end
  end
end
