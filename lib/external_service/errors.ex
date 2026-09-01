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

  When that reason is an exception — including any Errata error — it is also set
  as this error's `:cause`, so `Errata.root_error/1` reaches the underlying
  failure and `Errata.format_chain/1` prints the chain.

  ## Retryability

  Unlike the other errors here, this one is **not** retryable: it exists to say
  that retrying has already been tried and did not work. Note that Errata's
  classification has no notion of *when* — "not retryable" here means "not worth
  retrying now". Re-attempting the work at a coarser layer, such as a background
  job re-enqueuing itself minutes later, is a perfectly reasonable response to
  this error; it just isn't the question `Errata.retryable?/1` is answering.
  """
  use Errata.InfrastructureError,
    default_message: "exhausted all retries while calling the external service",
    retryable: false
end

defmodule ExternalService.CircuitBreakerOpen do
  @moduledoc """
  Raised or returned when a call is rejected because the service's circuit breaker
  is open (the fuse is blown).

  This is an [Errata](https://hexdocs.pm/errata) infrastructure error. The same
  value is returned in an `{:error, error}` tuple by `ExternalService.call/3` and
  raised by `ExternalService.call!/3`. Its `:context` contains the `:service`
  (the fuse name) whose circuit breaker is open.

  This error is retryable: the wrapped function never ran, and the breaker resets
  itself once its refresh window elapses.
  """
  use Errata.InfrastructureError,
    default_message: "the circuit breaker for the external service is open",
    retryable: true
end

defmodule ExternalService.RateLimited do
  @moduledoc """
  Raised or returned when a call could not be made within the service's
  configured rate limit `:wait` budget.

  This is an [Errata](https://hexdocs.pm/errata) infrastructure error. The same
  value is returned in an `{:error, error}` tuple by `ExternalService.call/3` and
  raised by `ExternalService.call!/3`.

  Its `:context` contains:

    * `:service` — the service the call was made against.
    * `:retry_after` — milliseconds until the call would have been admitted, as
      reported by the rate limiter backend.

  Only services that bound the wait can produce this error: `rate_limit: [wait:
  false]`, an explicit millisecond budget, or the default of one window (`:per`)
  capped at 5 seconds. Only `wait: :infinity` waits as long as it takes instead,
  and never produces this error. Because the wrapped function never ran, this
  does *not* melt the circuit breaker and is not retried — retrying immediately
  would only be throttled again.

  It is nevertheless retryable in Errata's sense: the call is worth making again
  once the limiter has room, and `:context.retry_after` says when that is.
  """
  use Errata.InfrastructureError,
    default_message: "the call was throttled beyond the configured rate limit wait time",
    retryable: true

  # Rate limiting maps naturally onto "Too Many Requests" rather than the default
  # infrastructure-error status (503).
  def http_status(_error), do: 429
end

defmodule ExternalService.ServiceSaturated do
  @moduledoc """
  Raised or returned when a call could not be made because the service's
  concurrency limit was already fully in use.

  This is an [Errata](https://hexdocs.pm/errata) infrastructure error. The same
  value is returned in an `{:error, error}` tuple by `ExternalService.call/3` and
  raised by `ExternalService.call!/3`.

  Its `:context` contains:

    * `:service` — the service the call was made against.
    * `:limit` — the configured concurrency limit.
    * `:in_flight` — how many slots were held when the call was rejected.

  Only services configured with a `:concurrency` limit can produce this error.
  Its `http_status/1` is the default `503`: unlike `ExternalService.RateLimited`,
  this is not the external service refusing you, it is your own bulkhead shedding
  load — a "Service Unavailable" from your application.

  Because the wrapped function never ran, this does *not* melt the circuit
  breaker and is not retried. Retrying immediately would only find the bulkhead
  full again; shedding is the point. See `ExternalService.Concurrency`.

  Like `ExternalService.RateLimited`, it is still retryable in Errata's sense —
  the call is worth making again once in-flight calls drain — just not on the
  spot.
  """
  use Errata.InfrastructureError,
    default_message: "the service's concurrency limit is fully in use",
    retryable: true
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
  rather than a transient infrastructure failure, so its `http_status/1` is 500
  and it is not retryable. Retrying cannot help: nothing changes until the
  service is started.
  """
  use Errata.InfrastructureError,
    default_message: "the external service has not been started",
    retryable: false

  # Override the default infrastructure-error status (503): a service that was
  # never started is a programming/configuration error, not a transient outage.
  def http_status(_error), do: 500
end
