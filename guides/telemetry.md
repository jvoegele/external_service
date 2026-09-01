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

Emitted for each failed *attempt*: the function returned `:retry` /
`{:retry, reason}`, returned a value matched by the `:retry_on` predicate, or
raised an exception matched by `:retry_exceptions`. This is a per-attempt count,
**not** a melt count — under the default circuit-breaker `:melt` setting
(`:per_call`), a call that retries four times and then succeeds emits this event
four times and melts the breaker not at all. See
[`:tolerate` counts calls, not attempts](circuit-breakers.md#what-counts-as-a-failure).

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

### `[:external_service, :concurrency, :rejected]`

Emitted when a call is shed because the service's concurrency limit was fully in
use. A steady trickle usually means the limit is too low for normal traffic; a
sudden spike is the dependency slowing down.

- **Measurements:** `:limit` (the configured concurrency limit), `:wait_time`
  (milliseconds spent waiting, `0` unless a `:wait` budget is configured)
- **Metadata:** `:service`

### `[:external_service, :concurrency, :waited]`

Emitted when a call had to wait for a slot but got one before its `:wait` budget
ran out. Calls served without waiting emit nothing, so this measures only the
bursts a budget is absorbing.

- **Measurements:** `:limit`, `:wait_time` (milliseconds waited)
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
    [:external_service, :rate_limit, :sleep],
    [:external_service, :concurrency, :rejected],
    [:external_service, :concurrency, :waited]
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

  def handle_event([:external_service, :concurrency, :rejected], _measurements, %{service: svc}, _config) do
    Logger.warning("Shed a call to #{inspect(svc)}; concurrency limit full")
  end

  def handle_event([:external_service, :concurrency, :waited], %{wait_time: ms}, %{service: svc}, _config) do
    Logger.info("#{inspect(svc)} waited #{ms}ms for a concurrency slot")
  end
end
```

Every handler passed to `attach_many/4` must have a clause for each event it is
attached to — a `FunctionClauseError` on one event detaches the handler from
*all* of them, silently. That is why every event listed above has a matching
clause.

Attach handlers once at application start (for example in your
`Application.start/2`).

## Insights: the handler this library ships

Everything above is raw material. `ExternalService.Insights` is a handler built
from it that watches for one specific thing: a configuration that has stopped
doing what it was set up to do.

```elixir
# in your application's start/2, after the supervision tree is up
ExternalService.Insights.attach()
```

```
[ExternalService.Insights] :payments has failed 6 consecutive calls over 11.5s
with its circuit breaker still closed. It tolerates 5 failures within 10s, but
these are arriving about 2.3s apart, so at most 5 are ever counted together.

    circuit_breaker: [within: :timer.seconds(28)]

A failing call takes its retry window plus however long its attempts run for, and
only the first of those is in the configuration — which is why a window that
fitted when it was written stops fitting when the dependency slows down.
```

`ExternalService.explain/1` and `ExternalService.simulate/3` answer questions
about a configuration from the configuration. This answers the one they cannot:
whether what is *happening* matches it. The gap between the two is attempt
duration, which nothing in a configuration states — so a breaker sized correctly
on the day it was written goes quietly inert when the dependency slows down.

It is off by default and free until attached: no handlers, no storage, no cost on
any call. Attached, it costs a fixed dozen integers per service, updated without
locks, and starts no process. Findings are also available as data through
`ExternalService.Insights.report/1`, for a health endpoint or a test.

See `ExternalService.Insights` for what it looks for and how to quiet it.

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
