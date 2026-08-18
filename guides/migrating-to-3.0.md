# Migrating to 3.0

> #### Draft — one value is still undecided {: .error}
>
> This guide is written ahead of the 3.0 release. Everything below is settled
> except the single value marked **TBD**: the new `:wait` default, which the
> roadmap wants re-measured against the Hammer backend before it is committed to
> (#73). Fill it in and delete this note before 3.0 ships.

ExternalService 3.0 changes four things, and **nothing renames**. Your code
compiles unchanged; it behaves differently. That is exactly what makes this a
major version: there is no call site to fix, because the call sites were never
wrong — the *defaults* were.

Three of the four changes are defaults that used to mean "never give up".
Retrying without a bound, waiting for a rate limit without a bound, and a retry
time budget that quietly rounded itself up. Each now stops at a finite point, and
each has a one-line way to keep the old behavior if it was what you wanted.

> If your application has been running 2.4.0 or later, **you have already been
> told which of these affect you.** The two largest changes have warned at boot
> since then. See [Have you been warned already?](#have-you-been-warned-already)
> below — for many applications the answer is "none of this applies", and that
> question is answerable in a minute.

## At a glance

| Area                          | 2.x                                          | 3.0                                       | Keep 2.x behavior with        |
| ----------------------------- | -------------------------------------------- | ----------------------------------------- | ----------------------------- |
| Retry bound                   | unbounded — retries forever                  | `max_attempts: 5`                         | `retry: [max_attempts: :infinity]` |
| Rate limit wait               | unbounded — sleeps until admitted            | finite `:per`-derived `:wait` default     | `rate_limit: [wait: :infinity]` |
| `:expiry` under 100ms         | floors the last delay at 100ms and adds an attempt | trims the last delay to the budget  | no equivalent — see below     |
| `:decorator` dependency       | installed transitively                       | declare it yourself                       | add it to your `deps`         |

The first two are silent: same code, different behavior. The third is silent but
narrow. The fourth is loud — it fails your build with a clear message.

## Have you been warned already?

Since 2.4.0, `ExternalService.start/2` logs a warning for each of the two
unbounded defaults. Search your boot logs:

```
sets no retry bound: neither :max_attempts nor :expiry is configured
sets no rate limit wait budget: :wait is unset
```

- **Neither appears** → changes 1 and 2 do not affect you. You already configure
  both bounds explicitly.
- **One or both appear** → that service takes the new default in 3.0. The
  warning names the service and the one-line fix.

The warnings disappear in 3.0, because the defaults they were warning about are
gone.

## 1. Retries are bounded by default

Retry options that set neither `:max_attempts` nor `:expiry` used to retry
forever. The circuit breaker was not a reliable backstop for this: growing
backoff delays outpace its `:within` window, so a fully default breaker paired
with `retry: [base: 100]` never opens.

```elixir
# 2.x — retries until it succeeds, however long that takes
ExternalService.start(:my_service, circuit_breaker: [tolerate: 5, within: 1_000])

# 3.0 — the same call now stops after 5 attempts
```

**What you will see if this affects you.** A call that used to block until it
eventually succeeded now returns `{:error, %ExternalService.RetriesExhausted{}}`
— into a `case` that may have no clause for it. That is the failure mode to look
for: not a crash at the call site, but an unhandled error a few frames up.

**To keep the old behavior**, say so explicitly. `:infinity` has been accepted
since 2.4.0 for exactly this, so it is safe to add *before* upgrading:

```elixir
retry: [max_attempts: :infinity]
```

**Better, where you can:** pick a real bound. Unbounded retrying is almost never
what a request path wants, and a bound is what lets the circuit breaker do its
job. See [Retries](retries.md#bounding-retries).

Two things worth knowing about the number `5`. It is what
`ExternalService.start/2` has been suggesting in its warning since 2.4.0, so if
you took that advice you are already on the 3.0 default. And it is a **bound**
rather than a generous allowance: with the default `base: 10` and exponential
backoff the delays are `[10, 20, 40, 80]`, so a defaulted call waits at most
150ms across its four retries. If your dependency needs a longer retry window,
raise `:base` — `base: 100` is the usual choice for HTTP — rather than
`:max_attempts`.

It also restores the circuit breaker at its own defaults. Every failing attempt
melts, so five attempts melt five of the ten a default breaker tolerates: two
fully-failing calls open it. Today, a default breaker paired with default retry
options never opens at all, because growing backoff delays outpace its `:within`
window.

## 2. The rate limit wait is bounded by default

An unset `rate_limit: [:wait]` used to sleep the calling process until the
limiter admitted it. In a request path that converts sustained throttling into
unbounded latency and process growth rather than a fast `429` — even though
`ExternalService.RateLimited` already carries `retry_after` and maps to `429`.

```elixir
# 2.x — a throttled call waits as long as it takes
ExternalService.start(:my_service, rate_limit: [limit: 50, per: 1_000])

# 3.0 — the same call gives up after TBD and returns RateLimited
```

**To keep the old behavior:**

```elixir
rate_limit: [limit: 50, per: 1_000, wait: :infinity]
```

> #### Flow pipelines want the old behavior {: .warning}
>
> [Flow Pipelines](flow.md) recommends an unbounded wait, and is right to:
> sleeping is how back-pressure propagates upstream through a pipeline. A finite
> budget converts that into shedding work mid-pipeline.
>
> **If you run guarded calls inside a Flow or a background job, set
> `wait: :infinity` explicitly.** This is the one place where the 2.x default was
> the correct choice, and 3.0 makes you say so.

The new default is **TBD** — a budget derived from `:per` rather than `false`, because
`wait: false` sheds load a healthy service should absorb — roughly half of a 2×
burst, which makes bursty-but-fine traffic look like an outage.

## 3. `:expiry` no longer overshoots a small budget

`:expiry` is documented as a total time budget for retrying. Under 2.x, budgets
below 100ms did not honor that: the last delay was floored at 100ms, so a tight
budget cost at least 100ms and always bought one more attempt.

Only budgets **under about 100ms** are affected. For everything larger, 3.0
produces exactly the same delays as 2.x:

| `:expiry` | 2.x                              | 3.0                              |
| --------- | -------------------------------- | -------------------------------- |
| 50ms      | 2 attempts, 100ms slept          | 4 attempts, 50ms slept           |
| 250ms     | 6 attempts, 250ms slept          | 6 attempts, 250ms slept — same   |
| 1000ms    | 8 attempts, 1000ms slept         | 8 attempts, 1000ms slept — same  |

Note that the change runs in both directions at once: *more* attempts, in *less*
time. A tight budget now does what it says — it retries as fast as the backoff
allows and stops at the deadline, rather than sleeping past it.

There is no option that restores the 2.x shape, because it was not a shape anyone
chose deliberately. If you were relying on "one retry roughly 100ms later", say
that directly:

```elixir
retry: [max_attempts: 2, backoff: :linear, base: 100]
```

## 4. `:decorator` is an optional dependency

`ExternalService.Decorator` — the `@decorate external_call` annotations — is now
behind an optional dependency, the same treatment `:flow` has always had. If you
use it, declare it:

```elixir
# mix.exs
{:decorator, "~> 1.4"}
```

Unlike the three above, this one is **loud**. If you use the decorator and do not
add the dependency, the build fails immediately and says so:

```
error: module ExternalService.Decorator is not loaded and could not be found
** (CompileError) cannot compile module MyApp.Stripe (errors have been logged)
```

If you do not use `@decorate external_call`, you need to do nothing, and you get
one fewer transitive dependency.

## Upgrade checklist

- [ ] Search boot logs for the two `start/2` warnings. If neither appears, skip to the last two boxes.
- [ ] For each warned service, decide: a real bound, or `max_attempts: :infinity` / `wait: :infinity` to keep 2.x behavior.
- [ ] Set `wait: :infinity` explicitly on any service used from a Flow pipeline or background job.
- [ ] Check for `:expiry` values under 100ms; if any, confirm the new attempt count and timing are what you want.
- [ ] Add `{:decorator, "~> 1.4"}` to your deps if you use `@decorate external_call`.
- [ ] Add clauses for `ExternalService.RetriesExhausted` and `ExternalService.RateLimited` wherever a previously-unbounded call is handled — these are the errors that could not occur before.
- [ ] Run your test suite. Tests that relied on a call blocking until success are the ones most likely to surface this.
