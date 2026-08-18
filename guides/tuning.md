# Tuning

Each mechanism in this library is documented on its own page, and each is simple
enough on its own. Together they are not: the retry settings decide how fast the
circuit breaker trips, the backoff decides whether it trips at all, and the
attempt count decides how much load a failing dependency takes. This guide is
about choosing them together.

Every number here was measured against the library rather than derived.

## What you are actually choosing

Four things, and the setting that controls each:

| You want to control | Set | Don't reach for |
| --- | --- | --- |
| How long a failing call keeps trying | `:base`, `:cap` | `:max_attempts` |
| How many times a failing dependency gets hit | `:max_attempts` | — |
| When to give up regardless of how slow attempts are | `:expiry` | `:max_attempts` |
| When to stop calling the dependency at all | `:tolerate`, `:within` | — |

The first row is the one people get wrong. A longer retry window and more
attempts feel like the same thing, and they are not:

- **The window** costs you nothing but latency on a call that was already
  failing.
- **The attempt count** also multiplies the load you put on a struggling
  dependency, and spends the circuit breaker's failure budget.

So when you want to ride out a longer outage, raise `:base`. Reach for
`:max_attempts` only when you actually want *more attempts*.

## What a configuration costs

Total time a call spends waiting between attempts, with exponential backoff:

| `:max_attempts` | `base: 10` | `base: 50` | `base: 100` | `base: 500` |
| --- | --- | --- | --- | --- |
| 3 | 30ms | 150ms | 300ms | 1.5s |
| 4 | 70ms | 350ms | 700ms | 3.5s |
| **5** (default) | **150ms** | 750ms | **1.5s** | 7.5s |
| 6 | 310ms | 1.6s | 3.1s | 15.5s |
| 8 | 1.3s | 6.3s | 12.7s | 63.5s |
| 10 | 5.1s | 25.6s | 51.1s | 255.5s |

Read that table down a column rather than across a row. Each extra attempt costs
roughly as much as everything before it combined, so the last one or two attempts
account for most of the window.

`:cap` is what stops that runaway, and it matters more the more attempts you have:

| `:max_attempts` (`base: 100`) | uncapped | `cap: 1s` | `cap: 2s` |
| --- | --- | --- | --- |
| 5 | 1.5s | 1.5s | 1.5s |
| 8 | 12.7s | 4.5s | 7.1s |
| 10 | 51.1s | 6.5s | 11.1s |

At the default of five attempts a cap changes nothing. Past six it is the
difference between a bounded call and a minute-long one.

## Three couplings worth knowing

### `:base` multiplies with `:max_attempts`

This is the trap the first table exists to show. `base: 100` is the usual advice
for an HTTP dependency, and `max_attempts: 10` sounds merely thorough. Together
they are a **51-second call**, and nothing about either setting hints at the
other.

If you raise one, look at the table before raising the other.

### `:max_attempts` spends the breaker's failure budget

Every failing attempt melts the circuit breaker, so a fully-failing call spends
`:max_attempts` of the `:tolerate` budget by itself. Measured — consecutive
fully-failing calls before the breaker opens:

| `:tolerate` | `max_attempts: 3` | `5` | `8` | `10` |
| --- | --- | --- | --- | --- |
| 5 | 2 | 1 | **0** | **0** |
| 10 | 3 | 2 | 1 | 1 |
| 20 | 7 | 4 | 2 | 2 |
| 25 | 8 | 5 | 3 | 2 |

The zeros are not a rounding artifact. With `tolerate: 5` and `max_attempts: 8`,
a call melts the breaker five times partway through **its own retry loop**, and
the remaining attempts are rejected by the breaker it just opened. The first call
trips its own breaker mid-flight.

### `:within` has to be wider than the retry window

The breaker counts failures *within* a window. If a call's retries are spread
wider than that window, its melts never accumulate.

This is not a corner case. Until 3.0 this guide's own recommended configuration
had it — `tolerate: 5, within: 1s` alongside `base: 100, max_attempts: 5`, whose
retry window is about 1.5 seconds. Measured against it:

```
consecutive failing calls before the breaker opened: >20
elapsed: 30012ms of continuous failure
```

Thirty seconds of a dependency failing every single call, and the breaker stayed
closed — because at most four of each call's five melts ever landed inside the
same one-second window, and `:tolerate` was five.

**Rule: `:within` should be at least as wide as your retry window**, which is the
figure in the first table.

## Sizing the breaker against your retry settings

Those two couplings give a two-step rule:

