# Migrating to 2.0

ExternalService 2.0 is a deliberate, breaking modernization of the library. It
sheds the leaked "fuse" terminology, validates and documents every option,
adds telemetry and introspection, and replaces ad-hoc error tuples with
structured error types. This guide is the mechanical checklist for upgrading a
1.x codebase.

The changes are real but the upgrade is mostly find-and-replace. Work through the
sections below in order; each shows the 1.x form and its 2.0 replacement.

> A complete, categorized list of changes is in the
> [CHANGELOG](changelog.html). This guide focuses on _what you have to do_ to
> upgrade.

## At a glance

| Area                      | 1.x                                                        | 2.0                                                  |
| ------------------------- | ---------------------------------------------------------- | ---------------------------------------------------- |
| Minimum Elixir            | < 1.15                                                     | `~> 1.15`                                            |
| Circuit breaker config    | `fuse_strategy: {:standard, max, win}`, `fuse_refresh: ms` | `circuit_breaker: [tolerate:, within:, reset:]`      |
| Rate limit config         | `rate_limit: {limit, win}`                                 | `rate_limit: [limit:, per:]`                         |
| Service identifier term   | `fuse_name`                                                | `service`                                            |
| Reset a breaker           | `reset_fuse/1`                                             | `reset/1`                                            |
| Retry backoff             | `{:exponential, d}` / `{:linear, d, f}`                    | `backoff: :exponential\|:linear` + `base:`/`factor:` |
| Retry on exceptions       | `rescue_only: [...]` (retried `RuntimeError` by default)   | `retry_on: [...]`, default `[]`                      |
| Jitter                    | `randomize:`                                               | `jitter:`                                            |
| Module gateway            | `use ExternalService.Gateway` + `external_call/*`          | `use ExternalService` + `call/*`                     |
| Library errors (returned) | nested tuples                                              | structured `Errata` structs                          |
| Library errors (raised)   | `*Error` modules                                           | new structured modules                               |

## 1. Bump the minimum Elixir version

2.0 requires Elixir `~> 1.15`. Make sure your project (and CI matrix) is on 1.15
or later before upgrading.

## 2. Update circuit breaker and rate limit configuration

The `fuse_*` options and tuple-style rate limit are gone, replaced by validated
keyword lists. The option names now describe what they do rather than leaking the
underlying `:fuse` library.

```elixir
# Before (1.x)
ExternalService.start(MyService,
  fuse_strategy: {:standard, 5, 1_000},
  fuse_refresh: 5_000,
  rate_limit: {100, 1_000}
)

# After (2.0)
ExternalService.start(MyService,
  circuit_breaker: [tolerate: 5, within: 1_000, reset: 5_000],
  rate_limit: [limit: 100, per: 1_000]
)
```

The mapping is direct:

- `fuse_strategy: {:standard, max, window}` → `circuit_breaker: [tolerate: max, within: window]`
- `fuse_refresh: ms` → `circuit_breaker: [reset: ms]`
- `rate_limit: {limit, window}` → `rate_limit: [limit: limit, per: window]`

For the `{:fault_injection, rate, max, window}` strategy, use
`circuit_breaker: [fault_injection: rate, tolerate: max, within: window]`.

