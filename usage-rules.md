# ExternalService usage rules

Safely calling external services with **retries**, a **circuit breaker**, **rate limiting**, and
a **concurrency limit** (bulkhead). You wrap the risky call in a function; all four protections
apply on every call.

## Setup

```elixir
# mix.exs
{:external_service, "~> 3.1"}
```

```elixir
# .formatter.exs — the guides use the paren-free `call fn -> ... end` idiom
import_deps: [:external_service]
```

Define a module per service, configure it declaratively, and **start it under a supervisor**:

```elixir
defmodule MyApp.Stripe do
  use ExternalService,
    retry: [max_attempts: 5, backoff: :exponential, base: 100, cap: 2_000, jitter: true],
    circuit_breaker: [tolerate: 5, within: :timer.seconds(30), reset: :timer.seconds(5)],
    rate_limit: [limit: 100, per: :timer.seconds(1), wait: :timer.seconds(1)]

  def charge(params) do
    call fn ->
      case Stripe.charge(params) do
        {:ok, result} -> {:ok, result}
        {:error, %{status: s}} when s in 500..599 -> {:retry, s}
        other -> other
      end
    end
  end
end
```

```elixir
children = [MyApp.Stripe]   # forgetting this is the #1 cause of "why isn't anything protected?"
Supervisor.start_link(children, strategy: :one_for_one)
```

A functional API exists too (`ExternalService.start/2` + `ExternalService.call/3` with a service
name atom), but the module front door is the recommended shape.

## The one rule about `call`

Everything hinges on what the function you pass to `call/1` returns:

| Return | Effect |
| --- | --- |
| `:retry` | retry |
| `{:retry, reason}` | retry, and record the reason |
| a value matched by the `:retry_on` predicate | retry, result recorded as the reason |
| **anything else** | **success — returned as-is** |
| a raised exception | propagates, unless matched by `:retry_exceptions` |

**"Anything else" includes `{:error, reason}`.** An error tuple is a successful call as far as
this library is concerned, and is handed straight back to you. If you want a failure retried, you
must say so — either by returning `:retry`/`{:retry, reason}`, or by declaring a `:retry_on`
predicate.

```elixir
call fn -> HTTP.get(url) end            # ❌ {:error, :timeout} is never retried
call fn ->
  case HTTP.get(url) do
    {:error, :timeout} -> :retry        # ✅
    other -> other
  end
end
```

## The traps

### Your HTTP client's own retries multiply against these

If the client you call inside `call/1` retries on its own, the two compound: `max_attempts: 3`
around a client doing 3 retries is up to 9 requests, with two independent backoff schedules
interleaved, and the breaker melting on a count you did not choose.

`Req` is the common case — it retries by default (`retry: :safe_transient`, which covers **GET
and HEAD only**, so a POST behaves differently from a GET under the same configuration). Turn the
client's retries off and let this library own the policy:

```elixir
Req.new(retry: false)
```

**Check this first whenever attempt counts do not match what you configured.**

### `max_attempts: 5` is a bound, not an allowance

With the default `base: 10` that is **150 ms of total waiting** — far too little for a real
dependency. For a service that is briefly overloaded, raise `:base`, not the attempt count:

```elixir
retry: [max_attempts: 5, base: 100, cap: 2_000, backoff: :exponential, jitter: true]
```

`max_attempts: :infinity` retries forever, and **the circuit breaker does not reliably stop it**.

### Circuit-breaker `:tolerate` counts failed *attempts*, not failed calls

Retries melt the breaker too, so a call with `max_attempts: 5` can contribute five melts on its
own. `tolerate ≈ failing calls × max_attempts` is the arithmetic to have in mind.

And the window has to be wide enough to *contain* those melts. If one call's retry schedule
spans 7.5 s and you need 6 calls to open the breaker, the melts spread over ~37.5 s — so a
`within: 30_000` breaker **never opens**, silently, with nothing raising and no log line.

