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
| `:tolerate`        | `10`     | Number of failed **calls** tolerated within the `:within` window before the breaker opens (see below — `:melt` changes what counts as one). `:infinity` never opens. |
| `:within`          | `:auto`  | Length of the failure-counting window, in milliseconds. Sized automatically from the retry options; never below `10_000`. |
| `:reset`           | `60_000` | Milliseconds to wait before the breaker resets (closes) after opening.                         |
| `:fault_injection` | —        | If set to a rate between `0.0` and `1.0`, randomly fails that fraction of calls (for testing). |

So `tolerate: 5, within: 1_000` means "open the breaker once there have been more
than 5 failing calls inside any 1-second window." After opening, the breaker stays
open for `:reset` milliseconds, then closes again and calls resume under the same
monitoring.

The `:circuit_breaker` option (and every key within it) is optional. Omit it to
get the defaults above.

## What counts as a failure?

The breaker is "melted" — pushed one step toward opening — once per call whose
retrying gives up, where a failing attempt is one in which:

- the function returns `:retry` or `{:retry, reason}`, or
- the function returns a value matched by the `:retry_on` predicate, or
- the function raises an exception matched by the `:retry_exceptions` retry
  option — either by being one of the modules it lists, or by satisfying the
  predicate it holds.

> #### Melt and retry go together for exceptions {: .info}
>
> The `:retry_exceptions` retry option governs **both** whether a raised exception
> is retried **and** whether it melts the breaker. An exception `:retry_exceptions`
> matches is retried and melts the breaker; one it does not match is neither
> retried nor melted — it propagates to the caller and leaves the breaker
> untouched.
>
> Explicit `:retry` / `{:retry, reason}` return values, and results matched by the
> `:retry_on` predicate, always melt the breaker — they are ways of asking for
> another attempt.

Values your function simply returns — including its own `{:error, reason}` — are
successes as far as the breaker is concerned and do not melt it.

> #### `:tolerate` counts calls, not attempts {: .info}
>
> `:tolerate` reads like "how many failed calls before the breaker opens," and
> since 3.0 that is what it is. A call melts the breaker **once**, when its
> retrying gives up, however many attempts it made on the way. Measured with:
>
> ```elixir
> use ExternalService,
>   circuit_breaker: [tolerate: 10],
>   retry: [max_attempts: 5]
> ```
>
> ```
> failing calls #1..#10: returned RetriesExhausted,   blown? false
> failing call  #11:     returned RetriesExhausted,   blown? true
> failing call  #12:     returned CircuitBreakerOpen
> ```
>
> `:fuse` tolerates `:tolerate` melts and opens on the next, so `tolerate: 10`
> opens on the 11th failing call. Changing `:max_attempts` does not move that
> number.
>
> Note that a call which fails some attempts and then **succeeds** melts nothing
> at all. Retries did their job, and a breaker that opened on a call the caller
> saw succeed would turn working traffic into errors. If you want to see that a
> dependency is degraded even while it is succeeding, the
> `[:external_service, :call, :retry]` telemetry event counts attempts and fires
> for every one of them.
>
> Before 3.0 every failing *attempt* melted, so `:tolerate` and `:max_attempts`
> could not be tuned independently — with `max_attempts: 5` the configuration
> above opened during the **third** failing call rather than the eleventh, and
> raising the attempt count made a service give up *sooner*. Services that keep
> those semantics with `circuit_breaker: [melt: :per_attempt]` still need to
> budget in attempts: `:tolerate` as roughly *failing calls you will accept* ×
> `:max_attempts`. The library warns when such a configuration would let a call
> trip its own breaker part-way through its own retry loop.

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

It resets **only** the breaker. A service's rate limiter is separate state, and
clearing it releases a burst at the service — rarely what someone closing a
breaker intended. When you do want both, `ExternalService.reset_all/1` clears the
breaker and the limiter together:

```elixir
ExternalService.reset_all(:payments)
MyApp.Stripe.reset_all()
```

That is usually what a test `setup` block wants; see the [Testing](testing.md)
guide.

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

## When the service hangs

The breaker protects you against a service that **fails**. It has no answer for
one that **hangs**.

If your function blocks, `call/3` blocks with it. No failure has been observed,
so nothing melts the breaker, no retry is attempted, and no `:stop` telemetry is
emitted. Measured with `tolerate: 1` while a slow call is in flight:

```
available?: true
blown?:     false
```

That is correct behavior — the call hasn't failed, it just hasn't finished — but
it is the opposite of what "circuit breaker" leads people to expect. The pattern
as usually described pairs a breaker with a **timeout**, and the timeout is what
converts a hang into the failure the breaker counts. Without one, the most common
real degradation — service up, responses crawling — is invisible: latency climbs,
processes pile up, and nothing trips.

