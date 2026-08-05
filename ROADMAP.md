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

### M4 — Module front door polish ✓
- [x] `use ExternalService` (the blessed front door): unified, NimbleOptions-validated
      `circuit_breaker:` / `rate_limit:` / `retry:` config; generated
      `call`/`call!`/async/stream/`available?`/`blown?`/`reset`/`child_spec`/`start_link`.
      `ExternalService.Gateway` is now a deprecated wrapper.
- [x] `rescue_only` → `retry_on`, default `[]` (don't retry exceptions by default) — fixes #7.
- [x] Terminology cleanup: `fuse_name` → `service`, `fuse_strategy`/`fuse_refresh` →
      `circuit_breaker: [...]`, `reset_fuse` → `reset`, `RetryOptions` reshaped
      (atom `backoff` + `base`/`factor`, `jitter`), NimbleOptions validation throughout.
- [x] Services remember their default retry options (`start/2` `:retry`), used by `call/2`.

> Circuit-breaker melt semantics were left unchanged in M4 and revisited in M6:
> as of M6, `:retry_on` governs both retrying and melting — a raised exception
> melts the breaker only when its type is retriable.

### M5 — Documentation overhaul ✓
- [x] Split the README into `guides/` (mirror Bond): getting-started, the module
      front door, circuit breakers, retries, rate limiting, error handling,
      telemetry, migrating-to-2.0, about/history. README slimmed to a 2.0-accurate
      overview that links into the guides.
- [x] ExDoc cheatsheet (`guides/cheatsheet.cheatmd`) for retry/circuit-breaker recipes.
- [x] `mix.exs` docs config with `extras` + `groups_for_extras` + `filter_modules`
      (internal: true); `main` now the Getting Started guide.
- [x] Wrote the 1.x → 2.0 migration guide the CHANGELOG references.

### M6 — Release prep
- [x] `:retry_on` now governs circuit-breaker melting (non-retried exceptions no
      longer trip the breaker).
- [x] CHANGELOG/migration-guide final pass; deprecation-warning review on 1.x
      paths (the `use ExternalService.Gateway` compile-time warning is the only
      one; functional-API renames are clean breaks with clear validation errors).
- [x] Bump version to `2.0.0-rc.1` and stamp the CHANGELOG.
- [x] Tag and publish `2.0.0-rc.1` to Hex
      ([package](https://hex.pm/packages/external_service/2.0.0-rc.1)).
- [ ] Gather RC feedback, then release `2.0.0` (final) (#25).

## Deferred to 2.1+
- ~~Pluggable rate-limit backend (issue #12) and circuit-breaker/state backend
  for distributed Elixir (issue #13)~~ — shipped in 2.2.0 behind a `backend:`
  adapter contract, with `ExternalService.CircuitBreaker.Cluster` and
  `ExternalService.RateLimiter.Hammer` as the distributed implementations. See
  the Distributed Elixir guide.
- ~~**Public `ExternalService.CircuitBreaker` / `ExternalService.RateLimiter`
  modules** (#26)~~ — deferred out of 2.0, then shipped in two steps.

  The pre-2.0 rationale for waiting was that the two were thin shells over
  `:fuse` / `ex_rated`, so exposing them would have frozen those dependencies
  into the public contract and fought the `backend:` adapter goal. Doing the
  backend work first dissolved that objection: what is public now is the
  *behaviour contract*, not a third-party API, and `ex_rated` is gone entirely.

  - **2.2.0** exposed both as documented **behaviours** with default
    implementations (the seam for #12/#13), and renamed the internal
    `ExternalService.RateLimit` to the agent-noun `RateLimiter`. Control
    operations stayed `@doc false`.
  - **After 2.2.0**, the control operations became public: `CircuitBreaker.melt/1`
    (report a failure the library never saw), `ask/1`, `reset/1`, and
    `RateLimiter.request/1`, plus the rate-limit *read* helper this roadmap
    anticipated — `ExternalService.rate_limited?/1`, backed by a new
    non-consuming `peek/2` behaviour callback.
- ~~`Flow`-based `call_async_stream` option (#27)~~ — shipped in 2.1.0 as
  `ExternalService.Flow`.
- ~~Decorator-based annotations for marking external calls (#28)~~ — shipped in
  2.1.0 as `ExternalService.Decorator`.

## Deferred to 3.0
- **Give `:max_attempts` a finite default** (#43). Retry options that set neither
  `:max_attempts` nor `:expiry` retry forever, and the circuit breaker is not a
  reliable backstop — growing backoff delays outpace its `:within` window, so a
  fully default breaker with `retry: [base: 100]` never opens. Changing the
  default is the fix the documentation has always implied, but it silently
  changes behavior for anyone relying on unbounded retries, so it belongs in a
  major version.

  The groundwork is in place as of the unreleased 2.x: `start/2` warns when both
  bounds are unset, and `:infinity` is accepted as an explicit, forward-compatible
  way to keep unbounded behavior. 3.0 changes the default and the warning goes
  away.

- **Give the rate limit `:wait` a finite default** (#47). An unset `:wait` sleeps
  the calling process until the limiter admits it. That is right for background
  work and wrong in a request path, where it turns load into latency and process
  growth instead of a fast 429 — and `ExternalService.RateLimited` already carries
  `retry_after` and maps to 429, but the default configuration can never produce
  it.

  The wait is also not as predictable as it looks. A single backend check never
  reports more than one emission interval (`:per / :limit`), so long waits come
  from the re-check loop, which has no queue and is unfair: measured at
  `limit: 50, per: 1_000`, one caller against a herd of 25 blocked for 1.7s, 4.4s
  and 5.2s across three runs of the same scenario.

  **The 3.0 default should be a finite budget derived from `:per`, not `false`.**
  Measured at `limit: 50, per: 1_000`, a one-window (1000ms) budget sheds 0% at
  1× offered load, 1% of a 2× instantaneous burst, 9% of a 2× sustained load and
  50% under 6× sustained — it absorbs bursts and sheds only real overload.
  `wait: false` sheds 50% of that same 2× burst, which would make bursty-but-
  healthy traffic look like an outage. One window is the value to beat; the exact
  multiple is worth re-measuring against the Hammer backend before committing.

  Groundwork is in place as of the unreleased 2.x: `:wait` has no schema default,
  so an unset value is distinguishable from an explicit `:infinity`; `start/2`
  warns about the former, and `:infinity` is the forward-compatible way to keep
  waiting indefinitely.
