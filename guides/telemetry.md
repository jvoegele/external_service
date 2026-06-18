# Telemetry

`ExternalService` emits [`:telemetry`](https://hexdocs.pm/telemetry) events so
that calls to external services can be observed and instrumented. Attach a
handler to forward them to your metrics or logging backend — StatsD, Prometheus
(via `TelemetryMetrics`), structured logs, or anything else.

Every event carries a `:service` key in its metadata identifying the service it
relates to.

## The events

### `[:external_service, :call, :start]`

Emitted when a guarded call begins.

- **Measurements:** `:system_time`, `:monotonic_time`
- **Metadata:** `:service`

### `[:external_service, :call, :stop]`

Emitted when a guarded call completes — including when it completes with an error
value such as `ExternalService.RetriesExhausted` or
`ExternalService.CircuitBreakerOpen`.

- **Measurements:** `:duration`, `:monotonic_time`
- **Metadata:** `:service`, `:result` (the value returned from the call)

### `[:external_service, :call, :exception]`

Emitted when a guarded call raises — for example a non-retriable exception from
your function, or `call!/3` raising on an open breaker or exhausted retries.

- **Measurements:** `:duration`, `:monotonic_time`
- **Metadata:** `:service`, `:kind`, `:reason`, `:stacktrace`

### `[:external_service, :call, :retry]`

Emitted each time a call's function fails in a way that melts the circuit breaker
(it returned `:retry` / `{:retry, reason}`, or it raised). Whether another
attempt is actually made depends on the retry options.

- **Measurements:** `:count` (always `1`)
- **Metadata:** `:service`, `:reason`

### `[:external_service, :circuit_breaker, :blown]`

Emitted when a call is rejected because the service's circuit breaker is open.

- **Measurements:** `:count` (always `1`)
- **Metadata:** `:service`

### `[:external_service, :rate_limit, :sleep]`

Emitted when a call is throttled and put to sleep to stay within the configured
rate limit.

- **Measurements:** `:sleep_time` (milliseconds)
- **Metadata:** `:service`

> #### Event names are a stable contract {: .info}
>
> The event names use `:circuit_breaker` (not the underlying `:fuse`)
> deliberately, so they remained stable through the 2.0 terminology changes.
> Treat them as a public API you can build dashboards on.

The `:call` events form a [`:telemetry.span/3`](https://hexdocs.pm/telemetry/telemetry.html#span/3),
so `:start` is always paired with either `:stop` or `:exception`, and the
`:duration` measurement is directly usable as call latency.

## Attaching a handler

A minimal handler that logs retries and breaker trips:

```elixir
:telemetry.attach_many(
  "external-service-logger",
  [
    [:external_service, :call, :retry],
    [:external_service, :circuit_breaker, :blown],
    [:external_service, :rate_limit, :sleep]
  ],
  &MyApp.ServiceTelemetry.handle_event/4,
  nil
)

defmodule MyApp.ServiceTelemetry do
  require Logger

  def handle_event([:external_service, :call, :retry], _measurements, %{service: svc, reason: reason}, _config) do
    Logger.warning("Retrying #{inspect(svc)}: #{inspect(reason)}")
  end

  def handle_event([:external_service, :circuit_breaker, :blown], _measurements, %{service: svc}, _config) do
    Logger.error("Circuit breaker open for #{inspect(svc)}")
  end

  def handle_event([:external_service, :rate_limit, :sleep], %{sleep_time: ms}, %{service: svc}, _config) do
    Logger.info("Rate limited #{inspect(svc)}; slept #{ms}ms")
  end
end
```

Attach handlers once at application start (for example in your
`Application.start/2`).

## With Telemetry.Metrics

If you use [`Telemetry.Metrics`](https://hexdocs.pm/telemetry_metrics), the
events map cleanly onto metric definitions:

```elixir
import Telemetry.Metrics

[
  # Call latency, tagged by service.
  summary("external_service.call.stop.duration",
    unit: {:native, :millisecond},
    tags: [:service]
  ),

  # How often calls fail and trigger a retry.
  counter("external_service.call.retry.count", tags: [:service]),

  # How often the breaker trips.
  counter("external_service.circuit_breaker.blown.count", tags: [:service]),

  # Time lost to rate-limit throttling.
  sum("external_service.rate_limit.sleep.sleep_time", tags: [:service])
]
```

These four signals — latency, retry rate, breaker trips, and throttle time —
give you a clear, per-service picture of the health of every external dependency
your application relies on.
