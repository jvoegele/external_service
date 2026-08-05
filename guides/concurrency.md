# Concurrency Limiting

Retries bound how hard you try, the circuit breaker bounds how many failures you
tolerate, and the rate limiter bounds how *often* calls start. None of them
bounds how many calls are **in flight at once**.

That is the gap that opens when a service degrades rather than fails. Requests
still succeed, just slowly. The breaker counts failures, so it sees nothing. The
rate limiter counts starts, not concurrency — so `limit: 100, per: 1_000` against
a service that slows to 10 seconds per call leaves roughly a thousand processes
parked in the same call, each holding a connection out of the pool and whatever
the caller had live. The breaker opens only once things actually start failing,
by which point the pressure is upstream of it.

A concurrency limit — the **bulkhead** pattern — caps that.

## Configuration

```elixir
use ExternalService,
  concurrency: [
    limit: 25,                            # at most 25 calls in flight
    reclaim_after: :timer.seconds(30)     # ...and a held slot expires after this
  ]
```

| Option           | Required | Meaning                                                                 |
| ---------------- | -------- | ----------------------------------------------------------------------- |
| `:limit`         | yes      | Maximum number of calls in flight against the service at once.          |
| `:reclaim_after` | yes      | Milliseconds after which a held slot is assumed abandoned and reused.   |

Concurrency limiting is **opt-in**: omit `:concurrency` and calls are never
capped.

## It sheds load, it does not smooth it

Over the limit, a call fails immediately with `ExternalService.ServiceSaturated`.
It does not queue — queueing is what the rate limiter's `:wait` budget is for,
and a queue of waiting processes is the pile-up this exists to prevent.

That makes the limit sharp, and worth sizing deliberately. With 400 callers
arriving at once against `limit: 8`, eight are admitted and the rest are shed
immediately:

```elixir
case MyApp.Api.fetch(id) do
  {:error, %ExternalService.ServiceSaturated{context: %{limit: limit}}} ->
    # We are at capacity for this dependency. Shed, don't wait.
    {:error, :busy}

  result ->
    result
end
```

`ServiceSaturated` reports `http_status/1` of `503`. That differs from
`ExternalService.RateLimited`'s `429` on purpose: a rate limit is the external
service refusing you, while saturation is *your own* bulkhead shedding load — a
"Service Unavailable" from your application, not a "Too Many Requests" from
theirs.

Because the wrapped function never ran, saturation does **not** melt the circuit
breaker and is **not** retried, exactly like rate limiting. Retrying immediately
would only find the bulkhead full again.

## Choosing a limit

Size it to the resource you are actually protecting, which is usually your
connection pool rather than the remote service. A limit at or just below your
pool size means the bulkhead rejects a call rather than letting it block waiting
for a connection — failing in a millisecond instead of queueing behind a pool
checkout.

A limit far larger than the pool protects nothing; one far smaller wastes
capacity you have paid for.

## What `:reclaim_after` is for

A slot is released as soon as the call finishes — including when it raises,
throws, or exits. What it cannot cover is the calling process being killed from
**outside**, because an exit signal does not run `after` blocks. That is not an
exotic case: it is the ordinary `:shutdown` a supervisor sends to in-flight
callers on every deploy that drains requests.

Without expiry, each of those would burn a slot permanently, and the service
would ratchet toward wedged until someone restarted it. `:reclaim_after` bounds
the damage to one slot for one window.

> #### Set it longer than your client's timeout {: .warning}
>
> Reclaiming a slot from a call that was merely *slow* means briefly running more
> than `:limit` calls at once. That is the intended trade — over-admitting for
> one window is much better than wedging forever — but it does mean too short a
> value silently defeats the limit.
>
> `:reclaim_after` is required rather than defaulted precisely because no
> universally correct value exists: it has to exceed the longest legitimate call,
> and only you know the timeout configured in your HTTP client. See
> [When the service hangs](circuit-breakers.md#when-the-service-hangs) — if you
> have not set a client timeout, there is no longest legitimate call.

## Retries take a slot per attempt

The slot is acquired per **attempt**, not per call, and released as soon as that
attempt finishes. A call sitting in backoff between attempts holds nothing, so
the limit tracks calls actually hitting the service rather than calls that happen
to be somewhere in a retry sequence.

One consequence worth knowing: a call can be rejected partway through its
retries, if the bulkhead filled up while it was backing off. That is honest
backpressure — the alternative is reserving capacity for a call that is currently
doing nothing.

The slot is also taken *inside* the rate limiter, so a caller sleeping on a
`:wait` budget holds no slot either.

## Asking before you commit

`ExternalService.saturated?/1` completes the trio with `available?/1` and
`rate_limited?/1`:

```elixir
if ExternalService.saturated?(:payments) do
  {:error, :busy}
else
  charge(build_expensive_request(order))
end
```

`ExternalService.Concurrency.in_flight/1` reports how many slots are held, which
is the more useful number to put on a dashboard:

```elixir
ExternalService.Concurrency.in_flight(:payments)   #=> 17
ExternalService.Concurrency.limit(:payments)       #=> 25
```

Like the other checks, these are best-effort: a slot can be taken or freed
between the check and the call, so they let you bail out early rather than
replacing handling of the error itself.

## Observing saturation

Every rejected call emits an
`[:external_service, :concurrency, :rejected]` telemetry event, with the
configured `:limit` in its measurements and the `:service` in its metadata.
A steady trickle usually means the limit is too low for normal traffic; a sudden
spike is the dependency slowing down. See the [Telemetry](telemetry.md) guide.

## How it works

State is an `:atomics` array with one slot per permit, so a concurrency limit
needs no process, supervisor, or registry — the same design as
`ExternalService.RateLimiter.Local`, and cheap enough not to matter on the hot
path (about 0.4µs for an uncontended acquire and release).

Each slot holds the monotonic millisecond deadline until which it counts as
occupied. There is deliberately no "free" sentinel value, because
`System.monotonic_time/1` may be negative — a slot is free precisely when its
deadline has passed. Acquiring scans from a slot derived from the caller's own
hash, so concurrent callers spread out rather than contending on the head of the
array, and takes the first free slot with a compare-and-exchange.

Releasing is also a compare-and-exchange rather than a write. That is what makes
reclamation safe: if a slow caller's slot was already reclaimed and handed to
someone else, its release finds a deadline it does not recognize and does
nothing, instead of evicting the new owner.

## Clearing leaked slots

`ExternalService.reset_all/1` frees every slot along with resetting the breaker
and the rate limiter. Outside of tests this is for clearing slots lost to killed
callers when `:reclaim_after` is long — it forgets that the slots were taken, it
does not stop any call that is genuinely running.

## What this does not do

It bounds concurrency **per node**, since the counters live in that node's
memory. Four nodes with `limit: 25` allow up to 100 concurrent calls at the
service. That is usually the right shape — the resource you are protecting, your
connection pool, is also per node — but if you need a cluster-wide ceiling it has
to come from somewhere else.

It also does not bound how long any single call takes; see
[When the service hangs](circuit-breakers.md#when-the-service-hangs). The two go
together: a concurrency limit without a client timeout fills with calls that
never finish, and only `:reclaim_after` saves it.