Options are now validated by [NimbleOptions](https://hexdocs.pm/nimble_options),
so a typo or wrong type raises a clear error at `start` time instead of silently
misconfiguring the service. (In fact, in 1.x a mismatched gateway `fuse:` option
was silently dropped — that class of bug is now impossible.)

## 3. Rename `reset_fuse` to `reset`

```elixir
# Before
ExternalService.reset_fuse(MyService)

# After
ExternalService.reset(MyService)
```

(On modules using the deprecated gateway, `reset_fuse/0` still works as an
alias — see section 7.)

## 4. Reshape your retry options

`ExternalService.RetryOptions` changed shape. Backoff is now a plain atom plus
separate numeric fields, `randomize` became `jitter`, and `rescue_only` became
`retry_on`.

```elixir
# Before (1.x)
%ExternalService.RetryOptions{
  backoff: {:exponential, 100},
  randomize: true,
  rescue_only: [RuntimeError]
}

# After (2.0)
%ExternalService.RetryOptions{
  backoff: :exponential,
  base: 100,
  jitter: true,
  retry_on: [RuntimeError]
}
```

Mapping:

- `backoff: {:exponential, delay}` → `backoff: :exponential, base: delay`
- `backoff: {:linear, delay, factor}` → `backoff: :linear, base: delay, factor: factor`
- `randomize: true` → `jitter: true` (a float still means that proportion)
- `rescue_only: mods` → `retry_on: mods`

You can also now pass retry options as a plain keyword list to `call/3` /
`call!/3` and to the `:retry` option, not only as a struct.

### ⚠️ Behavior change: exceptions are no longer retried by default

This is the one change that can alter runtime behavior rather than just syntax.
In 1.x, `rescue_only` defaulted to `[RuntimeError]`, so any raised `RuntimeError`
was retried automatically. In 2.0, **`retry_on` defaults to `[]`** — raised
exceptions are _not_ retried unless you opt in
([issue #7](https://github.com/jvoegele/external_service/issues/7)).

If you were relying on exceptions being retried, restore it explicitly:

```elixir
retry: [retry_on: [RuntimeError]]
```

But prefer driving retries with `:retry` / `{:retry, reason}` return values where
you can — it is more explicit and avoids retrying an exception that actually
signals a bug. See [Retries](retries.md).

## 5. Update error handling

This is the largest source-level change. The library no longer returns nested
error tuples or raises the old `*Error` modules. It returns (and raises)
structured [Errata](https://hexdocs.pm/errata) error structs. The _same_ struct
is returned by `call/3` and raised by `call!/3`.

### Returned errors (`call/3`)

| Before (1.x)                             | After (2.0)                                                                              |
| ---------------------------------------- | ---------------------------------------------------------------------------------------- |
| `{:error, {:retries_exhausted, reason}}` | `{:error, %ExternalService.RetriesExhausted{context: %{service: name, reason: reason}}}` |
| `{:error, {:fuse_blown, name}}`          | `{:error, %ExternalService.CircuitBreakerOpen{context: %{service: name}}}`               |
| `{:error, {:fuse_not_found, name}}`      | `{:error, %ExternalService.ServiceNotStarted{context: %{service: name}}}`                |

```elixir
# Before (1.x)
case ExternalService.call(MyService, fun) do
  {:error, {:retries_exhausted, reason}} -> handle_exhausted(reason)
  {:error, {:fuse_blown, _name}}         -> handle_blown()
  result                                 -> result
end

# After (2.0)
case ExternalService.call(MyService, fun) do
  {:error, %ExternalService.RetriesExhausted{context: %{reason: reason}}} -> handle_exhausted(reason)
  {:error, %ExternalService.CircuitBreakerOpen{}}                         -> handle_blown()
  result                                                                  -> result
end
```

Note the retry `reason` now lives in `context.reason`.

### Raised errors (`call!/3`)

| Before (1.x)                            | After (2.0)                          |
| --------------------------------------- | ------------------------------------ |
| `ExternalService.RetriesExhaustedError` | `ExternalService.RetriesExhausted`   |
| `ExternalService.FuseBlownError`        | `ExternalService.CircuitBreakerOpen` |
| `ExternalService.FuseNotFoundError`     | `ExternalService.ServiceNotStarted`  |

```elixir
# Before (1.x)
rescue
  e in [ExternalService.RetriesExhaustedError, ExternalService.FuseBlownError] -> ...

# After (2.0)
rescue
  e in [ExternalService.RetriesExhausted, ExternalService.CircuitBreakerOpen] -> ...
```

The old `*Error` modules have been removed entirely. As a bonus, the new structs
are Errata infrastructure errors, so they carry an `http_status/1` and JSON
encoding — see [Error handling](error-handling.md).

Results your own function returns (including its own `{:error, reason}` values)
are **unchanged** — only the library's own error representations moved.

## 6. Adopt the module front door (recommended)

The blessed way to use 2.0 is `use ExternalService`, which replaces both manual
`start/2` + `call/3` wiring and the old `ExternalService.Gateway`. You configure
the service declaratively and start it under your supervisor:

```elixir
defmodule MyApp.Stripe do
  use ExternalService,
    circuit_breaker: [tolerate: 5, within: :timer.seconds(1), reset: :timer.seconds(5)],
    rate_limit: [limit: 100, per: :timer.seconds(1)],
    retry: [max_attempts: 5, backoff: :exponential, jitter: true]

  def charge(params), do: call(fn -> Stripe.charge(params) end)
end

# In your supervision tree:
children = [MyApp.Stripe]
```

This isn't required to upgrade — the functional `start/2` + `call/3` API is fully
supported — but it is the most polished way to use the library. See
[The module front door](the-front-door.md).

## 7. Migrate off `ExternalService.Gateway`

`use ExternalService.Gateway` still compiles but is **deprecated** and emits a
warning. It now delegates to `use ExternalService`, keeping the
`external_call/*` and `reset_fuse/0` names as aliases — but it uses the new
option shape, so the old `fuse: [strategy:, refresh:]` options are gone.

```elixir
# Before (1.x)
defmodule MyApp.PubSub do
  use ExternalService.Gateway,
    fuse: [name: MyApp.PubSub, strategy: {:standard, 5, 1_000}, refresh: 5_000],
    rate_limit: {100, 1_000},
    retry: [backoff: {:linear, 100, 1}, expiry: 5_000]

  def publish(msg), do: external_call(fn -> do_publish(msg) end)
end

# After (2.0)
defmodule MyApp.PubSub do
  use ExternalService,
    name: MyApp.PubSub,
    circuit_breaker: [tolerate: 5, within: 1_000, reset: 5_000],
    rate_limit: [limit: 100, per: 1_000],
    retry: [backoff: :linear, base: 100, expiry: 5_000]

  def publish(msg), do: call(fn -> do_publish(msg) end)
end
```

Renames at the call site: `external_call` → `call`, `external_call!` → `call!`,
`external_call_async` → `call_async`, `external_call_async_stream` →
`call_async_stream`, `reset_fuse` → `reset`.

## Upgrade checklist

- [ ] Elixir `~> 1.15` everywhere (deps and CI).
- [ ] `fuse_strategy:`/`fuse_refresh:` → `circuit_breaker: [tolerate:, within:, reset:]`.
- [ ] `rate_limit: {l, w}` → `rate_limit: [limit: l, per: w]`.
- [ ] `reset_fuse/1` → `reset/1`.
- [ ] `RetryOptions`: tuple backoff → atom `backoff:` + `base:`/`factor:`; `randomize:` → `jitter:`; `rescue_only:` → `retry_on:`.
- [ ] Re-add `retry_on: [RuntimeError]` only where you actually want exceptions retried.
- [ ] Replace error tuples with the structured `RetriesExhausted` / `CircuitBreakerOpen` / `ServiceNotStarted` structs.
- [ ] Replace the old `*Error` modules in `rescue` clauses.
- [ ] (Recommended) Move `use ExternalService.Gateway` modules to `use ExternalService`.
- [ ] Run your test suite; let NimbleOptions validation surface any missed config.
