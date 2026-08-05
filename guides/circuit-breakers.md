# Circuit Breakers

The circuit breaker is what protects your application from a _persistently_
failing dependency. Where retries handle the occasional blip, the breaker
handles the outage: once a service fails too often, the breaker "opens" and
further calls fail fast — immediately, without touching the struggling service —
until it has had time to recover.

This is the mechanism described in Michael Nygard's _Release It!_ and popularized
by Martin Fowler. `ExternalService` implements it on top of the Erlang
[`:fuse`](https://github.com/jlouis/fuse) library, but you never call `:fuse`
directly — the breaker is managed for you on every call.

## Why fail fast?

When a dependency is down and you keep calling it, every caller blocks on
timeouts, work piles up, and the failure spreads — a _cascading_ failure. The
breaker short-circuits that: after enough failures it stops you from even
attempting the call, so callers get an immediate error they can handle (serve
cached data, degrade gracefully, return 503) instead of hanging.

Unlike retries, which are per-call, the breaker is **global to the service**. If
it trips, it trips for every caller in the system at once. That is precisely what
makes it effective at preventing cascades.

## Configuration

Configure the breaker with the `:circuit_breaker` option to `use
ExternalService` or `ExternalService.start/2`:

```elixir
use ExternalService,
  circuit_breaker: [
    tolerate: 5,                 # failures allowed within the window...
    within: :timer.seconds(1),   # ...this window, in milliseconds
    reset: :timer.seconds(5)     # stay open this long before resetting
  ]
```

| Option             | Default  | Meaning                                                                                        |
| ------------------ | -------- | ---------------------------------------------------------------------------------------------- |
| `:tolerate`        | `10`     | Number of failed **attempts** tolerated within the `:within` window before the breaker opens.  |
| `:within`          | `10_000` | Length of the failure-counting window, in milliseconds.                                        |
| `:reset`           | `60_000` | Milliseconds to wait before the breaker resets (closes) after opening.                         |
| `:fault_injection` | —        | If set to a rate between `0.0` and `1.0`, randomly fails that fraction of calls (for testing). |

So `tolerate: 5, within: 1_000` means "open the breaker once there are more than
5 failed attempts inside any 1-second window." After opening, the breaker stays open
for `:reset` milliseconds, then closes again and calls resume under the same
monitoring.

The `:circuit_breaker` option (and every key within it) is optional. Omit it to
get the defaults above.

## What counts as a failure?

The breaker is "melted" — pushed one step toward opening — on every call attempt
that fails, where a failure is:

- the function returns `:retry` or `{:retry, reason}`, or
- the function returns a value matched by the `:retry_on` predicate, or
- the function raises an exception whose type is listed in the `:retry_exceptions`
  retry option.

> #### Melt and retry go together for exceptions {: .info}
>
> The `:retry_exceptions` retry option governs **both** whether a raised exception
> is retried **and** whether it melts the breaker. An exception whose type is in
> `:retry_exceptions` is retried and melts the breaker; an exception that is *not*
> in `:retry_exceptions` is neither retried nor melted — it propagates to the
> caller and leaves the breaker untouched.
>
> Explicit `:retry` / `{:retry, reason}` return values, and results matched by the
> `:retry_on` predicate, always melt the breaker — they are ways of asking for
> another attempt.

Values your function simply returns — including its own `{:error, reason}` — are
successes as far as the breaker is concerned and do not melt it.

> #### `:tolerate` counts attempts, not calls {: .warning}
>
> The word doing the work above is **attempt**. `:tolerate` reads like "how many
> failed calls before the breaker opens," but retries melt too: one `call/3` with
> `max_attempts: 5` that fails throughout contributes 5 melts by itself.
>
> So `:tolerate` and `:max_attempts` cannot be tuned independently. Measured with
> this configuration:
>
> ```elixir
> use ExternalService,
>   circuit_breaker: [tolerate: 10, within: :timer.seconds(10)],
>   retry: [max_attempts: 5]
> ```
>
> ```
> failing call #1: returned RetriesExhausted,   blown? false
> failing call #2: returned RetriesExhausted,   blown? false
> failing call #3: returned CircuitBreakerOpen, blown? true
> ```
>
> A breaker that reads as "open after 10 failures" opens during the **third**
> failing call. (`:fuse` tolerates `:tolerate` melts and opens on the next, so
> `tolerate: 10` opens on the 11th melt; three calls × 5 attempts = 15 melts,
> crossing 11 partway through the third.) On a service handling any real
> concurrency that is a much shorter fuse than the numbers suggest — and the
> breaker is global, so those calls fail everything else too.
>
> Budget in attempts: pick `:tolerate` as roughly *failing calls you'll accept*
> × `:max_attempts`. The [Retries](retries.md) guide covers the same interaction
> from the other side — why the breaker is not a reliable bound on retries.

## When the breaker is open

A call made while the breaker is open does not invoke your function at all.
Instead:

- `call/3` returns `{:error, %ExternalService.CircuitBreakerOpen{}}`,
- `call!/3` raises `ExternalService.CircuitBreakerOpen`, and
- an `[:external_service, :circuit_breaker, :blown]` telemetry event is
  emitted.

See [Error handling](error-handling.md) for how to deal with these.

## Introspecting and resetting

You can ask about the breaker's state at any time. With the module front door:

```elixir
MyApp.Stripe.available?()   #=> true when the breaker is closed
MyApp.Stripe.blown?()       #=> true when the breaker is open
MyApp.Stripe.reset()        #=> force the breaker closed
```

Or with the functional API:

```elixir
ExternalService.available?(:payments)
ExternalService.blown?(:payments)
ExternalService.all_available?([:payments, :inventory])
ExternalService.reset(:payments)
```

A few semantics worth knowing:

- **`available?/1`** is `true` only when the breaker is closed. A service that
  was never started reports `false` — it is not "ready to use."
- **`blown?/1`** is the direct "is it open?" question. A service that was
  never started is _not_ reported as blown (there is no breaker to be open);
  use `available?/1` when you want "ready to use" semantics.
- **`all_available?/1`** is `true` only if _every_ listed service is
  `available?/1` — handy for guarding work that depends on several services.
- Availability can change between the check and a subsequent call, so treat
  these as best-effort signals, not guarantees. They let you bail out early;
  they do not replace handling a `CircuitBreakerOpen` error from the call
  itself.

`reset/1` forces the breaker closed immediately, discarding its recorded
failures. It is mainly useful in tests and in operational tooling ("we fixed the
upstream, stop failing fast now").

## Reporting a failure the library never saw

The breaker counts failures that happen inside `call/3`. Sometimes a service
fails somewhere else — a long-lived streaming connection drops, a webhook you
were expecting never arrives, a request made through a different client times
out. Those are real failures, and you can tell the breaker about them:

```elixir
ExternalService.CircuitBreaker.melt(:payments)
```

A melt counts toward the service's configured `:tolerate` exactly as an in-call
failure does, so enough of them will open the breaker — and with the
[cluster breaker](distributed.md), open it across the cluster. This is the
mirror image of `reset/1`: one forces the breaker closed, the other pushes it
toward open.

Use it sparingly and only for genuine failures of the service. Melting on
something that is not the service's fault will fail-fast traffic that would have
succeeded.

## Fault injection (for testing)

The `:fault_injection` option makes the breaker fail a random fraction of calls,
which is useful for exercising your own fallback and error-handling paths:

```elixir
use ExternalService,
  circuit_breaker: [tolerate: 5, within: 1_000, fault_injection: 0.25]
```

This is a testing aid — leave it unset in production.

## Choosing thresholds

There is no universally correct setting; it depends on the service's normal
error rate and how costly a false trip is. Some rules of thumb:

- Set `:tolerate`/`:within` so the breaker tolerates normal transient noise
  but trips promptly on a real outage. Counting failures over a window (rather
  than consecutively) makes it robust to interleaved success and failure.
- Set `:reset` to roughly how long you expect a recovering service to need. Too
  short and you hammer a service that isn't ready; too long and you stay
  degraded after it has recovered.
- Remember the breaker is global to the service. Size it for aggregate traffic,
  not a single caller.

## Running on more than one node

"Global to the service" means global *on this node*. Each node counts its own
failures and opens its own breaker, so in a cluster every node has to learn about
an outage separately.

That is usually the behavior you want — a node with a bad network path should
stop calling the service without taking the rest of the cluster with it — but it
does mean slower convergence. `ExternalService.CircuitBreaker.Cluster` trades
that isolation for speed, propagating a trip to the other nodes:

```elixir
use ExternalService,
  circuit_breaker: [
    tolerate: 5,
    within: :timer.seconds(1),
    backend: ExternalService.CircuitBreaker.Cluster
  ]
```

See the [Distributed Elixir](distributed.md) guide for how it works and what the
trade costs you.
