defmodule ExternalService.Test.StubLimiter do
  @moduledoc false

  # A rate limiter backend that answers from the calling process's dictionary, so
  # that tests can drive `{:wait, ms}` responses deterministically.

  @behaviour ExternalService.RateLimiter

  @denials :stub_limiter_denials

  @impl true
  def init(_service, options), do: {:ok, Map.new(options)}

  @impl true
  def check(_service, config) do
    case Process.get(@denials, 0) do
      0 ->
        :ok

      remaining ->
        Process.put(@denials, remaining - 1)
        {:wait, Map.get(config, :wait, 1)}
    end
  end

  @impl true
  def peek(_service, config) do
    # Reports the same answer as `check/2` without spending a denial, so tests
    # can tell a consuming check from a non-consuming peek.
    case Process.get(@denials, 0) do
      0 -> :ok
      _remaining -> {:wait, Map.get(config, :wait, 1)}
    end
  end

  @impl true
  def reset(_service, _config) do
    Process.delete(@denials)
    :ok
  end

  @doc "Makes the next `count` checks report `{:wait, _}`."
  def deny_next(count), do: Process.put(@denials, count)

  def reset, do: Process.delete(@denials)
end

defmodule ExternalService.Test.StubBreaker do
  @moduledoc false

  # A circuit breaker backend that records every operation in the calling
  # process's dictionary, so that tests can assert the seam dispatches and can
  # force the breaker open without involving `:fuse`.

  @behaviour ExternalService.CircuitBreaker

  @calls :stub_breaker_calls
  @blown :stub_breaker_blown

  @impl true
  def install(service, options) do
    record({:install, service})
    {:ok, Map.new(options)}
  end

  @impl true
  def ask(service, _config) do
    record({:ask, service})
    if Process.get(@blown, false), do: :blown, else: :ok
  end

  @impl true
  def melt(service, _config) do
    record({:melt, service})
    :ok
  end

  @impl true
  def reset(service, _config) do
    record({:reset, service})
    Process.put(@blown, false)
    :ok
  end

  @impl true
  def remove(service, _config) do
    record({:remove, service})
    :ok
  end

  @doc "Forces `ask/2` to report the breaker as open."
  def blow, do: Process.put(@blown, true)

  @doc "The operations the seam has dispatched, oldest first."
  def calls, do: Enum.reverse(Process.get(@calls, []))

  @doc "The operation names the seam has dispatched, oldest first."
  def call_names, do: Enum.map(calls(), &elem(&1, 0))

  def reset_stub do
    Process.delete(@calls)
    Process.delete(@blown)
  end

  defp record(call), do: Process.put(@calls, [call | Process.get(@calls, [])])
end
