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
| `:expiry`       | —              | Total time budget for retries, in milliseconds. Retrying stops once exceeded.                |
| `:max_attempts` | —              | Maximum number of attempts (initial plus retries). No limit by default.                      |
| `:jitter`       | `false`        | Random jitter on delays. `true` applies ±10%; a float (e.g. `0.25`) applies that proportion. |
| `:retry_on`     | —              | Predicate run on the return value; retry when it returns a truthy value (see below).        |
| `:retry_exceptions` | `[]`       | Exception modules that should trigger a retry when raised.                                   |

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

By default there is **no** `:max_attempts`, `:expiry`, or `:cap`, so returning
`:retry` repeatedly keeps retrying with an ever-growing delay. You almost always
want an explicit bound. There are two, and they compose:

- **`:max_attempts`** — a count. `max_attempts: 5` means at most five attempts
  total (the first try plus four retries).
- **`:expiry`** — a time budget in milliseconds. Once cumulative retry time
  exceeds it, retrying stops.

You can use either or both; whichever is reached first stops the retries. When
the bound is hit without success, `call/3` returns
`{:error, %ExternalService.RetriesExhausted{}}` (and `call!/3` raises it).

```elixir
# Stop after 5 attempts OR 5 seconds, whichever comes first.
retry: [max_attempts: 5, expiry: :timer.seconds(5), backoff: :exponential, base: 100]
```

> #### Don't rely on the circuit breaker to bound retries {: .warning}
>
> The breaker is a backstop, not a retry bound. With no `:max_attempts`/`:expiry`,
> retries stop only when the breaker opens — and that is not guaranteed. The
> breaker opens after `:tolerate` failures *within* its `:within` window, but
> exponential backoff keeps widening the gap between attempts. Once the delay
> grows past the window, failures stop accumulating fast enough to trip the
> breaker, and retries can continue far longer than you'd expect (in pathological
> configs, effectively forever). Always set an explicit `:max_attempts` or
> `:expiry` — and a `:cap`, below — for unattended retries.

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
  circuit_breaker: [tolerate: 5, within: :timer.seconds(1), reset: :timer.seconds(5)],
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
and lets the circuit breaker take over if the failures are sustained.
