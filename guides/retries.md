# Retries

Many failures when calling an external service are _transient_: a momentary
timeout, a brief overload, a connection reset. The simplest effective response is
to try again — perhaps after a short backoff. `ExternalService` automates this
using the [retry](https://hex.pm/packages/retry) library, exposing its
flexibility through the `ExternalService.RetryOptions` struct.

## Triggering a retry

Inside the function you pass to `call`, you signal that a retry should happen by
returning either:

- the atom `:retry`, or
- a tuple `{:retry, reason}`, where `reason` is any term.

Anything else is a success and is returned to the caller as-is — including the
function's own `{:error, reason}` results. You decide what is retriable:

```elixir
call fn ->
  case HTTP.post(url, body) do
    {:ok, %{status: 200} = resp}            -> {:ok, resp}
    {:ok, %{status: s}} when s in 500..599  -> {:retry, s}   # retry server errors
    {:ok, %{status: 429}}                   -> :retry        # retry throttling
    {:ok, %{status: 4xx}} = resp            -> resp          # client error: don't retry
    {:error, reason}                        -> {:error, reason}
  end
end
```

Each retry melts the service's circuit breaker, so a sustained run of retries
will eventually open it. See [Circuit breakers](circuit-breakers.md).

## Retrying on the return value with `:retry_on`

Returning `:retry` works when you control the function body. When you're calling
an existing function that already returns its own result shape — and you'd rather
not wrap it just to translate that shape into `:retry` — the `:retry_on` retry
option takes a **predicate** that is run on the return value. When the predicate
returns a truthy value, the call is retried exactly as if the function had
returned `{:retry, result}`: the result becomes the retry reason, and the circuit
breaker melts.

```elixir
# Retry any 5xx response from an unmodified client function.
retry: [retry_on: &match?({:error, %{status: s}} when s in 500..599, &1)]

call fn -> Stripe.charge(params) end
```

If retries are exhausted, the matched result is carried as the reason on
`ExternalService.RetriesExhausted` (and in the `[:external_service, :call, :retry]`
telemetry metadata). An explicit `:retry` / `{:retry, reason}` return from the
function always takes precedence over the predicate.

> #### Prefer explicit returns when you own the function {: .tip}
>
> `:retry_on` is for adapting functions you don't want to change. When you do
> control the body, returning `:retry` / `{:retry, reason}` keeps the retry
> decision explicit and local to the call.

## Configuring retries

Retry behavior is described by `ExternalService.RetryOptions`. You can supply it
as the service's default (the `:retry` option to `use ExternalService` /
`start/2`), or per call as a keyword list or struct:

```elixir
# Service default
use ExternalService,
  retry: [max_attempts: 5, backoff: :exponential, base: 100, jitter: true]

# Per-call override (keyword list)
call [max_attempts: 2, backoff: :linear, base: 50], fn -> work() end

# Per-call override (struct)
call %ExternalService.RetryOptions{max_attempts: 2}, fn -> work() end
```

When you use the two-argument `call/2` (no options), the service's default
`:retry` options apply.

> #### Per-call keyword lists merge; structs replace {: .info}
>
> A per-call **keyword list** is treated as a set of *overrides*: it is merged
> onto the service's configured `:retry` defaults, changing only the keys you
> list and inheriting the rest. So if a service is configured with
> `retry: [backoff: :exponential, base: 100, max_attempts: 5]`, then
> `call([max_attempts: 2], fun)` runs with `backoff: :exponential, base: 100,
> max_attempts: 2`.
>
> A per-call **`%RetryOptions{}` struct**, by contrast, is already a complete set
> of options, so it *replaces* the service defaults wholesale — any field you
> don't set takes the library default, not the service's value.

### The options

