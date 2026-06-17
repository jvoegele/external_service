defmodule ExternalService.RetriesExhausted do
  @moduledoc """
  Raised or returned when the allowable number of retries (or the retry time
  budget) is exceeded while calling an external service.

  This is an [Errata](https://hexdocs.pm/errata) infrastructure error. The same
  value is returned in an `{:error, error}` tuple by `ExternalService.call/3` and
  raised by `ExternalService.call!/3`.

  Its `:context` contains:

    * `:service` — the fuse name the error relates to.
    * `:reason` — the retry reason: the value from the function's `{:retry, reason}`
      return, or `:reason_unknown` when the function returned a bare `:retry`.
  """
  use Errata.InfrastructureError,
    default_message: "exhausted all retries while calling the external service"
end

defmodule ExternalService.CircuitBreakerOpen do
  @moduledoc """
  Raised or returned when a call is rejected because the service's circuit breaker
  is open (the fuse is blown).

  This is an [Errata](https://hexdocs.pm/errata) infrastructure error. The same
  value is returned in an `{:error, error}` tuple by `ExternalService.call/3` and
  raised by `ExternalService.call!/3`. Its `:context` contains the `:service`
  (the fuse name) whose circuit breaker is open.
  """
  use Errata.InfrastructureError,
    default_message: "the circuit breaker for the external service is open"
end

defmodule ExternalService.ServiceNotStarted do
  @moduledoc """
  Raised or returned when a call is made to a service that has not been started
  with `ExternalService.start/2`.

  This is an [Errata](https://hexdocs.pm/errata) infrastructure error. The same
  value is returned in an `{:error, error}` tuple by `ExternalService.call/3` and
  raised by `ExternalService.call!/3`. Its `:context` contains the `:service`
  (the fuse name) that was not started.

  Unlike the other errors, this one indicates a programming/configuration mistake
  rather than a transient infrastructure failure, so its `http_status/1` is 500.
  """
  use Errata.InfrastructureError,
    default_message: "the external service has not been started"

  # Override the default infrastructure-error status (503): a service that was
  # never started is a programming/configuration error, not a transient outage.
  def http_status(_error), do: 500
end
