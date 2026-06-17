# Road to ExternalService 2.0

The goal of 2.0 is to make `external_service` the most developer-friendly way to
call an external service reliably from Elixir — polished from the perspective of
an application developer who just wants retries, a circuit breaker, and rate
limiting to "just work" with great defaults, great docs, and great observability.

Breaking changes are on the table. Backward-compat shims and a migration guide
smooth the upgrade.

## Direction (decided)

- **Blessed primary API: the module-based front door** (`use ExternalService`).
  Declarative config at the module level; no fuse-name juggling at call sites.
  The functional `ExternalService.start/2` + `call/3` API remains as the
  lower-level foundation it is built on.
- **Structured errors via [Errata](https://github.com/jvoegele/errata)** —
  dogfood our own library. Circuit-blown / retries-exhausted / not-started become
  `Errata.InfrastructureError` types carrying `reason`, `context`, `cause`, and
  origin `env`, with telemetry + JSON for free.
- **Lean 2.0, then 2.x.** 2.0 = API cleanup, validated+documented options,
  telemetry, introspection, structured errors, docs overhaul. Pluggable /
  distributed backends (issues #12, #13) are deferred to a focused 2.1.
- **Minimum Elixir `~> 1.15`** (unlocks NimbleOptions, modern telemetry idioms).

## Target API (sketch)

```elixir
defmodule MyApp.Stripe do
  use ExternalService,
    circuit_breaker: [tolerate: 5, within: :timer.seconds(1), reset: :timer.seconds(5)],
    rate_limit:      [limit: 100, per: :timer.seconds(1)],
    retry: [
      max_attempts: 5,          # NEW: count-based, in addition to time-based :expiry
      backoff: :exponential,    # :exponential | :linear
      base: 100,
      cap: :timer.seconds(5),
      jitter: true,
      retry_on: []              # exceptions to retry on; default [] (see issue #7)
    ]

  def charge(params) do
    call fn ->
      case Stripe.charge(params) do
        {:ok, result}                          -> {:ok, result}
        {:error, %{status: s}} when s in 500..599 -> :retry
        other                                  -> other
      end
    end
  end
end

# Supervise it; introspect it.
children = [MyApp.Stripe]
MyApp.Stripe.available?()   #=> true | false
MyApp.Stripe.blown?()
MyApp.Stripe.reset()
```

## Milestones

### M0 — Foundation & hygiene
- [ ] Bump `elixir: "~> 1.15"`; refresh deps; update `mix.lock`.
- [ ] Add deps: `nimble_options`, `telemetry`, `errata`.
- [ ] Add an opt-in `ExternalService.Application` supervision tree.
- [ ] CI workflow + formatter/credo/dialyzer clean (mirror the Errata setup).

### M1 — Internal refactor (no public break)
- [ ] Replace the unsupervised `Agent` state in `ExternalService.start/2` with
      `:persistent_term` — fast reads, nothing to crash. Resolves the resilience
      items in TODO.md. (Gateway's supervised `Config` Agent is left for the M4
      front-door redesign, where its storage and lifecycle change together.)
- [ ] **Fix the Gateway fuse-config drop**: `use ExternalService.Gateway` accepts
      `fuse: [strategy:, refresh:]` but `ExternalService.start/2` reads
      `:fuse_strategy`/`:fuse_refresh`, so gateway circuit-breaker settings were
      silently ignored and every gateway ran on default fuse config. Translate the
      keys + add a regression test asserting on the installed fuse record.
- [ ] Add a regression test for the `:fault_injection` strategy (issue #4). The
      `FunctionClauseError` in `:fuse_monitor` no longer reproduces on fuse 2.5 —
      the dependency upgrade fixed it — so this just locks the behavior in.

> NimbleOptions schema extraction moved to **M4**: the public option *shape*
> changes there (`circuit_breaker:`/`rate_limit:`/`retry:`), so validating the
> current, soon-to-be-replaced shape would be throwaway work.

### M2 — New capabilities (additive)
- [ ] Introspection: `available?/1`, `blown?/1`, `all_available?/1` + module-level
      equivalents (issue #5).
- [ ] Telemetry events: `[:external_service, :call, :start|:stop|:exception]`,
      `[:external_service, :retry]`, `[:external_service, :rate_limit, :sleep]`,
      `[:external_service, :circuit, :blown|:reset]`.
- [ ] Count-based retries (`max_attempts`) and explicit `jitter`.

### M3 — Structured errors (Errata) ✓
- [x] Define `ExternalService.RetriesExhausted`, `ExternalService.CircuitBreakerOpen`,
      `ExternalService.ServiceNotStarted` as `Errata.InfrastructureError`.
- [x] `call!` raises them; `call` returns `{:error, %Struct{}}`.
- [x] Migration notes for the old nested tuples (CHANGELOG table).

> No runtime compatibility shim: 2.0 is a clean break with a documented mapping.
> A `legacy_errors: true`-style flag would entrench the tuple shape we are
> deliberately replacing; the migration table + structured structs make the
> upgrade mechanical instead. Retry reasons are arbitrary terms, so they live in
> the error `:context` (Errata's `:reason` field must be an atom).

### M4 — Module front door polish
- [ ] Redesign `use ExternalService` (supersedes/wraps `ExternalService.Gateway`):
      unified `circuit_breaker:` / `rate_limit:` / `retry:` config, NimbleOptions
      validated, generated `call`/`call!`/async/stream/`available?`/`reset`.
- [ ] Rename `rescue_only` → `retry_on`; default `[]` (don't retry exceptions by
      default) — fixes the surprise in issue #7. Map old name with a deprecation.
- [ ] Unify terminology away from leaked "fuse" wording toward "circuit_breaker".

### M5 — Documentation overhaul
- [ ] Split the README into `guides/` (mirror Bond): getting-started, circuit
      breakers, retries, rate limiting, gateways, telemetry, error handling,
      migrating-to-2.0, about/history.
- [ ] ExDoc cheatsheets for retry/circuit-breaker recipes.
- [ ] `mix.exs` docs config with `extras` + `filter_modules` (internal: true).

### M6 — Release prep
- [ ] CHANGELOG, migration guide, deprecation warnings on 1.x paths.
- [ ] Cut `2.0.0-rc.1`, gather feedback, then `2.0.0`.

## Deferred to 2.1+
- Pluggable rate-limit backend (issue #12) and circuit-breaker/state backend for
  distributed Elixir (issue #13) — behind a `backend:` adapter contract.
- `Flow`-based `call_async_stream` option (TODO).
- Decorator-based annotations for marking external calls (TODO).