| Option          | Default        | Meaning                                                                                      |
| --------------- | -------------- | -------------------------------------------------------------------------------------------- |
| `:backoff`      | `:exponential` | Growth strategy for the delay between retries: `:exponential` or `:linear`.                  |
| `:base`         | `10`           | Initial delay between retries, in milliseconds (`0` for no delay).                           |
| `:factor`       | `1`            | Growth factor applied each retry. Only used for `:linear` backoff.                           |
| `:cap`          | —              | Caps the delay between retries to at most this many milliseconds.                            |
| `:expiry`       | —              | Time budget for the retrying, in milliseconds. The budget is spent, never overshot.          |
| `:max_attempts` | `5`            | Maximum number of attempts, counting the initial one. `:infinity` to retry without a count bound. |
| `:jitter`       | `false`        | Random jitter on delays. `true` applies ±10%; a float (e.g. `0.25`) applies that proportion. |
| `:retry_on`     | —              | Predicate run on the return value; retry when it returns a truthy value (see below).        |
| `:retry_exceptions` | `[]`       | Which raised exceptions trigger a retry: a list of exception modules, or a predicate run on the exception (see below). |

Options are validated when the struct is built; an invalid value raises
`NimbleOptions.ValidationError` with a helpful message.

## Backoff strategies

**Exponential** backoff grows the delay multiplicatively, starting from `:base`.
This is the right default for most services: it backs off quickly when a service
is struggling.

```elixir
retry: [backoff: :exponential, base: 100]
# delays grow ~100ms, 200ms, 400ms, 800ms, ...
```

**Linear** backoff grows the delay by `:factor` each time, starting from
`:base`:

```elixir
retry: [backoff: :linear, base: 100, factor: 1]
# delays grow ~100ms, 200ms, 300ms, 400ms, ...
```

## Bounding retries

`:max_attempts` defaults to `5`, so retrying always stops on its own. There are
two bounds and they compose:

- **`:max_attempts`** — a count, defaulting to `5`. `max_attempts: 5` means at
  most five attempts total (the first try plus four retries).
