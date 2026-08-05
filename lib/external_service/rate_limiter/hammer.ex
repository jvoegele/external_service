defmodule ExternalService.RateLimiter.Hammer do
  @moduledoc """
  Rate limiter backend backed by a [Hammer](https://hexdocs.pm/hammer) rate
  limiter module.

  This is the supported route to **cluster-wide rate limiting**: point it at a
  Hammer module using a shared backend (such as
  [`hammer_backend_redis`](https://hexdocs.pm/hammer_backend_redis)) and every
  node in the cluster meters against the same counters, so the external service
  sees the limit you configured rather than that limit multiplied by your node
  count.

  Define and supervise a Hammer module as Hammer documents:

      defmodule MyApp.RateLimit do
        use Hammer, backend: Hammer.Redis
      end

      children = [{MyApp.RateLimit, url: "redis://localhost:6379"}]

  Then point a service at it:

      use ExternalService,
        rate_limit: [
          limit: 100,
          per: :timer.seconds(1),
          backend: {ExternalService.RateLimiter.Hammer, module: MyApp.RateLimit}
        ]

  ## Options

    * `:module` (required) - the Hammer rate limiter module to meter against.
    * `:key` - the Hammer key to meter under. Defaults to a key derived from the
      service name. Set this explicitly when several services (or several
      applications) should share one budget.

  `:hammer` is **not** a dependency of this library. The backend calls `hit/3` on
  the module you supply, which is Hammer's own API, so nothing needs to be added
  to your dependencies beyond Hammer itself.
  """

  @behaviour ExternalService.RateLimiter

  @impl true
  def init(service, options) do
    config = %{
      module: fetch_module!(options),
      key: Keyword.get(options, :key, default_key(service)),
      limit: Keyword.fetch!(options, :limit),
      window: Keyword.fetch!(options, :per)
    }

    {:ok, config}
  end

  @impl true
  def check(_service, %{module: module, key: key, window: window, limit: limit}) do
    # Hammer's `hit/3` both checks and consumes, and reports how many
    # milliseconds remain until the call would be admitted — a real wait time
    # rather than an estimate.
    case module.hit(key, window, limit) do
      {:allow, _count} -> :ok
      {:deny, retry_after} -> {:wait, retry_after}
    end
  end

  @impl true
  def peek(_service, %{module: module, key: key, window: window, limit: limit} = config) do
    # Hammer's `hit/3` both checks and consumes, so a non-consuming read has to
    # be assembled from `get/2` (the current count) and, where the algorithm
    # provides it, `expires_at/2`.
    if module.get(key, window) < limit, do: :ok, else: {:wait, wait_time(config)}
  end

  @impl true
  def reset(_service, %{module: module, key: key, window: window}) do
    # Hammer has no delete, but `set/3` writes the counter directly, and zero is
    # an untouched window as far as `hit/3` and `get/2` are concerned.
    _ = module.set(key, window, 0)
    :ok
  end

  defp wait_time(%{module: module, key: key, window: window} = config) do
    # `expires_at/2` is only defined for algorithms with a discrete window
    # (Hammer's fixed window), and answers an absolute wall-clock timestamp in
    # milliseconds — the same clock Hammer meters on — or `0` for no active
    # window.
    if function_exported?(module, :expires_at, 2) do
      case module.expires_at(key, window) do
        0 -> estimated_wait(config)
        expires_at -> max(1, expires_at - System.system_time(:millisecond))
      end
    else
      estimated_wait(config)
    end
  end

  # Without a real window expiry to read, one call's worth of the window is the
  # best available guess.
  defp estimated_wait(%{window: window, limit: limit}),
    do: trunc(Float.ceil(window / limit))

  @doc "The Hammer key used for a service when no `:key` option is given."
  @spec default_key(ExternalService.service()) :: String.t()
  def default_key(service), do: "external_service/#{inspect(service)}"

  defp fetch_module!(options) do
    case Keyword.get(options, :module) do
      nil ->
        raise ArgumentError,
              "#{inspect(__MODULE__)} requires a :module option naming the Hammer " <>
                "rate limiter module to meter against, for example " <>
                "backend: {#{inspect(__MODULE__)}, module: MyApp.RateLimit}"

      module when is_atom(module) ->
        module

      other ->
        raise ArgumentError,
              "#{inspect(__MODULE__)} expects :module to be a Hammer rate limiter " <>
                "module, got: #{inspect(other)}"
    end
  end
end
