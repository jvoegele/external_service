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
| `:wait`          | no       | Milliseconds a call may wait for a slot. Defaults to `false` — shed at once. |

Concurrency limiting is **opt-in**: omit `:concurrency` and calls are never
capped.

## What happens over the limit

Nothing is dropped. A call over the limit returns
`ExternalService.ServiceSaturated` to its caller — the library declines to
*start* the call and hands control straight back. What happens next is yours to
decide:

```elixir
case MyApp.Api.fetch(id) do
  {:error, %ExternalService.ServiceSaturated{}} ->
    # Any of these is a legitimate answer. The request is still yours.
    MyApp.Queue.enqueue(:fetch, id)          # do it later
    # or: MyApp.Cache.stale(id)              # serve something older
    # or: {:error, :busy}                    # 503 with a Retry-After
    # or: retry at your own layer            # the next call may well succeed

  result ->
    result
end
```

**There is no cooldown.** Unlike the circuit breaker, which stays open for
`:reset` once tripped, a concurrency limit has no lockout at all: the moment a
call finishes, its slot is free and the next caller takes it. Recovery is not
something you have to arrange — it is continuous.

`ServiceSaturated` reports `http_status/1` of `503`. That differs from
`ExternalService.RateLimited`'s `429` on purpose: a rate limit is the external
service refusing you, while saturation is *your own* bulkhead shedding load — a
"Service Unavailable" from your application, not a "Too Many Requests" from
theirs.

Because the wrapped function never ran, saturation does **not** melt the circuit
breaker and is **not** retried inside the call, exactly like rate limiting.

### It only fires above capacity

Shedding is proportional to overload, not a cliff. Measured with `limit: 8` and
20ms calls — a capacity of roughly 400 calls per second:

| Offered load             | Shed  |
| ------------------------ | ----- |
| 25% of capacity          | 0%    |
| 50% of capacity          | 0%    |
| at capacity              | 12%   |
| 2× capacity              | 54%   |

Below capacity the limit never fires. Above it, the calls being shed are ones
that could not have been served anyway — and the point is what happens to the
rest. Without a limit those callers do not disappear; they park in your
application, each holding a connection, degrading the calls that *could* have
succeeded and every other endpoint sharing the node. Shedding protects the work
you can actually do.

## Absorbing bursts with `:wait`

By default a call over the limit is shed immediately. That is the right default,
but it is strict: a burst that would have cleared in 30ms is shed anyway.

A **bounded** wait budget absorbs that:

```elixir
concurrency: [
  limit: 25,
  reclaim_after: :timer.seconds(30),
  wait: 50                            # wait up to 50ms for a slot
]
```

A waiting caller holds **no slot** and no connection — it is parked, and the
number parked is bounded by arrival rate × budget, so this smooths bursts without
reintroducing the pile-up the limit exists to prevent. If the budget runs out,
you get `ServiceSaturated` exactly as before.

| `:wait` value | Behavior                                                     |
| ------------- | ------------------------------------------------------------ |
| `false`       | Shed immediately. **The default.**                           |
| milliseconds  | Wait up to this long for a slot, then shed.                  |

Start small. A budget in the tens of milliseconds absorbs jitter; one in the
hundreds starts adding real latency to the requests you are trying to protect.

> #### `:infinity` is not accepted here {: .warning}
>
> The rate limiter's `:wait` accepts `:infinity`, because sleeping until a quota
> refills is bounded by the quota itself. A slot only frees when another call
> finishes, so nothing bounds waiting for one — an unbounded wait *is* the
> unbounded pile-up. `start/2` raises rather than accepting it.

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
configured `:limit` and `:wait_time` (milliseconds spent waiting, `0` unless a
`:wait` budget is configured) in its measurements and the `:service` in its
metadata. A steady trickle usually means the limit is too low for normal
traffic; a sudden spike is the dependency slowing down.

A call that had to wait for a slot but got one before its `:wait` budget ran out
instead emits `[:external_service, :concurrency, :waited]`, with `:limit` and
`:wait_time` (milliseconds actually waited) in its measurements. Calls served
without waiting emit nothing, so this measures only the bursts a `:wait` budget
is absorbing. See the [Telemetry](telemetry.md) guide.

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
