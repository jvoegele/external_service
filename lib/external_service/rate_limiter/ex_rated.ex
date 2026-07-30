defmodule ExternalService.RateLimiter.ExRated do
  @moduledoc false

  # The default rate limiter backend: a thin wrapper over the `ex_rated` library.
  #
  # Counters live in node-local ETS, so in a cluster each node enforces the limit
  # independently and the external service sees up to `limit * node_count` calls
  # per window.

  @behaviour ExternalService.RateLimiter

  @impl true
  def init(service, options) do
    config = %{
      bucket: bucket_name(service),
      limit: Keyword.fetch!(options, :limit),
      window: Keyword.fetch!(options, :per)
    }

    {:ok, config}
  end

  @impl true
  def check(_service, %{bucket: bucket, window: window, limit: limit} = config) do
    case ExRated.check_rate(bucket, window, limit) do
      {:ok, _count} -> :ok
      {:error, _limit} -> {:wait, wait_time(config)}
    end
  end

  # The bucket name must be a string and unique per service. `inspect/1` yields a
  # stable, unique string for any term, so rate limiting works for any service
  # name — not only atoms (`Module.concat/2` would reject tuple or other non-atom
  # names, even though service names may be any term).
  @spec bucket_name(ExternalService.service()) :: String.t()
  def bucket_name(service), do: "#{inspect(__MODULE__)}/#{inspect(service)}"

  # `ex_rated` does not report how long is left in the current window, so the wait
  # is estimated as one call's worth of the window.
  defp wait_time(%{limit: limit, window: window}), do: trunc(Float.ceil(window / limit))
end