Do not hand-tune this. Ask the library:

```elixir
IO.puts ExternalService.explain(MyApp.Stripe)          # what will this configuration do?
ExternalService.simulate(MyApp.Stripe, :always_failing) # does the breaker actually open?
#=> %Simulation{opens_after: 4, worst_call: 1500, attempts: 20, ...}
ExternalService.RetryOptions.window(base: 100, max_attempts: 5)  #=> 1500
```

Both `explain/1` and `simulate/3` also accept a proposed keyword list, so you can check a
configuration before shipping it. `ExternalService.ConfigCheck` runs the same reasoning at
compile time and at start, and warns with the arithmetic shown.

### `:wait` for the rate limiter depends on *where the call is made*, not on the service

This is the rule to internalise, because the wrong answer sheds traffic silently.

A limiter check never quotes more than one emission interval (`per / limit`), and the default
`:wait` budget is one window capped at 5 s. At `limit: 1, per: 2_000` those are both 2000 ms, so
a single re-check exhausts the budget and the service sheds on the slightest contention instead
of pacing.

  * **Background work** — an Oban job, a Flow pipeline, a bulk transfer: `wait: :infinity`.
    Sleeping *is* the back-pressure, and there is no user waiting.
  * **A request path** — a page load, a LiveView event: a finite budget, so a slow dependency
    turns into a fast error rather than a hung request.
  * `wait: false` fails immediately. It never melts the breaker and is never retried.

The same call configured for the wrong side of that line is the single most common
misconfiguration.

### Not every failure melts the breaker or gets retried

| Error | Melts breaker? | Retried? |
| --- | --- | --- |
| `%ExternalService.RetriesExhausted{}` | the attempts did | — |
| `%ExternalService.CircuitBreakerOpen{}` | n/a — it is already open | no |
| `%ExternalService.RateLimited{}` (http_status 429) | **no** | **no** |
| `%ExternalService.ServiceSaturated{}` (http_status 503) | **no** | **no** |

Shedding is not failing. Treating a `RateLimited` as a service outage — melting, retrying, or
tripping an alert — is a misreading.

### The concurrency limit sheds; it does not queue

```elixir
concurrency: [limit: 25, reclaim_after: :timer.seconds(30), wait: 50]
```

Over the limit, calls return `ServiceSaturated` rather than queueing. A short `:wait` absorbs
bursts; `:infinity` is **rejected** for the bulkhead (a quota refills on its own, but a slot
frees only when another call finishes). `:reclaim_after` must exceed your client timeout, or
slots are reclaimed from calls that are still running.

### Both the breaker and the limiter are node-local by default

N nodes means up to N × `limit` calls, and each node trips its breaker on its own. If the quota
is imposed per-account rather than per-node, you need a shared backend:

```elixir
rate_limit: [limit: 100, per: 1_000,
             backend: {ExternalService.RateLimiter.Hammer, module: MyApp.RateLimit}]

circuit_breaker: [tolerate: 5, backend: ExternalService.CircuitBreaker.Cluster]
```

### Errors are Errata errors, and the useful message is usually underneath

`RetriesExhausted`'s own message describes *our* reaction — "the request could not be completed
after 3 attempts" — which is true and rarely actionable. The failure a user can do something
about is the `:cause`:

```elixir
# the deepest Errata error — has a code, a context and a classification to render or report
Errata.root_error(error)

# the foreign original underneath it — :econnrefused, an %Mint.TransportError{}, ... or nil
Errata.root_error(error) |> Errata.cause()
```

That turns "could not be completed after 3 attempts" into "connection refused", and works across
library boundaries — `RetriesExhausted` wraps your error and neither knows about the other.

