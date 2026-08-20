# Tuning

Each mechanism in this library is documented on its own page, and each is simple
enough on its own. Choosing them together used to be the hard part: the retry
settings decided how fast the circuit breaker tripped, and the breaker's window
decided whether it tripped at all.

Most of that is gone in 3.0. `:tolerate` counts failing calls, so it no longer
moves when you change `:max_attempts`; `:within` sizes itself against your retry
settings; and the configuration you write is checked against itself when you
compile it. What is left is one coupling worth understanding and a handful of
judgement calls, which is what this guide is about.

Every number here was measured against the library rather than derived.

## Ask the library first

Before reading further, ask your configuration what it does:

```elixir
use ExternalService,
  circuit_breaker: [tolerate: 3],
  retry: [backoff: :exponential, base: 100, max_attempts: 5]
```

```elixir
IO.puts ExternalService.explain(MyApp.Stripe)
```

```
MyApp.Stripe

  retry
    window       1.5s
    delays       100ms, 200ms, 400ms, 800ms
    attempts     up to 5
    time budget  none (:expiry unset)

  circuit breaker
    opens after      4 failing calls
    counting window  10s
    resets after     60s
    backend          ExternalService.CircuitBreaker.Fuse

  rate limit
    none  calls are not throttled

  concurrency
    none  calls are not limited in flight

  a fully-failing call
    spends  1.5s waiting between attempts
    plus    however long its 5 attempts take — nothing here bounds a single attempt
```

It takes a proposed keyword list as well as a started service, so you can try a
configuration before shipping it. Anything this guide warns about, it also warns
about — at compile time, on the line where the configuration is written.

## What you are actually choosing

Four things, and the setting that controls each:

| You want to control | Set | Don't reach for |
| --- | --- | --- |
| How long a failing call keeps trying | `:base`, `:cap` | `:max_attempts` |
| How many times a failing dependency gets hit | `:max_attempts` | — |
| When to give up regardless of how slow attempts are | `:expiry` | `:max_attempts` |
| How many failing calls before you stop calling | `:tolerate` | — |

The first row is the one people get wrong. A longer retry window and more
attempts feel like the same thing, and they are not:

- **The window** costs you nothing but latency on a call that was already
  failing.
- **The attempt count** also multiplies the load you put on a struggling
  dependency.

So when you want to ride out a longer outage, raise `:base`. Reach for
`:max_attempts` only when you actually want *more attempts*.

## What a configuration costs

Total time a call spends waiting between attempts, with exponential backoff.
`ExternalService.RetryOptions.window/1` answers this for any configuration; the
table is here to show the shape.

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
difference between a bounded call and a minute-long one — which is why the
library warns about an uncapped configuration above six attempts.

### The coupling that remains

`base: 100` is the usual advice for an HTTP dependency, and `max_attempts: 10`
sounds merely thorough. Together they are a **51-second call**, and nothing about
either setting hints at the other.

If you raise one, look at the table before raising the other — or ask
`explain/1`, which does it for you.

## Sizing the breaker

`:tolerate` is the number of failing calls you are willing to absorb; the breaker
opens on the next one. It is independent of `:max_attempts`, so this is now one
decision rather than an arithmetic problem:

```elixir
circuit_breaker: [tolerate: 3]
```

Measured with `base: 100, max_attempts: 5`: the breaker opens on the **4th**
consecutive fully-failing call, and a single failing call takes about 1.4
seconds.

`:within` — the window those failures are counted over — defaults to `:auto` and
is computed from your retry settings. Set it yourself only when you know
something the configuration does not, which is usually **how long your attempts
take**. A configuration states how long it waits *between* attempts and says
nothing about the attempts themselves, so a dependency that hangs for ten seconds
per attempt needs a wider window than `:auto` can know to ask for.

> #### The rule this section used to contain {: .info}
>
> Before 3.0, `:tolerate` counted failing *attempts*. Sizing a breaker meant
> multiplying by `:max_attempts` and then checking that `:within` was wider than
> the whole retry window, because a single call's melts were spread across it.
> Getting it wrong produced a breaker that never opened — as this guide's own
> recommended configuration did, staying closed through 20 consecutive failing
> calls over 30 seconds of continuous failure.
>
> Services that keep the old semantics with `circuit_breaker: [melt: :per_attempt]`
> still need that rule. The library warns when such a configuration has a
> `:tolerate` smaller than its `:max_attempts`, which is the case where a call
> trips its own breaker part-way through its own retry loop.

## Three situations

### A request path

You have a latency budget, and a call that fails fast is better than one that
succeeds too late. Keep the retry window well inside the budget and let the
breaker do the rest.

```elixir
use ExternalService,
  circuit_breaker: [tolerate: 3, reset: :timer.seconds(5)],
  retry: [backoff: :exponential, base: 100, max_attempts: 4, expiry: 1_000, jitter: true]
  # :wait defaults to one window, which is what you want here
```

Measured: a fully-failing call takes about **670ms**, and the breaker opens on the
**4th** consecutive one. After that, callers get `CircuitBreakerOpen` immediately
instead of waiting 670ms to fail. `:within` resolves to 10 seconds.

Note what the `:expiry` is for. It is not bounding the backoff — 700ms of waiting
is nowhere near a second. It bounds the case the attempt count cannot: a *slow*
dependency, where four attempts at three seconds each would otherwise mean twelve
seconds of call. `:expiry` is checked between attempts, so it stops the next one
rather than interrupting the current one; see
[Nothing here bounds a single attempt](retries.md#nothing-here-bounds-a-single-attempt).

### A background job

Nobody is waiting, and the work has nowhere else to go — so trade latency for
success. This is where the patient settings are correct rather than careless.

```elixir
use ExternalService,
  circuit_breaker: [tolerate: 3, reset: :timer.seconds(30)],
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
stop after half a minute. Unbounded on *both* is rejected outright — under the
default melt semantics a call that never gives up never melts the breaker, so
nothing would stop it.

Measured: a fully-failing call takes **30 seconds**, spending its budget exactly,
and the breaker opens on the **4th** consecutive one — two minutes into a total
outage. `:within` resolves to 180 seconds, which is what makes that possible: four
failures two minutes apart have to be counted over a window wider than two
minutes.

That number is worth pausing on. A slow service needs a *wider* counting window
than a fast one, not a narrower one, and it is the single most common thing to get
wrong by hand. Leave `:within` unset unless you know your attempts are slower than
your backoff.

If your job runner already retries failed jobs, prefer a modest bound here and
let re-enqueueing be the outer loop. Two retry layers multiply.

### A Flow pipeline

The important setting is `wait: :infinity`, and it is the one most easily missed.

```elixir
use ExternalService,
  circuit_breaker: [tolerate: 3],
  retry: [backoff: :exponential, base: 100, cap: 2_000, max_attempts: 5, jitter: true],
  rate_limit: [limit: 100, per: :timer.seconds(1), wait: :infinity]
```

Measured: a fully-failing call takes about **1.5 seconds** and the breaker opens
on the **4th** consecutive one.

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

Four of the seven items this guide used to carry are now checked for you when you
compile. What is left needs a human:

- [ ] Read your retry window off `explain/1` — is it inside the latency budget of whoever is calling?
- [ ] Is `:tolerate` the number of failing calls you are actually willing to absorb?
- [ ] Do you know how long a single *attempt* can take? Nothing here bounds it, and `:within` cannot size itself against it.
- [ ] Is `:wait` right for the call site — default for a request path, `:infinity` for a pipeline or job?
- [ ] Is `:jitter` on, if many processes call this service?
