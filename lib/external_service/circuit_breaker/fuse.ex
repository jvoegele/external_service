defmodule ExternalService.CircuitBreaker.Fuse do
  @moduledoc false

  # The default circuit breaker backend: a thin wrapper over the `:fuse` library.
  #
  # This is the node-local breaker that `ExternalService` has always used. Each
  # node counts its own failures and opens its own breaker; see
  # `ExternalService.CircuitBreaker.Cluster` for a variant that propagates trips
  # across a cluster.

  @behaviour ExternalService.CircuitBreaker

  alias :fuse, as: Fuse

  @impl true
  def install(service, options) do
    fuse_options = {strategy(options), {:reset, Keyword.fetch!(options, :reset)}}
    :ok = Fuse.install(service, fuse_options)
    {:ok, fuse_options}
  end

  @impl true
  def ask(service, _config) do
    # `:fuse.ask/2` answers `{:error, :not_found}` for a breaker that does not
    # exist — which happens when a service is stopped while a call is in flight.
    # A missing breaker is reported as blown rather than leaking the backend's
    # error shape; "never started" is determined from the service state instead.
    case Fuse.ask(service, :sync) do
      :ok -> :ok
      _ -> :blown
    end
  end

  @impl true
  def melt(service, _config), do: Fuse.melt(service)

  @impl true
  def reset(service, _config), do: Fuse.reset(service)

  @impl true
  def remove(service, _config) do
    # `:fuse.remove/1` answers `{:error, :not_found}` for an unknown breaker;
    # ignoring that keeps removal idempotent.
    _ = Fuse.remove(service)
    :ok
  end

  @doc """
  Builds the `:fuse` strategy tuple for the given circuit breaker options.

  Exposed so that backends layered on top of this one (such as
  `ExternalService.CircuitBreaker.Cluster`) can reuse it.
  """
  @spec strategy(keyword()) :: tuple()
  def strategy(options) do
    tolerate = Keyword.fetch!(options, :tolerate)
    within = Keyword.fetch!(options, :within)

    case Keyword.get(options, :fault_injection) do
      nil -> {:standard, tolerate, within}
      rate -> {:fault_injection, rate, tolerate, within}
    end
  end

  @doc """
  Returns the number of failures the breaker tolerates before opening.

  Read back out of an installed breaker's config, so that a layered backend can
  work out how many melts it takes to trip this node's breaker.
  """
  @spec tolerate(ExternalService.CircuitBreaker.config()) :: pos_integer()
  def tolerate({{:standard, tolerate, _within}, _reset}), do: tolerate
  def tolerate({{:fault_injection, _rate, tolerate, _within}, _reset}), do: tolerate
end