1. **`:within` ≥ your retry window.** Read the window off the table above.
2. **`:tolerate` = (failing calls you are willing to absorb) × `:max_attempts`.**

Worked: you want the breaker to open after roughly three dead calls, with
`base: 100, max_attempts: 5` — a 1.5-second retry window.

```elixir
circuit_breaker: [tolerate: 15, within: :timer.seconds(5), reset: :timer.seconds(5)],
retry: [backoff: :exponential, base: 100, cap: 2_000, max_attempts: 5, expiry: 10_000, jitter: true]
```

Measured: the breaker opens on the **3rd** consecutive fully-failing call, and a
single failing call takes about 1.5 seconds.

Note what the `:expiry` is for there. It is not bounding the backoff — 1.5
seconds of waiting is nowhere near 10 seconds. It bounds the case the attempt
count cannot: a *slow* dependency, where five attempts at three seconds each
would otherwise mean fifteen seconds of call. `:expiry` is checked between
attempts, so it stops the next one rather than interrupting the current one; see
[Nothing here bounds a single attempt](retries.md#nothing-here-bounds-a-single-attempt).

## Three situations

### A request path

You have a latency budget, and a call that fails fast is better than one that
succeeds too late. Keep the retry window well inside the budget and let the
breaker do the rest.

```elixir
use ExternalService,
  circuit_breaker: [tolerate: 12, within: :timer.seconds(5), reset: :timer.seconds(5)],
  retry: [backoff: :exponential, base: 100, max_attempts: 4, expiry: 1_000, jitter: true]
  # :wait defaults to one window, which is what you want here
```

Measured: a fully-failing call takes about **650ms**, and the breaker opens on the
**3rd** consecutive one. After that, callers get `CircuitBreakerOpen` immediately
instead of waiting 650ms to fail.

### A background job

Nobody is waiting, and the work has nowhere else to go — so trade latency for
success. This is where the unbounded settings are correct rather than careless.

```elixir
use ExternalService,
  circuit_breaker: [tolerate: 20, within: :timer.seconds(30), reset: :timer.seconds(30)],
  retry: [
    backoff: :exponential,
    base: 500,
    cap: :timer.seconds(5),
    max_attempts: :infinity,
    expiry: :timer.seconds(30),
    jitter: true
  ],
  rate_limit: [limit: 100, per: :timer.seconds(1), wait: :infinity]
```

`max_attempts: :infinity` with an `:expiry` is the useful shape: keep trying, but
stop after half a minute. Unbounded on *both* is the one combination to avoid —
the breaker will not reliably rescue you, for the reason in
[Don't rely on the circuit breaker to bound retries](retries.md#bounding-retries).

If your job runner already retries failed jobs, prefer a modest bound here and
let re-enqueueing be the outer loop. Two retry layers multiply.

### A Flow pipeline

The important setting is `wait: :infinity`, and it is the one most easily missed.

```elixir
use ExternalService,
  circuit_breaker: [tolerate: 20, within: :timer.seconds(10)],
  retry: [backoff: :exponential, base: 100, cap: 2_000, max_attempts: 5, jitter: true],
  rate_limit: [limit: 100, per: :timer.seconds(1), wait: :infinity]
```

In a pipeline, sleeping is how back-pressure reaches upstream. A `:wait` budget
sheds work mid-pipeline instead of pacing it, and that work usually has nowhere
to go. See [Flow Pipelines](flow.md).

## Where the rate limiter fits

`:wait` defaults to one window (`:per`), capped at 5 seconds — enough to absorb a
burst, not enough to hide sustained saturation. Override it in two directions:

- **`:infinity`** for background work and pipelines, as above.
- **`false`**, or a budget well under one window, when your latency budget is
  tighter than the limiter's window and you would rather return `429` than wait.

Rate limiting composes with retries in a way worth noticing: a throttled call
that exhausts its `:wait` budget returns `RateLimited` **without** melting the
circuit breaker and without being retried, because the wrapped function never
ran. Throttling is not failure. See [Rate limiting](rate-limiting.md).

## A checklist

- [ ] Read your retry window off the table — is it inside the latency budget of whoever is calling?
- [ ] Is `:within` at least that wide?
- [ ] Is `:tolerate` about (calls you will absorb) × `:max_attempts`?
- [ ] If `:max_attempts` is above 6, is there a `:cap`?
- [ ] If either bound is `:infinity`, is the *other* one set?
- [ ] Is `:wait` right for the call site — default for a request path, `:infinity` for a pipeline or job?
- [ ] Is `:jitter` on, if many processes call this service?