> #### `ExternalService` does not impose a timeout {: .warning}
>
> There is no `:timeout` option, and no retry option supplies one.
> [`:expiry` is evaluated between attempts](retries.md#nothing-here-bounds-a-single-attempt),
> so it cannot interrupt an attempt already running. **Bounding a single attempt
> is your responsibility, at the client.**

In practice this is where it belongs, because your HTTP client already has the
timeout that matters — it can actually abandon the socket, which the library
could not do from the outside:

```elixir
# Req
Req.get(url, receive_timeout: :timer.seconds(5))

# Finch
Finch.request(req, MyFinch, receive_timeout: :timer.seconds(5), pool_timeout: :timer.seconds(1))

# Tesla / Hackney
Tesla.get(client, path, opts: [adapter: [recv_timeout: :timer.seconds(5)]])
```

Set the pool checkout timeout too, not just the receive timeout. Under saturation
you block waiting for a connection before you ever send a request, and only the
checkout timeout bounds that.

Once the client times out, the wrapped function returns or raises — which *is* an
observable failure, so it melts the breaker and can be retried like any other:

```elixir
def fetch(id) do
  call fn ->
    case Req.get(url(id), receive_timeout: :timer.seconds(5)) do
      {:ok, %{status: status} = resp} when status < 500 -> {:ok, resp}
      # Timeouts and 5xx are worth another attempt; both melt the breaker.
      _ -> :retry
    end
  end
end
```

Why the library doesn't do this for you: running each attempt in a `Task` would
put a process on the hot path, which is the cost this library exists to avoid,
and it would not help as much as it appears. Killing the task stops you *waiting*
for the socket but does not cancel the request — the connection can stay checked
out, so the timeout masks saturation rather than relieving it. It would also move
your function off the calling process, so anything it reads from there — `Logger`
metadata, OpenTelemetry context, Ecto sandbox ownership — would silently change.

Note that a timeout bounds each call but does not bound how many are in flight at
once. For that, see [Concurrency Limiting](concurrency.md) — and note the two go
together, since a concurrency limit whose calls never finish just fills up.

## When the client retries too

The client is also where retries tend to live by default, and unlike the timeout,
they are not wanted there.

`Req` is the clearest case, because it retries out of the box: `retry:
:safe_transient` retries **GET and HEAD** requests on 408/429/500/502/503/504 and
on transport timeouts, refusals and closed connections, three times, with its own
exponential backoff (roughly 0.9s, 2s, 4s). Wrapped in `call/3` that nests — each
attempt this library makes becomes four requests:

```
max_attempts: 3, against a service returning 500

Req defaults    12 requests
retry: false     3 requests
```

Turn them off, and leave the client owning the timeout:

```elixir
# The client owns the timeout. ExternalService owns retrying.
Req.get(url, retry: false, receive_timeout: :timer.seconds(5))
```

| Client | Retries on its own? |
| --- | --- |
| `Req` | **Yes.** Three retries on GET/HEAD. Pass `retry: false`. |
| `Tesla` | No — `Tesla.Middleware.Retry` is opt-in. Leave it out of the stack. |
| `Finch` | No, apart from re-dispatching a request whose HTTP/2 pool is draining. |
| `:hackney`, `HTTPoison` | No. |

The request count is the least of it. The retrying happens *below* `call/3`, so
none of the four mechanisms can see it:

- `[:external_service, :call, :retry]` never fires for those attempts, so the
  retry rate in [Telemetry](telemetry.md) under-reports by whatever the client
  did.
- The breaker melts once per call that gives up, so a nested storm is one melt —
  and none at all when the client's own retry eventually succeeds. The failures
  it hid are the ones `:tolerate` was counting.
- `ExternalService.explain/1`, `ExternalService.simulate/3` and
  `ExternalService.Insights` describe a call profile your application does not
  have, and the [compile-time configuration warnings](tuning.md) test `:within`
  against a retry window that is not the real one.

Everything in [Tuning](tuning.md) works out what a service will do from its
configuration alone. A client retrying underneath makes those answers wrong
without anything failing to say so.

## What this library does not bound

One thing, and it is [the hang](#when-the-service-hangs):

| Not bounded | Where it belongs |
| --- | --- |
| How long one attempt may take | Your HTTP client's receive and pool-checkout timeouts. |

Everything else has a bound available: failures with `:tolerate`, attempts with
`:max_attempts`/`:expiry`, call *rate* with `:rate_limit`, and calls *in flight*
with `:concurrency`.

The last two are easy to confuse. The rate limiter bounds how *often* calls
start, which is not the same as how many are running: at `limit: 100, per: 1_000`
against a service that slows to 10 seconds per call, roughly a thousand processes
end up parked in the same call, each holding a connection. That is what a
[concurrency limit](concurrency.md) caps, and the breaker only opens once things
actually start failing — by which point the pressure is upstream of it.

## Fault injection (for testing)

The `:fault_injection` option makes the breaker fail a random fraction of calls,
which is useful for exercising your own fallback and error-handling paths:

```elixir
use ExternalService,
  circuit_breaker: [tolerate: 5, within: 1_000, fault_injection: 0.25]
```

This is a testing aid — leave it unset in production.

## A breaker that never opens

`tolerate: :infinity` installs **no breaker at all**. Calls are never rejected,
melts are ignored, and the service holds no breaker state:

```elixir
use ExternalService,
  circuit_breaker: [tolerate: :infinity]
```

Two situations want this.

**In production**, for a service where opening the breaker is worse than the
failures it would prevent — an idempotent write to a queue you'd rather keep
retrying, say — while you still want the retry and telemetry machinery. It says
that deliberately, where `tolerate: 1_000_000` only says "not for a while".

**In tests**, because a breaker that holds no state cannot leak between them.
`:tolerate` is normally the awkward one: it is global to the service and nothing
resets it between tests, so a suite long enough to accumulate `:tolerate` melts
starts failing tests that have nothing to do with the breaker. A finite number
merely postpones that. See the [Testing](testing.md) guide.

`:infinity` cannot be combined with `:fault_injection` — one promises the breaker
never opens and the other exists to open it — so `start/2` raises rather than
letting either silently win:

```
** (ArgumentError) ExternalService.start(:payments, ...) sets both
circuit_breaker: [tolerate: :infinity] and :fault_injection, which contradict
each other.
```

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
- Leave `:within` to size itself unless you know how long a single *attempt*
  takes. It is computed from your retry settings, and the one thing no
  configuration states is attempt duration — which is exactly what makes a
  hand-set window too narrow. The [Tuning](tuning.md) guide has the measurements.

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