Do not hand-roll a recursive unwrap loop, and do not reach for `Errata.root_cause/1`: it is
deprecated because it returns an Errata error *or* a foreign value depending on how the chain
ends, leaving the caller to work out which it got. See the [Using Errata](guides/errata.md) guide — an application's own Errata
errors can also drive retries via `:retry_on` and `retryable?/1`, which puts the retry decision
in the error type rather than in a branch on the shape of what came back.

## Calling

```elixir
MyApp.Api.call(fn -> work() end)
MyApp.Api.call([max_attempts: 2], fn -> work() end)   # per-call retry overrides
MyApp.Api.call!(fn -> work() end)                      # raises instead of returning {:error, _}

task = MyApp.Api.call_async(fn -> work() end)          # Task
ids |> MyApp.Api.call_async_stream(fn id -> fetch(id) end) |> Enum.to_list()
```

Handle the outcome by error type, not by string:

```elixir
case MyApp.Api.fetch(id) do
  {:ok, v} -> v
  {:error, %ExternalService.RetriesExhausted{}} -> degrade()
  {:error, %ExternalService.CircuitBreakerOpen{}} -> degrade()
  {:error, %ExternalService.RateLimited{}} -> shed()
  {:error, reason} -> {:error, reason}       # your own error, passed through
end
```

## Retry options

```elixir
retry: [
  backoff: :exponential,          # or :linear
  base: 100,                      # initial delay ms (default 10 — usually too small)
  cap: :timer.seconds(2),         # max single delay
  max_attempts: 5,                # default; or :infinity
  expiry: :timer.seconds(10),     # total time budget; or :infinity
  jitter: true,                   # ±10%, or a float proportion
  retry_on: &match?({:error, %{status: 500}}, &1),   # predicate over the result
  retry_exceptions: [MyApp.TransientError]           # modules, or a predicate on the exception
]
```

`:retry_on` is how you retry the result of a function you cannot modify. `:retry_exceptions` is
how you retry something that raises — by default a raised exception propagates untouched.

Turn a protection off explicitly rather than omitting the mechanism:
`circuit_breaker: [tolerate: :infinity]` (never opens, holds no state) and
`rate_limit: [limit: :infinity, per: 1_000]`.

## Introspection

```elixir
MyApp.Api.available?()      # breaker closed?
MyApp.Api.blown?()          # breaker open?
MyApp.Api.reset()           # force closed
ExternalService.rate_limited?(:api)         # boolean, consumes no budget
ExternalService.saturated?(:svc)
ExternalService.Concurrency.in_flight(:svc)
```

## Telemetry

```text
[:external_service, :call, :start | :stop | :exception | :retry]
[:external_service, :circuit_breaker, :blown]
[:external_service, :rate_limit, :sleep]
[:external_service, :concurrency, :rejected | :waited]
```

`[:call, :retry]` fires **per attempt**, so it is a count of attempts and not of calls — worth
remembering when building a dashboard.

## Testing

`ExternalService.Test` provides assertions over those events. They need a handler attached before
the call, so record explicitly:

```elixir
defmodule MyApp.ApiTest do
  use ExUnit.Case
  use ExternalService.Test

  setup :record_events

  test "a 500 is retried" do
    # ... exercise the call ...
    assert_retried(MyApp.Api)
  end
end
```

`ExternalService.Test.Coverage` reports which protections each service actually exercised across
a suite — useful for finding a breaker or limiter that is configured but never reached.

Note that a `wait: false` rate limit never sleeps, so it emits no `[:rate_limit, :sleep]` event —
if your tests configure it that way, that signal is absent by construction.

## When configuration and reality disagree

Reach for these in order, before changing numbers:

1. `ExternalService.explain(MyApp.Api)` — states the *consequence* of each setting, not the
   setting.
2. `ExternalService.simulate(MyApp.Api, :always_failing)` — a virtual clock; nothing sleeps.
3. Check whether your HTTP client is retrying underneath you.

Fixing one shedding path can simply move the shedding to another — a limiter and a concurrency
limit can both shed the same call — which is why `explain/1` lists all of them at once.
