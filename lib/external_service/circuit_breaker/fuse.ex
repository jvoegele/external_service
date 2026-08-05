defmodule ExternalService.CircuitBreaker.Fuse do
  @moduledoc """
  The default circuit breaker backend, built on the
  [`:fuse`](https://github.com/jlouis/fuse) library.

  This is the breaker `ExternalService` has always used, and you get it without
  configuring anything. It is **node-local**: each node counts its own failures
  and opens its own breaker, which is usually what you want — a node with a bad
  network path should stop calling the service without taking the rest of the
  cluster down with it.

  It is configured through the ordinary `:circuit_breaker` options (`:tolerate`,
  `:within`, `:reset`, `:fault_injection`); see `ExternalService.start/2`.
  """

  @behaviour ExternalService.CircuitBreaker

  alias :fuse, as: Fuse

  # `tolerate: :infinity` installs no fuse at all rather than one with a very
  # large tolerance. A fuse that is never asked and never melted is not just
  # cheaper — it holds no state, which is the point: an inert breaker cannot
  # accumulate melts across the tests that share it.
  @never_opens :never_opens

  @impl true
  def install(service, options) do
    if Keyword.fetch!(options, :tolerate) == :infinity do
      # A previously installed fuse under this name would otherwise keep
      # answering, so removal is what actually makes the breaker inert.
      _ = Fuse.remove(service)
      {:ok, @never_opens}
    else
      fuse_options = {strategy(options), {:reset, Keyword.fetch!(options, :reset)}}
      :ok = Fuse.install(service, fuse_options)
      {:ok, fuse_options}
    end
  end

  @impl true
  def ask(_service, @never_opens), do: :ok

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
  def melt(_service, @never_opens), do: :ok
  def melt(service, _config), do: Fuse.melt(service)

  @impl true
  def reset(_service, @never_opens), do: :ok
  def reset(service, _config), do: Fuse.reset(service)

  @impl true
  def remove(_service, @never_opens), do: :ok

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
  @spec tolerate(ExternalService.CircuitBreaker.config()) :: pos_integer() | :infinity
  def tolerate(@never_opens), do: :infinity
  def tolerate({{:standard, tolerate, _within}, _reset}), do: tolerate
  def tolerate({{:fault_injection, _rate, tolerate, _within}, _reset}), do: tolerate
end
