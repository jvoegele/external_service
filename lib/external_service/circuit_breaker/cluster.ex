defmodule ExternalService.CircuitBreaker.Cluster do
  @moduledoc """
  A circuit breaker that trips the whole cluster when any one node trips.

  The default breaker (`ExternalService.CircuitBreaker.Fuse`) is node-local:
  every node has to learn independently that a service is failing, so a cluster
  of N nodes sends roughly N times the failing traffic before all of them stop.
  This backend keeps that same local breaker but tells the other nodes when it
  opens, so they open too.

      use ExternalService,
        circuit_breaker: [
          tolerate: 5,
          within: :timer.seconds(1),
          reset: :timer.seconds(5),
          backend: ExternalService.CircuitBreaker.Cluster
        ]

  ## Options

    * `:nodes` - which nodes to notify, as a list or a zero-arity function
      returning a list. Defaults to `&Node.list/0` (every connected node). Supply
      a function when only some of your cluster calls the service:

          backend: {ExternalService.CircuitBreaker.Cluster, nodes: &MyApp.api_nodes/0}

  Every other option is passed through to the underlying `:fuse` breaker.

  ## How it works

  Each node keeps its own ordinary fuse. When a node's breaker **transitions**
  from closed to open, and only then, it sends a fire-and-forget
  `:erpc.multicast/4` to the other nodes. A node receiving that message trips its
  *own* breaker, which means its own reset timer then closes it on the normal
  schedule — there is no distributed state to keep, no shared store to reach, and
  no process or supervision tree that this library has to run.

  Only locally originated trips are broadcast, so a trip costs one round of
  messages rather than one per node per node.

  ## What this costs you

  This backend deliberately trades isolation for speed of convergence, and that
  trade is not always the right one:

    * **One node can trip the whole cluster.** If a single node has a bad network
      path while the service is healthy for everyone else, it will still take the
      cluster's breakers with it. If you would rather each node judge the service
      for itself — the bulkhead argument — stay on the default breaker.
    * **Propagation is best-effort.** The multicast is fire-and-forget: a message
      lost to a netsplit or a slow node simply means that node keeps its own
      counsel until it trips on its own, which is exactly the default behavior.
      Nothing breaks; convergence is just slower.
    * **Recovery is not coordinated.** Each node's reset timer runs
      independently. Because they trip at roughly the same moment they also reset
      at roughly the same moment, but they do not agree on it, and the first node
      to close will probe the service alone.
    * **A node that starts later does not catch up.** It learns the service is
      unhealthy the first time one of its own calls fails.

  Automatic resets are not broadcast (each node's timer handles its own), but an
  explicit `ExternalService.reset/1` is, since that is a deliberate
  administrative action.
  """

  @behaviour ExternalService.CircuitBreaker

  alias ExternalService.CircuitBreaker.Fuse, as: FuseBackend

  require Logger

  @impl true
  def install(service, options) do
    {nodes, fuse_options} = Keyword.pop(options, :nodes, &Node.list/0)
    validate_nodes!(nodes)

    {:ok, fuse_config} = FuseBackend.install(service, fuse_options)

    config = %{
      fuse: fuse_config,
      # How many melts it takes to trip *this* node's breaker. Each node reads
      # its own value, so the cluster does not have to agree on tolerances.
      tolerate: FuseBackend.tolerate(fuse_config),
      nodes: nodes
    }

    {:ok, config}
  end

  @impl true
  def ask(service, config), do: FuseBackend.ask(service, config.fuse)

  @impl true
  def melt(service, config) do
    # Only the closed -> open transition is broadcast. Melts that do not trip the
    # breaker, and melts that arrive while it is already open, cost nothing.
    #
    # Two callers melting concurrently can both observe the transition and both
    # broadcast. That is harmless — tripping an already-tripped breaker is a
    # no-op — and it is bounded by the number of in-flight calls, so it is not
    # worth a lock on the failure path to prevent.
    was_available = ask(service, config) == :ok
    :ok = FuseBackend.melt(service, config.fuse)

    if was_available and ask(service, config) == :blown do
      broadcast(config, :remote_trip, [service])
    end

    :ok
  end

  @impl true
  def reset(service, config) do
    result = FuseBackend.reset(service, config.fuse)
    broadcast(config, :remote_reset, [service])
    result
  end

  @impl true
  def remove(service, config), do: FuseBackend.remove(service, config.fuse)

  @doc false
  # Invoked on remote nodes via `:erpc.multicast/4`. Trips this node's breaker by
  # melting it past its own tolerance, so that the fuse's own reset timer takes
  # it from there. Never broadcasts, which is what keeps a trip from echoing
  # around the cluster.
  def remote_trip(service) do
    case local_config(service) do
      {:ok, config} ->
        Enum.each(0..config.tolerate, fn _ -> :fuse.melt(service) end)

        Logger.info(fn ->
          "[ExternalService] Circuit breaker for #{inspect(service)} tripped " <>
            "because a peer node's breaker opened."
        end)

      :error ->
        # The service is not started on this node, or is not using this backend.
        :ok
    end

    :ok
  end

  @doc false
  # Invoked on remote nodes via `:erpc.multicast/4` when a peer is explicitly
  # reset. Never broadcasts.
  def remote_reset(service) do
    case local_config(service) do
      {:ok, _config} -> :fuse.reset(service)
      :error -> :ok
    end

    :ok
  end

  defp local_config(service) do
    case ExternalService.State.fetch(service) do
      {:ok, %{circuit_breaker: {__MODULE__, config}}} -> {:ok, config}
      _ -> :error
    end
  end

  defp broadcast(config, function, args) do
    case resolve_nodes(config.nodes) do
      [] -> :ok
      nodes -> :erpc.multicast(nodes, __MODULE__, function, args)
    end

    :ok
  end

  defp resolve_nodes(nodes) when is_list(nodes), do: nodes
  defp resolve_nodes(fun) when is_function(fun, 0), do: fun.()

  defp validate_nodes!(nodes) when is_list(nodes), do: :ok
  defp validate_nodes!(fun) when is_function(fun, 0), do: :ok

  defp validate_nodes!(other) do
    raise ArgumentError,
          "#{inspect(__MODULE__)} expects :nodes to be a list of nodes or a " <>
            "zero-arity function returning one, got: #{inspect(other)}"
  end
end
