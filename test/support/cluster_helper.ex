defmodule ExternalService.Test.ClusterHelper do
  @moduledoc false

  # Helpers invoked on a remote node in the distributed circuit breaker tests.
  #
  # These exist as named functions in a compiled module rather than as anonymous
  # functions in the test file because a closure sent across nodes needs its
  # defining module to be loadable there, and ExUnit test modules are never
  # written to disk. Everything under `test/support` is compiled into the
  # project's ebin directory, so the peer can load it from the code path.

  @retry_options [base: 1, max_attempts: 5]

  @doc "Trips `service`'s circuit breaker by failing every attempt."
  def trip(service) do
    ExternalService.call(service, @retry_options, &always_retry/0)
  end

  defp always_retry, do: :retry
end