- **`:expiry`** — a time budget in milliseconds for the retrying. Backoff delays
  are used as-is while they fit; the one that would overshoot the budget is
  trimmed instead, so the final attempt starts exactly at the deadline rather
  than past it. It is checked **between** attempts, so it bounds when the next
  attempt starts, never how long the current one runs — see
  [Nothing here bounds a single attempt](#nothing-here-bounds-a-single-attempt).

You can use either or both; whichever is reached first stops the retries. When
the bound is hit without success, `call/3` returns
`{:error, %ExternalService.RetriesExhausted{}}` (and `call!/3` raises it).

```elixir
# Stop after 5 attempts OR 5 seconds, whichever comes first.
retry: [max_attempts: 5, expiry: :timer.seconds(5), backoff: :exponential, base: 100]
```

> #### The default is a bound, not an allowance {: .info}
>
> With the default `:base` of `10`, five attempts means delays of
> `[10, 20, 40, 80]` — **150ms of waiting in total**. That is a safety net
> against retrying forever, not a retry window tuned for a real dependency.
>
> If your dependency needs longer, raise `:base` rather than the attempt count:
> `base: 100` gives the same five attempts across 1.5 seconds, and is the usual
> starting point for an HTTP service. Raising `:max_attempts` instead makes the
> circuit breaker trip sooner, for the reason in the warning below.

### Nothing here bounds a single attempt

`:expiry` reads like a wall-clock budget for the whole call. It isn't, and the
difference matters as soon as your function is slow rather than fast-failing.
Both bounds are evaluated **between** attempts — when the retry machinery decides
whether to make another one — so neither can interrupt an attempt already
running.

Measured with `retry: [max_attempts: 4, expiry: 100]` against a function that
sleeps 300ms and then returns `:retry`:

```
attempts made: 2
total elapsed: 621ms
```

The 100ms budget stopped the third attempt, but the call still took six times
the budget, because each attempt ran to completion first. Push that further —
a function that never returns — and `:expiry` is never evaluated at all, so the
call hangs forever no matter what you set.

**`ExternalService` imposes no timeout on your function.** Bounding a single
attempt is the caller's job; see
[When the service hangs](circuit-breakers.md#when-the-service-hangs).

> #### Don't rely on the circuit breaker to bound retries {: .warning}
>
> The breaker is a backstop, not a retry bound. Set `max_attempts: :infinity` and
> retries stop only when the breaker opens — and that is not guaranteed. The
> breaker opens after `:tolerate` failures *within* its `:within` window, but
> exponential backoff keeps widening the gap between attempts. Once the delay
> grows past the window, failures stop accumulating fast enough to trip the
> breaker, and retrying continues indefinitely.
>
> This needs no exotic configuration. With a **fully default** circuit breaker
> (`tolerate: 10`, `within: 10_000`) and retry options default except for the
> `base: 100` used throughout this guide, attempts land at roughly 0ms, 100ms,
> 300ms, 700ms, 1.5s, 3.1s, 6.3s, 12.7s, … Only seven of them ever fall inside
> any 10-second window, so the melt count tops out at 7 against a `:tolerate` of
> 10. The breaker never opens and the call never returns. Always set an explicit
> `:max_attempts` or `:expiry` — and a `:cap`, below — for unattended retries.
>
> Since 3.0 this combination is **rejected** rather than merely discouraged: under
> the default melt semantics a call that never gives up never melts the breaker, so
> there would be nothing at all to stop it. The paragraph above describes what the
> breaker does for services that opt back into `circuit_breaker: [melt: :per_attempt]`,
> where it remains the only backstop and an unreliable one. See
> [`:tolerate` counts calls, not attempts](circuit-breakers.md#what-counts-as-a-failure).

### Unbounded retries are a choice you have to make

Retrying without a count bound is available, but it has to be asked for:

```elixir
ExternalService.start(:my_service, retry: [max_attempts: :infinity])
```

That is the right answer for some work — a background job that should keep trying
until it succeeds, where there is nowhere else for the failure to go. It is
almost never the right answer in a request path, where a call that never returns
is worse than one that fails.

If you do reach for it, pair it with an `:expiry`, or at least a `:cap` so the
delay between attempts doesn't grow without limit. And read the warning above
first: the circuit breaker will not reliably stop the retrying for you.

## Capping the delay

Exponential backoff grows without bound. `:cap` puts a ceiling on any single
delay so you don't end up waiting minutes between attempts:

```elixir
retry: [backoff: :exponential, base: 100, cap: :timer.seconds(2)]
# delays grow 100, 200, 400, 800, 1600, 2000, 2000, ... (capped at 2s)
```

## Jitter

When many processes retry on the same schedule, they retry in lockstep and slam
the recovering service all at once — the _thundering herd_. Jitter randomizes
each delay to spread them out:

```elixir
retry: [backoff: :exponential, base: 100, jitter: true]   # ±10%
retry: [backoff: :exponential, base: 100, jitter: 0.25]   # ±25%
```

Enabling jitter is good practice for any service with many concurrent callers.

## Retrying on raised exceptions

**By default, raised exceptions are not retried** — they propagate straight to
the caller. This is a deliberate 2.0 change (see
[issue #7](https://github.com/jvoegele/external_service/issues/7)): retrying
every `RuntimeError` by default tended to mask real bugs.

If a particular exception genuinely indicates a transient condition worth
retrying, list its module in `:retry_exceptions`:

```elixir
retry: [retry_exceptions: [MyApp.TransientError, DBConnection.ConnectionError]]
```

Now a raised `MyApp.TransientError` triggers a retry just like a `:retry` return
value would, and it melts the circuit breaker. Exceptions not in the list still
propagate untouched and leave the breaker alone — `:retry_exceptions` governs both
retrying and whether a raised exception counts against the breaker.

If retries run out while retrying an exception, that original exception is
re-raised — with its original stacktrace, still pointing at the code that raised
it — rather than being converted into an `ExternalService.RetriesExhausted`.

### Deciding per exception rather than per type

A module list settles the question by type, which is the wrong grain when the
same exception is transient in one instance and permanent in another — an HTTP
client that raises one error struct for every status, say. Give
`:retry_exceptions` a predicate instead and it is run on the exception itself:

```elixir
retry: [
  retry_exceptions: fn
    %MyApp.HTTPError{status: status} -> status >= 500
    _other -> false
  end
]
```

A truthy return retries and melts the breaker; anything else propagates the
exception untouched, exactly as an unlisted module would. The predicate replaces
the list rather than supplementing it, so fold any module checks you still want
into it:

> #### Predicates must answer for every value {: .info}
>
> A predicate is handed every exception the call raises, including ones it does
> not recognise, so a `%MyApp.HTTPError{}`-only clause will eventually meet
> something else. A predicate that fails rather than answering — raising,
> throwing, or exiting — is treated as **no match**: the exception it was asked
> to classify reaches the caller unchanged, nothing is retried, the breaker is
> left alone, and a warning naming the option and the service is logged. The same
> holds for the `:retry_on` predicate, where the call's result passes through
> untouched. A broken classifier never changes the outcome of a call; it only
> stops retries from happening.

```elixir
retry_exceptions: fn
  %MyApp.HTTPError{status: status} -> status >= 500
  error -> is_struct(error, DBConnection.ConnectionError)
end
```

> #### Anonymous functions and `use ExternalService` {: .warning}
>
> The examples above pass an anonymous function, which works for
> `ExternalService.start/2` and for per-call retry options. The options given to
> `use ExternalService` are stored in a module attribute, though, which cannot
> hold one:
>
> ```elixir
> use ExternalService, retry: [retry_exceptions: fn error -> ... end]
> # ** (ArgumentError) cannot inject attribute @__external_service_opts__ into
> #    function/macro because cannot escape #Function<...>
> ```
>
> Put the predicate in a named function and pass a remote capture —
> `&MyApp.Retry.transient?/1` — which is a valid attribute value. The same
> applies to the `:retry_on` predicate.

This pairs well with [Errata](https://hexdocs.pm/errata), whose errors classify
themselves — an error type can decide from its own `:reason` or `:context` and
answer through `Errata.retryable?/1`:

```elixir
defmodule MyApp.Retry do
  require Errata

  def retryable_error?(error), do: Errata.is_error(error) and Errata.retryable?(error)
end

# ...then, in the service configuration:
retry: [retry_exceptions: &MyApp.Retry.retryable_error?/1]
```

See [Using Errata in Your Application](errata.md) for both boundaries together,
and for the difference between an error being retryable and a call being safe to
repeat.

> #### Prefer return values over exceptions {: .tip}
>
> Where you can, drive retries with `:retry` / `{:retry, reason}` return values
> (or the `:retry_on` predicate) rather than relying on `:retry_exceptions`. It
> keeps the retry decision explicit and local to the call, and avoids retrying an
> exception that happens to share a type with a genuine bug.

## Putting it together

A solid default for an HTTP-style dependency:

```elixir
use ExternalService,
  circuit_breaker: [tolerate: 15, within: :timer.seconds(5), reset: :timer.seconds(5)],
  retry: [
    backoff: :exponential,
    base: 100,
    cap: :timer.seconds(2),
    max_attempts: 5,
    expiry: :timer.seconds(10),
    jitter: true
  ]
```

This retries transient failures with jittered exponential backoff, never waits
more than 2 seconds between attempts, gives up after 5 attempts or 10 seconds,
and opens the circuit breaker on the third consecutive fully-failing call.

The breaker settings are sized against the retry settings rather than picked
independently, and that is not optional. Five attempts spread over a ~1.5 second
retry window means `:within` has to be wider than 1.5 seconds for the melts to
accumulate at all, and `:tolerate` has to be about `3 × max_attempts` for three
calls to be what trips it. Get that wrong and the breaker never opens: see
[Sizing the breaker](tuning.md#sizing-the-breaker)
for the measurement, and the [Tuning](tuning.md) guide for choosing all of these
together.
