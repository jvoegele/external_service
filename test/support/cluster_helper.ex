defmodule ExternalService.TestSupport.ClusterHelper do
  @moduledoc false

  # Helpers invoked on a remote node in the distributed circuit breaker tests.
  #
  # These exist as named functions in a compiled module rather than as anonymous
  # functions in the test file because a closure sent across nodes needs its
  # defining module to be loadable there, and ExUnit test modules are never
  # written to disk. Everything under `test/support` is compiled into the
  # project's ebin directory, so the peer can load it from the code path.

  @retry_options [base: 1, max_attempts: 5]

  @doc """
  Trips `service`'s circuit breaker by failing calls until it opens, and returns
  the `ExternalService.CircuitBreakerOpen` error from a call it then rejects.

  Written as "fail until open, then one more" rather than "one failing call" so
  that it reads the same under either `:melt` setting. Under the default
  `:per_call`, a call charges the breaker once when its retrying gives up — so it
  takes `:tolerate` + 1 calls to open the breaker, and the call that opens it
  still reports its own failure rather than a rejection. Under `:per_attempt` a
  single call can do it, and this simply stops after one.
  """
  def trip(service) do
    :ok = fail_until_blown(service, 20)
    ExternalService.call(service, @retry_options, &always_retry/0)
  end

  defp fail_until_blown(_service, 0), do: :ok

  defp fail_until_blown(service, remaining) do
    if ExternalService.blown?(service) do
      :ok
    else
      ExternalService.call(service, @retry_options, &always_retry/0)
      fail_until_blown(service, remaining - 1)
    end
  end

  defp always_retry, do: :retry
end
