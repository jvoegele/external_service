# Changelog

All notable changes to this project, from version 1.0.0 onward, will be documented in this file.

The format is based on [Keep a Changelog](http://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](http://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- **The guides are re-derived and re-measured** for the 3.0 semantics
  ([issue #97](https://github.com/jvoegele/external_service/issues/97)). The
  [Tuning](guides/tuning.md) guide loses two of the three couplings it existed to
  warn about, and three of the seven items on its checklist, because the library
  now computes or rejects them. Its three worked configurations were re-derived
  and measured again against a running service.

- **The circuit breaker's `:tolerate` now counts failing calls, not failing
  attempts** — a breaking change
  ([issue #93](https://github.com/jvoegele/external_service/issues/93)).
  A call melts the breaker once, when its retrying gives up, rather than once per
  failing attempt. `tolerate: 3` means three dead calls, whatever `:max_attempts`
  is.

  This removes the two couplings that `guides/tuning.md` exists to warn about.
  `:tolerate` and `:max_attempts` could not previously be tuned independently:
  raising the attempt count made the breaker open *sooner*, because each call
  spent more of its budget — and with `tolerate: 5, max_attempts: 8` the very
  first call melted the breaker five times inside its own retry loop and had its
  remaining attempts rejected by the breaker it had just opened. A call's melts
  were also spread across its whole retry window, so `:within` had to be wider
  than that window or they never accumulated at all.

  Three consequences worth reading before upgrading, all covered in the
  [migration guide](guides/migrating-to-3.0.md):

  - **Divide your `:tolerate` by the `:max_attempts` it was sized against.** Left
    alone it now means that many *calls*, so the breaker opens later than
    intended — silently, and in the dangerous direction.
  - **`:within` may need to be wider.** Melts now arrive one per call rather than
    several per call, so the window has to span the interval across which
    `:tolerate` failing calls arrive. Slow services need a wider window than
    before, not a narrower one.
  - **Unbounded retrying now needs a time budget.** A call that never gives up
    never melts, so `max_attempts: :infinity` with no `:expiry` would retry
    forever with nothing to stop it. That combination now raises, at `start/2`
    and at any `call/3` that overrides its way into it.

  `circuit_breaker: [melt: :per_attempt]` restores the pre-3.0 semantics in full,
  including the breaker acting as the backstop for an unbounded retry loop.

  A call that fails some attempts and then succeeds no longer melts at all.
  Retries did their job, and a breaker that opened on it would convert working
  calls into errors. `[:external_service, :call, :retry]` telemetry still fires
  per attempt under both settings, so degraded-but-succeeding traffic remains
  observable.

### Added
- **`ExternalService.explain/1`** — a report of what a configuration will do
  ([issue #90](https://github.com/jvoegele/external_service/issues/90)). Takes
  either a started service or a keyword list, so a configuration can be examined
  before it ships as well as during an incident:

      IO.puts ExternalService.explain(MyApp.Stripe)

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
        ...

  Every line is derived from the options rather than measured, which is what the
  rest of this release makes possible: before it, most of this report would have
  had to say "it depends". A started service reports the options it is actually
  running with, including child-spec overrides and the resolved `:within`, and any
  configuration warnings appear in the report itself.

- **Configurations are now checked against each other**, at compile time for
  services declared with `use ExternalService` and at start time for everything
  else ([issue #91](https://github.com/jvoegele/external_service/issues/91)).

  `NimbleOptions` validates every option in isolation, which is why every trap in
  the tuning guide is a pair of options that are individually valid and jointly
  wrong — and why this library shipped a recommended configuration whose breaker
  never opened. Four checks, each naming the setting to change and a value to try:

  | Finding | What it means |
  | --- | --- |
  | uncapped backoff above six attempts | a failing call waits minutes, most of it in the last attempt or two |
  | a call that trips its own breaker | under `melt: :per_attempt`, one call melts more times than `:tolerate`, so raising `:max_attempts` makes the service give up *sooner* |
  | unbounded retrying | under `melt: :per_attempt`, the breaker is the only backstop and is not a reliable one |
  | a window narrower than the failures it counts | `:within` cannot accumulate the failures needed to open the breaker |

  Compile-time findings carry a file and a line and fail a build compiled with
  `--warnings-as-errors`. Start-time findings are logged, which is what covers the
  functional API and child-spec overrides — the latter being runtime values that
  no compile-time check can see.

      config :external_service, on_suspicious_config: :warn   # | :raise | :ignore

- **The circuit breaker's `:within` now defaults to `:auto`**, sizing the
  failure-counting window against the retry options rather than being a flat
  `10_000` with no relationship to them
  ([issue #92](https://github.com/jvoegele/external_service/issues/92)). A flat
  window stops fitting the moment someone raises `:base`, which is the usual first
  move for an HTTP dependency — and a window narrower than the failures it has to
  count is a breaker that never opens.

  `:auto` reads what it needs from the retry options and the `:melt` setting: with
  the default `melt: :per_call` a call melts once, so `:tolerate` of them span
  `:tolerate` retry windows; with `melt: :per_attempt` a single call's melts are
  spread across its own retry window. It then doubles that, because the interval
  between two failing calls is a whole call — its retry window *plus* however long
  its attempts run for, which no configuration states. It is a **floor**, never
  narrower than the 10 seconds it replaces, so no existing service gets a narrower
  window than it had. An explicit `:within` is left exactly as given.

  What it cannot know is attempt duration: a failing call takes its retry window
  plus however long its attempts run for, and no configuration states the latter.
  Size `:within` yourself when your dependency's attempts are slow.

- **`ExternalService.RetryOptions.window/1`** — the total time a fully-failing call
  spends waiting between attempts, for a set of retry options
  ([issue #90](https://github.com/jvoegele/external_service/issues/90)). This is the
  number to compare against a caller's latency budget, and the one the circuit
  breaker's `:within` window has to be at least as wide as. Until now it existed
  only as a table in the tuning guide that readers had to look their configuration
  up in.

      RetryOptions.window(base: 100, max_attempts: 5)              #=> 1500
      RetryOptions.window(base: 100, max_attempts: 10, cap: 1_000) #=> 6500
      RetryOptions.window(base: 500, max_attempts: :infinity)      #=> :infinity

  Both tables in [the tuning guide](guides/tuning.md) are now asserted against this
  function, cell by cell, by a test that reads them out of the guide itself.

### Fixed
- **Internal: a retry configuration with an `:expiry` can now be inspected without
  waiting out its budget** ([issue #89](https://github.com/jvoegele/external_service/issues/89)).
  The delay sequence measures what is left of the budget against the monotonic
  clock, and it is the retry loop *sleeping* each delay that keeps the clock
  advancing in step with it. Drawing the sequence without sleeping decoupled the
  two, so `base: 500, cap: 5_000, expiry: 30_000, max_attempts: :infinity` took 25
  seconds to yield 2400 delays totalling 3.3 hours. A planning path now spends the
  budget against the delays themselves — the same trimming rule, written once —
  and answers the same configuration in microseconds with a sequence that totals
  the budget exactly. No change to what a real call does.

### Changed
- **Internal: extracted an ExternalService.Retry module**, so that retrying is owned by one
  module the way the circuit breaker, rate limiter and concurrency limit each are
  ([issue #86](https://github.com/jvoegele/external_service/issues/86)). It owns the
  delay streams, the retry loop, and the decision about whether an outcome counts as
  a retry at all. `ExternalService.RetryOptions` stays public and unchanged in shape —
  it remains the per-call configuration type callers construct, validate and merge —
  and simply no longer carries behavior. No public API moved and nothing observable
  changed.

## [3.0.0-rc.1] - 2026-08-18

3.0 changes four defaults and behaviors, and **renames nothing**. Your code
compiles unchanged; it behaves differently — which is what makes it a major.
Each change has a one-line way to keep the 2.x behavior.

**Start with the [migration guide](guides/migrating-to-3.0.md).** If your
application has been running 2.4.0 or later, its first section tells you in about
a minute which of these affect you, by grepping two strings out of your boot logs.

### Changed
- **The rate limit `:wait` now defaults to one window, capped at 5 seconds** — a
  breaking change, and part of the forthcoming 3.0
  ([issue #73](https://github.com/jvoegele/external_service/issues/73)).
  An unset `:wait` used to sleep the calling process until the limiter admitted
  it, so rate limiting paced calls without ever shedding: sustained throttling
  became unbounded latency and process growth rather than a fast `429`, even
  though `ExternalService.RateLimited` already carries `retry_after` and maps to
  429.

  One window (`:per`) is the value because it is the most a limiter can ask a
  caller to wait for the next refill — it absorbs a burst exactly and no more.
  Measured at `limit: 50, per: 1_000` on both the default GCRA limiter and the
  Hammer backend:

  | offered load | `wait: false` | one window | 2 × window |
  | --- | --- | --- | --- |
  | 2× instantaneous burst | 50% shed | **0% shed** | 0% shed |
  | 2× sustained | 27–35% shed | 15–17% shed | 1–5% shed, ~2× the latency |
  | 6× sustained | 71–75% shed | 64–67% shed | 55–58% shed |

  A burst is absorbed completely; sustained overload is still shed, which is the
  point — shedding is the right answer to real overload, and the larger budget
  buys a lower shed rate only by converting it back into latency. On the
  fixed-window Hammer backend one window is also the structural answer: a window
  boundary is never more than `:per` away.

  The 5-second cap keeps the derivation sane for a large window. A per-minute
  quota (`limit: 100, per: :timer.minutes(1)`) would otherwise block a caller for
  a full minute, which is barely better than not bounding the wait at all.

  **To keep waiting indefinitely, ask for it:**

  ```elixir
  rate_limit: [limit: 100, per: 1_000, wait: :infinity]
  ```

  That is the right setting for background jobs and **for Flow pipelines**, where
  sleeping is how back-pressure propagates upstream and a budget sheds work that
  has nowhere else to go. `guides/flow.md` recommends it explicitly, so a pipeline
  is the configuration most worth checking when upgrading.

  The unset-`:wait` warning is gone, having existed only to announce this.
- **`:max_attempts` now defaults to `5`** — a breaking change, and part of the
  forthcoming 3.0
  ([issue #43](https://github.com/jvoegele/external_service/issues/43)).
  Retry options that set neither `:max_attempts` nor `:expiry` used to retry
  **forever**, and the circuit breaker was not a reliable backstop: growing
  backoff delays outpace its `:within` window, so a fully default breaker paired
  with `retry: [base: 100]` never opens. Retrying now always stops on its own.

  `5` is the number `ExternalService.start/2` has been suggesting in its
  unbounded-retries warning since 2.4.0, and that the guides have shown
  throughout, so an application that took that advice is already on the 3.0
  default.

  Two things worth knowing about it. With the default `:base` of `10` the delays
  are `[10, 20, 40, 80]`, so this is a **bound** — 150ms of waiting — rather than
  a retry window tuned for a real dependency; raise `:base` (`100` for HTTP)
  rather than the attempt count. And because every failing attempt melts the
  circuit breaker, five attempts melt five of the ten a default breaker tolerates,
  so two fully-failing calls now open a breaker that previously never opened at
  all.

  **To keep unbounded retrying, ask for it:**

  ```elixir
  retry: [max_attempts: :infinity]
  ```

  `:infinity` has been accepted since 2.4.0, so this can be set before upgrading.
  The unbounded-retries warning is gone, having existed only to announce this.
- **`:decorator` is now an optional dependency** — a breaking change, and part of
  the forthcoming 3.0
  ([issue #48](https://github.com/jvoegele/external_service/issues/48)).
  `ExternalService.Decorator` — the `@decorate external_call` annotations — is a
  convenience layer that someone using the front door or the functional API never
  touches, but compiled anyway. It now gets the same treatment
  `ExternalService.Flow` has always had: the module is compiled only when its
  dependency is present, and the dependency is not forced on you.

  **If you use `@decorate external_call`, add it to your deps:**

  ```elixir
  {:decorator, "~> 1.4"}
  ```

  Unlike the other 3.0 changes this one is loud rather than silent — a build
  without it fails immediately and names the missing module:

  ```
  error: module ExternalService.Decorator is not loaded and could not be found
  ```

  If you do not use the annotations, there is nothing to do and one fewer
  transitive dependency in your tree.
- **Removed the `:deep_merge` dependency.** It was used in exactly one place —
  combining child-spec overrides with the options given to `use ExternalService` —
  and is replaced by an internal helper of about a dozen lines. This one changes
  nothing observable.

  The merge is subtler than "recurse into keyword lists", so it was ported
  deliberately rather than reinvented. In particular an empty override list means
  two different things depending on the original: `start_link(circuit_breaker: [])`
  leaves the configured breaker options alone, while `retry_exceptions: []` *does*
  clear `[RuntimeError]`, because that original is not keyword-shaped. Both rules
  are pinned by tests, and the port was checked against `DeepMerge.deep_merge/2`
  across 24 option shapes before the dependency was dropped.

  Together with `:decorator`, this takes the required runtime dependencies from
  six to **four** — `fuse`, `errata`, `nimble_options` and `telemetry` — with
  `decorator` and `flow` optional alongside them.
- **`:expiry` now honors a budget smaller than 100ms** — a breaking change, and
  part of the forthcoming 3.0
  ([issue #70](https://github.com/jvoegele/external_service/issues/70)).
  `:expiry` is documented as a time budget for retrying, but its final delay was
  floored at 100ms, so any budget below that was silently rounded up *and* bought
  an extra attempt. The final delay is now trimmed to whatever is left of the
  budget, placing the last attempt exactly at the deadline.

  Measured with `backoff: :exponential, base: 10` against a function that always
  retries:

  | `:expiry` | 2.x | 3.0 |
  | --------- | --- | --- |
  | 1ms | 2 attempts, 103ms | 2 attempts, 4ms |
  | 50ms | 2 attempts, 100ms | 4 attempts, 51ms |
  | 250ms | 6 attempts, 254ms | 6 attempts, 250ms — unchanged |
  | 1000ms | 8 attempts, 1001ms | 8 attempts, 1000ms — unchanged |

  **Only budgets under ~100ms are affected**; the floor never engaged above that.
  Note that such a budget changes in both directions at once — more attempts, in
  less time — because the retrying now proceeds at the pace the backoff asks for
  instead of waiting out a 100ms floor.

  Trimming was chosen over halting on the first delay that would overshoot.
  Halting looks like the stricter reading of "budget" but abandons most of it
  under exponential backoff — 630ms of a 1000ms budget, 2550ms of 5000ms —
  because the delay that does not fit is roughly as large as everything before it
  combined.

### Added
- **A [Tuning](guides/tuning.md) guide**
  ([issue #81](https://github.com/jvoegele/external_service/issues/81)). Each
  mechanism was documented on its own page; how they interact was not. The new
  guide covers which setting controls what (and which one people reach for by
  mistake), what a configuration costs as a measured table, the three couplings
  that produce surprises, a two-step rule for sizing the breaker against the
  retry settings, and worked configurations for a request path, a background job
  and a Flow pipeline. Every number in it was measured against the library.

### Fixed
- **The recommended HTTP configuration in the Retries guide had a circuit breaker
  that never opened.** `tolerate: 5, within: :timer.seconds(1)` was paired with
  retry settings whose window is about 1.5 seconds, so at most four of a call's
  five melts ever landed inside the same one-second window and `:tolerate` was
  never reached. Measured against it: **20 consecutive fully-failing calls across
  30 seconds of continuous failure, with the breaker still closed.**

  The configuration is now `tolerate: 15, within: :timer.seconds(5)`, which opens
  on the third consecutive fully-failing call, and both that guide and the
  Circuit Breakers guide now say that the breaker settings have to be sized
  against the retry settings rather than chosen independently.

## [2.8.0] - 2026-08-18

### Added
- **`:sleep_function` now covers retry backoff**, not just rate-limit and
  concurrency waiting. The retry loop used to sleep with a hardcoded
  `:timer.sleep/1` inside the dependency, so backoff was the one wait a caller
  could not intercept. Tests can now assert on the real backoff configuration
  instead of flattening it with `base: 0`:

  ```elixir
  ExternalService.start(service,
    retry: [max_attempts: 4, backoff: :exponential, base: 100],
    sleep_function: fn delay -> send(test_process, {:slept, delay}) end
  )

  ExternalService.call(service, fn -> :retry end)

  assert_received {:slept, 100}
  assert_received {:slept, 200}
  assert_received {:slept, 400}
  ```

  Note that a no-op sleep function is the right tool for retry backoff — the
  delays are a fixed sequence — but still the wrong one for rate limiting and
  concurrency, where the wait is a re-check loop and skipping it busy-waits. The
  Testing guide now says which is which.

### Changed
- **Removed the [ElixirRetry](https://hex.pm/packages/retry) dependency**
  ([issue #69](https://github.com/jvoegele/external_service/issues/69)). The
  retry loop and its delay streams are now part of this library. **No retry
  behavior changes**: the delay sequences were pinned by characterization tests
  first, and those tests pass unchanged against the new implementation.

  The delay-stream builders are reimplemented from `Retry.DelayStreams`
  (ElixirRetry, © 2014 Safwan Kamarrudin, Apache-2.0 — the same license as this
  project), with attribution in the source.

  This drops the required runtime dependencies from seven to six — `fuse`,
  `deep_merge`, `decorator`, `errata`, `nimble_options` and `telemetry`, with
  `flow` optional alongside them — and lets the retry loop use the service's
  `:sleep_function`. It also removed the project's
  `.dialyzer_ignore.exs` entirely: its three suppressed `pattern_match` warnings
  were artifacts of the `Retry.retry/2` macro's success typing, and `mix dialyzer`
  now reports no warnings at all with no filters in place.

  One deliberate improvement rather than a faithful port: the `:expiry` budget is
  measured with `System.monotonic_time/1` rather than the system clock, so a clock
  adjustment mid-call can no longer stretch or collapse a retry budget.

## [2.7.0] - 2026-08-18

### Added
- **`:retry_exceptions` accepts a predicate, not just a list of modules**
  ([issue #63](https://github.com/jvoegele/external_service/issues/63)).
  A module list settles retriability by *type*, which is the wrong grain when
  the same exception is transient in one instance and permanent in another — an
  HTTP client that raises one error struct for every status, say. Pass a
  predicate and it is run on the exception itself:

  ```elixir
  retry: [
    retry_exceptions: fn
      %MyApp.HTTPError{status: status} -> status >= 500
      _other -> false
    end
  ]
  ```

  A truthy return retries and melts the circuit breaker; anything else
  propagates the exception untouched, exactly as an unlisted module would. The
  predicate replaces the list rather than supplementing it, so fold any module
  checks you still want into it.

  This is what makes the raised half of an [Errata](https://hexdocs.pm/errata)
  integration expressible — an Errata error type can decide from its own
  `:reason` or `:context`, and a module list cannot ask it:

  ```elixir
  retry_exceptions: fn error ->
    Errata.is_error(error) and Errata.retryable?(error)
  end
  ```
- **The structured error types now declare their retryability**
  ([issue #62](https://github.com/jvoegele/external_service/issues/62)).
  Errata 1.5.0 added a retryability classification, and `Errata.retryable?/1`
  exposes it for any Errata error. Left to the default for infrastructure
  errors, all five of `ExternalService`'s error types would have answered
  `true` — including `ServiceNotStarted`, where retrying can never help.
  Each type now says so for itself:

  | Error                | `retryable?/1` |
  | -------------------- | -------------- |
  | `CircuitBreakerOpen` | `true`         |
  | `RateLimited`        | `true`         |
  | `ServiceSaturated`   | `true`         |
  | `RetriesExhausted`   | `false`        |
  | `ServiceNotStarted`  | `false`        |

  The three retryable ones share a shape: the wrapped function never ran, and
  the condition clears on its own. `ServiceNotStarted` is a configuration
  mistake — the same reasoning that gives it a `500` rather than a `503`.

  `RetriesExhausted` is the one worth reading twice. It is not retryable because
  retrying is exactly what has already failed, and an outer loop branching on
  `retryable?/1` would spin on it. Errata's classification carries no notion of
  *when*, so this means "not worth retrying now" — re-attempting the work at a
  coarser layer, such as a background job re-enqueuing itself minutes later, is
  still perfectly reasonable.

  Note that this describes `ExternalService`'s own errors only. What your wrapped
  function returns or raises still passes through untouched; `ExternalService`
  does not consult `Errata.retryable?/1` when deciding whether to retry your
  function.
- **An exception retry reason is chained as the error's `:cause`.**
  When a call exhausts its retries with a reason that is an exception — any
  Errata error included — that value is now set as `RetriesExhausted`'s `:cause`
  as well as its `:context.reason`. `Errata.cause/1` and `Errata.root_cause/1`
  reach the underlying failure, and `Errata.format_chain/1` prints it:

  ```
  ExternalService.RetriesExhausted: exhausted all retries while calling the external service
  Caused by: MyApp.UpstreamTimeout: upstream timed out
  ```

  A reason that is not an exception is left in `:context.reason` alone, with no
  `:cause` set.

- **A guide for applications that use Errata themselves**
  ([Using Errata in Your Application](guides/errata.md)). Covers letting your own
  error types drive retries through the `:retry_on` and `:retry_exceptions`
  predicates, the distinction between an error being retryable and a call being
  safe to repeat, how `RetriesExhausted` chains your error as its `:cause`, and
  the sharp edges — `require Errata` for the guard macro, guarding
  `Errata.retryable?/1` against non-Errata values, and aggregates being retryable
  only when every member is.

  It also documents something that applies well beyond Errata: predicates cannot
  be given to `use ExternalService` as anonymous functions, because the options
  are stored in a module attribute. A remote capture
  (`&MyApp.Retry.retryable_error?/1`) works; the Retries guide now says so too.

### Fixed
- **A retry predicate that fails no longer changes the outcome of the call**
  ([issue #67](https://github.com/jvoegele/external_service/issues/67)).
  A `:retry_exceptions` predicate runs on a path that is already failing, so a
  bug in it *replaced* the exception it had been called to classify — the caller
  got the predicate's error instead of its own, and nothing was retried. The
  `:retry_on` predicate was worse: because it runs inside the same rescue, its
  exception was itself evaluated against `:retry_exceptions`, so a matching
  `:retry_exceptions` would re-run an already-successful function for every
  remaining attempt.

  A predicate that fails — raising, throwing, or exiting rather than answering —
  is now treated as **no match**. The call's own result or exception is left
  exactly as it was, nothing is retried, the circuit breaker is untouched, and a
  warning naming the option, the service and the predicate's own failure is
  logged so the bug is findable:

  ```
  [warning] The :retry_exceptions predicate for :my_service did not return, so the
  call was treated as not retriable and its own result or exception was left
  untouched. ...

  ** (RuntimeError) predicate blew up
      lib/my_app/retry.ex:12: MyApp.Retry.transient?/1
  ```

  Not retrying is the safe reading: retrying is the consequential interpretation,
  and a predicate that just crashed has not authorized it.

  This is easy to hit by accident with [Errata](https://hexdocs.pm/errata):
  `Errata.is_error/1` is a guard macro, so a predicate module that forgets
  `require Errata` raises, and `Errata.retryable?/1` raises on any value that is
  not an Errata error.
- **A retried exception now keeps its original stacktrace.** When retries ran out
  while retrying an exception, it was re-raised with `raise/1`, which generates a
  fresh stacktrace — so the trace handed to the caller pointed into
  `ExternalService`'s own retry loop rather than at the code that raised:

  ```
  ** (RuntimeError) KABOOM!
      (external_service) lib/external_service.ex:815: ExternalService.call_with_retry/4
  ```

  The exception is now re-raised with the stacktrace captured where it was
  raised. For a library whose failure mode is "your call failed N times", the
  old behaviour discarded exactly the information you needed.

### Changed
- The `:errata` dependency requirement is now `~> 1.5` (was `~> 1.3`).

## [2.6.0] - 2026-08-05

### Added
- **A per-service concurrency limit — the bulkhead pattern**
  ([issue #49](https://github.com/jvoegele/external_service/issues/49)).
  `concurrency: [limit: 25, reclaim_after: :timer.seconds(30)]` caps how many
  calls may be in flight against a service at once. Over the limit a call is not
  dropped: it returns the new `ExternalService.ServiceSaturated` error to its
  caller, which is free to enqueue the work, serve something stale, or answer
  503. There is no cooldown — unlike the circuit breaker, a slot is available
  again the instant the call holding it finishes, so recovery is continuous.

  This closes the gap that opens when a service degrades rather than fails. The
  breaker counts failures, so slow-but-successful calls are invisible to it; the
  rate limiter counts *starts*, not concurrency, so `limit: 100, per: 1_000`
  against a service that slows to 10 seconds per call leaves roughly a thousand
  processes parked in the same call, each holding a connection.

  Saturation is your own backpressure rather than the service's failure, so it
  does not melt the circuit breaker and is not retried — exactly like
  `ExternalService.RateLimited`. `ServiceSaturated` maps to `503` rather than
  `429` for the same reason: it is your application shedding load, not the
  external service refusing you.

  State is an `:atomics` array with one slot per permit — no process, supervisor,
  or registry, the same design as `ExternalService.RateLimiter.Local`, at roughly
  0.4µs for an uncontended acquire and release. Slots are taken per *attempt* and
  inside the rate limiter, so a call sitting in backoff or sleeping on a `:wait`
  budget holds no capacity.
- **`:reclaim_after` bounds how long a slot may be held before it is reused.**
  A slot is released whenever the call finishes, raises, throws, or exits — but
  not when the calling process is killed from outside, because an exit signal
  does not run `after` blocks. That includes the ordinary `:shutdown` a
  supervisor sends while draining, so it is not an edge case. Without expiry each
  such caller would burn a slot permanently and the service would ratchet toward
  wedged; `:reclaim_after` bounds the damage to one slot for one window. It is
  required rather than defaulted because it must exceed the longest legitimate
  call, which depends on a client timeout the library cannot see.
- **An optional `:wait` budget on `:concurrency`** absorbs short bursts instead of
  shedding them. `concurrency: [limit: 25, reclaim_after: 30_000, wait: 50]` parks
  a caller for up to 50ms waiting for a slot before returning `ServiceSaturated`.
  Waiting callers hold no slot and no connection, so the number parked is bounded
  by arrival rate times the budget — smoothing without reintroducing the pile-up a
  concurrency limit exists to prevent. Defaults to `false` (shed immediately).

  Unlike the rate limiter's `:wait`, `:infinity` is **not** accepted: sleeping
  until a quota refills is bounded by the quota, but a slot only frees when
  another call finishes, so an unbounded wait is the pile-up itself. `start/2`
  raises with an explanation rather than a bare type error, since anyone reaching
  for it is coming from the rate limiter where `:infinity` is often correct.
- **`ExternalService.saturated?/1`** (with a generated `saturated?/0`), plus
  `ExternalService.Concurrency.in_flight/1` and `limit/1`, completing the trio
  with `available?/1` and `rate_limited?/1`. `reset_all/1` frees every slot.
- **`[:external_service, :concurrency, :rejected]` and
  `[:external_service, :concurrency, :waited]` telemetry**, and a new
  [Concurrency Limiting](concurrency.md) guide. The guide documents what a
  rejection actually means — the call is handed back to its caller, not dropped —
  that there is no cooldown, and the measured shed rate against offered load
  (0% below capacity, 12% at capacity, 54% at twice capacity).

### Changed
- **Documented that `ExternalService` imposes no timeout**
  ([issue #44](https://github.com/jvoegele/external_service/issues/44)). The
  breaker protects against a service that fails, not one that hangs: a blocking
  function blocks `call/3`, melts nothing, and trips no breaker — measured with
  `tolerate: 1`, a slow in-flight call leaves the service reporting
  `available?: true`. A new **When the service hangs** section in the circuit
  breaker guide says so plainly, shows where the timeout belongs (the client's
  receive *and* pool-checkout timeouts), and explains why running attempts in a
  `Task` would cost a process on the hot path without reliably cancelling
  anything.
- **Corrected what `:expiry` bounds.** It was documented as a time budget for
  retries, which reads like a wall-clock bound on the call. It is evaluated
  *between* attempts, so it bounds when the next attempt starts and never how
  long the current one runs. Measured with `max_attempts: 4, expiry: 100` against
  a function sleeping 300ms per attempt: 2 attempts, **706ms total** — seven times
  the budget. A function that never returns is never bounded by it at all. Both
  measurements are now pinned by tests.
- **The circuit breaker guide names what the library does not bound** — attempt
  duration and in-flight concurrency — and points at where each belongs. The rate
  limiter bounds how *often* calls start, not how many are running.

## [2.5.0] - 2026-08-05

### Added
- **`circuit_breaker: [tolerate: :infinity]` installs no breaker at all**
  ([issue #55](https://github.com/jvoegele/external_service/issues/55)). It never
  opens, ignores melts, and holds no state. Useful in production for a service
  where opening the breaker is worse than the failures it would prevent, and in
  tests because a breaker with no state cannot leak between them. Rejected in
  combination with `:fault_injection`, which exists to open the breaker — the
  contradiction raises at `start/2` rather than letting either option silently
  win.
- **`rate_limit: [limit: :infinity]` installs no limiter at all.** Calls pass
  straight through, exactly as if `:rate_limit` had been omitted. It exists for
  the case where omitting is not possible: child spec overrides are deep merged,
  so they can replace a key but never remove one.

  Together these are the answer to #55's "first-class test mode" question. Both
  are exact where `tolerate: 1_000_000` was only large, and both are meaningful
  outside tests, so neither is API whose only purpose is switching the library
  off. The [Testing](testing.md) guide now shows the combination, and says
  plainly that a service made inert is not a service being tested.
- **`ExternalService.RateLimiter.reset/1` discards a service's recorded rate
  limit usage**, and the `ExternalService.RateLimiter` behaviour gained a
  corresponding `c:ExternalService.RateLimiter.reset/2` callback. The control API
  was asymmetric without it: the circuit breaker could be asked, melted, and
  reset, but a drained rate limit budget could not be cleared at all.
- **`ExternalService.reset_all/1` clears every stateful mechanism for a service** —
  the circuit breaker and the rate limiter — with a `reset_all/0` counterpart
  generated by `use ExternalService`. `reset/1` still resets only the breaker,
  deliberately: clearing a limiter in production releases a burst at the service,
  which is rarely what someone closing a breaker intended. `reset_all/1` is what
  a test `setup` block wants.

## [2.4.0] - 2026-08-05

### Added
- **`ExternalService.start/2` now warns when a service configures no retry
  bound** ([issue #43](https://github.com/jvoegele/external_service/issues/43)).
  Retry options that set neither `:max_attempts` nor `:expiry` retry forever, and
  the circuit breaker does not reliably stop them: exponential backoff eventually
  spaces attempts further apart than the breaker's `:within` window, so failures
  stop accumulating fast enough to reach `:tolerate`. This is not a pathological
  corner — a fully default breaker with `retry: [base: 100]` never opens, and the
  call never returns. The library's own documentation has always advised against
  this configuration; now the advice reaches the place the mistake is made.
- **`:max_attempts` and `:expiry` accept `:infinity`.** It behaves exactly like
  leaving the bound unset, but states the intent explicitly and silences the new
  warning — for background work that really should retry until it succeeds, or
  for a service whose call sites each supply their own bound.
- **`ExternalService.start/2` now warns when a rate limited service sets no
  `:wait` budget** ([issue #47](https://github.com/jvoegele/external_service/issues/47)).
  A throttled call sleeps the calling process until the limiter admits it, which
  is correct for background work and wrong in a request path, where it converts
  load into latency and process growth instead of a fast 429. The warning fires
  only for services that configure `:rate_limit`. `wait: :infinity` states the
  unbounded intent explicitly and silences it.

- **A [Testing](testing.md) guide**
  ([issue #45](https://github.com/jvoegele/external_service/issues/45)). Covers
  the thing an adopter hits first and the guides never addressed: service state
  is global — it lives in `:persistent_term` and `:fuse` keyed on the service
  term — so nothing is torn down between tests and `async: true` tests sharing a
  service share one breaker and one rate-limit bucket. Also covers keeping tests
  off the clock, driving the breaker and limiter directly to reach failure paths,
  and asserting on telemetry. Every example is executed as part of this library's
  suite (`test/testing_guide_examples_test.exs`), so the guide cannot drift from
  the API.

### Changed
- **The `:max_attempts` documentation no longer describes the circuit breaker as
  a bound on retries**, because it isn't one in the general case (see above).
- **`:tolerate` is now documented as counting failed *attempts*, not failed
  calls** ([issue #46](https://github.com/jvoegele/external_service/issues/46)).
  Every failing retry attempt melts the breaker, so `:tolerate` and
  `:max_attempts` cannot be tuned independently: a `tolerate: 10` breaker paired
  with `max_attempts: 5` opens during the **third** failing call, not the tenth.
  The circuit breaker guide now carries the measured numbers and the arithmetic,
  and the retries guide cross-references it — it is the same coupling seen from
  the other side.
- **`:wait` no longer carries a documented default of `:infinity`.** Runtime
  behavior is unchanged — an unset `:wait` still waits as long as the limiter
  requires — but it is now distinguishable from an explicit `:infinity`, which
  is what lets `start/2` warn about the former only.

### Deprecated
- Leaving both retry bounds unset is on the path to becoming an error. A future
  3.0 is expected to give `:max_attempts` a finite default; `:infinity` is the
  forward-compatible way to keep unbounded behavior.
- Leaving `:wait` unset is likewise on the path to changing meaning. 3.0 is
  expected to default it to a finite, `:per`-derived budget; `wait: :infinity`
  is the forward-compatible way to keep waiting indefinitely.

### Fixed
- **The `:sleep_function` documentation no longer recommends a no-op for tests.**
  `sleep_function: fn _ms -> :ok end` was presented as the way to avoid real
  delays under a rate limit. It does not avoid them: the limiter is asked again
  immediately, still says wait, and the loop spins until real time has passed.
  Measured at `limit: 1, per: 2_000`, the throttled call still took 2000ms and
  invoked the no-op 2,075,418 times — the same wall clock, with a core burned.
  `:sleep_function` is documented as an instrumentation hook, and the Testing
  guide points at `wait: false` for keeping rate limited tests fast.
- **`guides/` is now included in the Hex package**
  ([issue #42](https://github.com/jvoegele/external_service/issues/42)). The
  README links into the guides eight times, and hex.pm renders the README out of
  the package tarball — which did not contain them, so every one of those links
  404'd on the package page. HexDocs was unaffected, since ExDoc reads the guides
  from the working directory at doc-build time and rewrites the links.

## [2.3.0] - 2026-07-31

### Added
- **A public control API for the circuit breaker and rate limiter**
  ([issue #26](https://github.com/jvoegele/external_service/issues/26)), for the
  cases that fall outside a guarded `call/3`. 2.2.0 made
  `ExternalService.CircuitBreaker` and `ExternalService.RateLimiter` public as
  *behaviours*; this makes them usable directly.
  - `ExternalService.CircuitBreaker.melt/1` records a failure the library never
    saw — a dropped streaming connection, a webhook that never arrived, a call
    made through a different client. It counts toward the service's `:tolerate`
    exactly as an in-call failure does, so enough melts open the breaker (and,
    with the cluster backend, open it across the cluster). The mirror image of
    `reset/1`.
  - `ExternalService.CircuitBreaker.ask/1` reports `:ok`, `:blown`, or
    `:not_started` — the three-valued form of `available?/1` and `blown?/1`.
  - `ExternalService.CircuitBreaker.reset/1`, the same operation
    `ExternalService.reset/1` performs.
  - `ExternalService.RateLimiter.request/1` spends one call's worth of budget
    without running anything, for traffic that reaches the service by some path
    other than `call/3`. It honors the service's `:wait` setting and returns
    `ExternalService.RateLimited` if that budget runs out.
- **Rate limit introspection.** `ExternalService.rate_limited?/1` reports whether
  a call would currently be throttled, and `ExternalService.RateLimiter.peek/1`
  reports how long the wait would be. Both are reads that **consume nothing**, so
  they are safe to ask speculatively before committing to expensive work —
  symmetric with `available?/1` for the circuit breaker.

### Changed
- **The `ExternalService.RateLimiter` behaviour gained a `peek/2` callback.**
  Backends must answer the same way as `check/2` without consuming anything.
  Both shipped backends implement it; `Local` reads its atomics slot without the
  compare-and-exchange, and `Hammer` assembles the answer from `get/2` and
  `expires_at/2`, since Hammer's `hit/3` both checks and consumes.

  This is a breaking change for anyone who wrote a rate limiter backend against
  2.2.0. It is being made immediately after that release, while no third-party
  backends exist, precisely so that it does not have to be made later.

## [2.2.0] - 2026-07-30

This line makes `ExternalService` work correctly on more than one node. See the
new [Distributed Elixir](guides/distributed.md) guide for the full picture.

The two halves of that problem are not the same kind of problem, and are not
solved the same way. A node-local **rate limit** is a correctness bug — four
nodes configured for 100 calls per second send up to 400, violating the quota you
configured — so the fix is shared counters. A node-local **circuit breaker** is a
defensible design rather than a bug, since a node with a bad network path should
stop calling a service without taking the cluster down with it, so cross-node
tripping is offered as an opt-in choice.

### Added
- **Pluggable circuit breaker and rate limiter backends**
  ([issue #12](https://github.com/jvoegele/external_service/issues/12),
  [issue #13](https://github.com/jvoegele/external_service/issues/13)).
  Both `:circuit_breaker` and `:rate_limit` accept a `:backend` option, given as
  a module or a `{module, options}` tuple whose options are passed through to
  that backend:

  ```elixir
  use ExternalService,
    circuit_breaker: [backend: ExternalService.CircuitBreaker.Cluster],
    rate_limit: [limit: 100, per: 1_000, backend: {MyApp.Limiter, some: :option}]
  ```

  `ExternalService.CircuitBreaker` and `ExternalService.RateLimiter` are now
  documented behaviours you can implement — five callbacks for a breaker, two for
  a limiter. Backends are stateless modules: the `install`/`init` callback returns
  an opaque config term that is stored with the rest of the service state and
  handed back to every other callback, so a backend needs no process, supervisor,
  or registry of its own.

  Note that this exposes the breaker and limiter *as behaviours*, not as
  user-facing control APIs; the operations themselves remain internal
  ([issue #26](https://github.com/jvoegele/external_service/issues/26)).
- **`ExternalService.CircuitBreaker.Cluster`**, an opt-in circuit breaker that
  trips the whole cluster when any one node trips
  ([issue #13](https://github.com/jvoegele/external_service/issues/13)). Each node
  keeps its own ordinary breaker; when one transitions from closed to open it
  sends a fire-and-forget `:erpc.multicast/4` to the other nodes, each of which
  trips its own breaker and then recovers on its own reset timer. There is no
  shared store, no distributed state, and no process or supervision tree for this
  library to run. A `:nodes` option (a list, or a zero-arity function returning
  one; default `&Node.list/0`) narrows the broadcast. Read the module docs before
  enabling it: it trades isolation for convergence, and one bad node can trip the
  whole cluster.
- **`ExternalService.RateLimiter.Hammer`**, a rate limiter backend that meters
  against a [Hammer](https://hexdocs.pm/hammer) module
  ([issue #12](https://github.com/jvoegele/external_service/issues/12)). With a
  shared Hammer backend such as
  [`hammer_backend_redis`](https://hexdocs.pm/hammer_backend_redis) every node
  draws from the same counters, so the service sees the limit you configured
  rather than that limit multiplied by your node count. Hammer is **not** a
  dependency of this library — the backend calls `hit/3` on the module you supply.
- **`rate_limit: [wait: ...]`** to bound how long a throttled call may block:
  `:infinity` (the default, and the previous behavior), a millisecond budget for
  the whole call, or `false` to never wait. Previously a throttled call waited as
  long as the limiter required with no upper bound.
- **`ExternalService.RateLimited`**, returned by `call/3` and raised by `call!/3`
  when the `:wait` budget runs out. The wrapped function is not called. It carries
  `:context.retry_after` (milliseconds until the call would have been admitted)
  and reports `http_status/1` of `429`. Being throttled is this library's own
  back-pressure rather than a failure of the external service, so it does **not**
  melt the circuit breaker and is **not** retried.
- A [Distributed Elixir](guides/distributed.md) guide, plus rate limiting and
  circuit breaker guide sections and cheatsheet entries covering the above.

### Changed
- **The default rate limiter is now a token bucket, and paces calls differently.**
  `ExternalService.RateLimiter.Local` replaces the `ex_rated` fixed window. It
  admits a burst of exactly `:limit` and then paces the rest at one call per
  `:per / :limit`, refilling one call at a time.

  What you will notice: waiting out a full window no longer hands you a fresh
  full burst. The fixed window allowed `:limit` calls at the end of one window and
  another `:limit` at the start of the next, briefly sending **twice** your
  configured rate at the service — which could trip the provider's own limiter
  even though you had configured yours correctly. Smoothing that out is the point
  of the change, but it does mean bursty workloads are now paced where they
  previously were not.

  No configuration changes: `:limit` and `:per` mean what they did before. The
  new limiter keeps its counters in a single `:atomics` slot per service, so it
  needs no owning process, and it is correct under concurrent access (a
  compare-and-exchange loop, rather than a lock or a best-effort counter).
- **Rate limit sleeps are now as long as they need to be, and no longer.** Backends
  report a real time-to-next-window, where `ex_rated` could only be given the
  `window / limit` estimate this library computed for it. Expect the
  `[:external_service, :rate_limit, :sleep]` telemetry to report different (and
  more accurate) durations.

### Removed
- **The `ex_rated` dependency**, which has had no release since December 2021.
  Rate limiting is now handled by the built-in `ExternalService.RateLimiter.Local`
  or a backend of your choosing.

  If your own code called `ExRated` directly — it was previously reaching you as a
  transitive dependency — add `{:ex_rated, "~> 2.1"}` to your `deps`. Nothing in
  the `ExternalService` API changes.

## [2.1.0] - 2026-07-30

### Added
- `ExternalService.Decorator`: decorator-based annotations for marking a function
  as an external call ([issue #28](https://github.com/jvoegele/external_service/issues/28)).
  `use ExternalService.Decorator` brings `@decorate external_call(service)` (and a
  raising `external_call!`) into scope, wrapping the function body in
  `ExternalService.call/2` (or `call/3` when passed per-call retry options) instead
  of writing `call fn -> ... end` by hand. Built on the
  [`decorator`](https://hex.pm/packages/decorator) library.
- `ExternalService.Flow`: process an enumerable (or an existing `Flow`) through
  guarded `ExternalService` calls as a stage of a [`Flow`](https://hexdocs.pm/flow)
  pipeline ([issue #27](https://github.com/jvoegele/external_service/issues/27)).
  `ExternalService.Flow.map/3,4,5` returns a `Flow`, reusing `call/3` per element
  so retries, the circuit breaker, rate limiting, telemetry, and the
  structured-error returns all apply (errors arrive as `{:error, ...}` elements;
  results are unordered). `:flow` is an **optional** dependency — the module is
  only compiled when you add it. For simple ordered parallel maps,
  `call_async_stream/5` remains the right tool.

## [2.0.0] - 2026-06-23

The 2.0 line modernizes the project and introduces breaking changes. See the
[migration guide](guides/migrating-to-2.0.md) for a step-by-step upgrade from
1.x.

### Added
- Documentation overhaul: a set of guides (Getting Started, the module front
  door, circuit breakers, retries, rate limiting, error handling, telemetry), a
  cheatsheet, and a step-by-step [migration guide](guides/migrating-to-2.0.md),
  all published on HexDocs.
- Introspection for circuit breaker state ([issue #5](https://github.com/jvoegele/external_service/issues/5)):
  `ExternalService.available?/1`, `ExternalService.blown?/1`, and
  `ExternalService.all_available?/1`, plus `available?/0` and `blown?/0` on
  modules using `ExternalService.Gateway`.
- `:telemetry` events for guarded calls: `[:external_service, :call, :start | :stop | :exception]`
  (a span around each call), `[:external_service, :call, :retry]`,
  `[:external_service, :circuit_breaker, :blown]`, and
  `[:external_service, :rate_limit, :sleep]`. See the `ExternalService` module
  docs for measurements and metadata.
- `RetryOptions.max_attempts` to bound the total number of attempts (initial plus
  retries), complementing the existing time-based `:expiry`.
- `RetryOptions.jitter` to control random jitter on retry delays (`true` for
  +/- 10%, or a float proportion such as `0.25`).
- `RetryOptions.retry_on` accepts a **predicate over the return value** (an
  arity-1 function), so retries can be driven from a function that does not itself
  return `:retry` / `{:retry, reason}` (the common case when adapting an existing
  client function). When the predicate returns a truthy value the call is retried
  — the result becomes the retry reason and the circuit breaker melts — exactly
  like an explicit `:retry` return, which still takes precedence
  ([issue #29](https://github.com/jvoegele/external_service/issues/29)).
- **Declarative module front door**: `use ExternalService` generates a small
  wrapper (`call/1,2`, `call!/1,2`, async/stream variants, `available?/0`,
  `blown?/0`, `reset/0`, `child_spec/1`, `start_link/1`) around a service
  configured with validated `:circuit_breaker`/`:rate_limit`/`:retry` options.
- A service now remembers the default retry options given to `start/2`; the
  two-argument `call/2` (and `call!/2`, `call_async/2`) use that default.
- Option validation via NimbleOptions for `start/2` and `RetryOptions`, with the
  accepted options rendered into the docs.
- Structured error types (built on [Errata](https://hexdocs.pm/errata)):
  `ExternalService.RetriesExhausted`, `ExternalService.CircuitBreakerOpen`, and
  `ExternalService.ServiceNotStarted`. Each is an exception struct carrying a
  `:context` (always including the `:service`), an `http_status/1`, and JSON
  encoding, so the same value can be returned from `call/3` or raised by
  `call!/3`.

### Changed (breaking)
- **Error representation overhauled.** `call/3` now returns structured error
  structs instead of nested tuples, and `call!/3` raises the same structs:

  | Before (1.x) | After (2.0) |
  | --- | --- |
  | `{:error, {:retries_exhausted, reason}}` | `{:error, %ExternalService.RetriesExhausted{context: %{service: name, reason: reason}}}` |
  | `{:error, {:fuse_blown, name}}` | `{:error, %ExternalService.CircuitBreakerOpen{context: %{service: name}}}` |
  | `{:error, {:fuse_not_found, name}}` | `{:error, %ExternalService.ServiceNotStarted{context: %{service: name}}}` |
  | raise `ExternalService.RetriesExhaustedError` | raise `ExternalService.RetriesExhausted` |
  | raise `ExternalService.FuseBlownError` | raise `ExternalService.CircuitBreakerOpen` |
  | raise `ExternalService.FuseNotFoundError` | raise `ExternalService.ServiceNotStarted` |

  Results returned directly by the wrapped function (including its own
  `{:error, reason}` values) are unchanged. See the
  [migration guide](guides/migrating-to-2.0.md) for the full mapping.
- **Configuration and terminology overhauled** to drop the leaked "fuse" wording:
  - `start/2` now takes `circuit_breaker: [tolerate:, within:, reset:, fault_injection:]`
    and `rate_limit: [limit:, per:]` (and an optional `retry:`) instead of
    `fuse_strategy: {:standard, max, window}` / `fuse_refresh:` and the
    `rate_limit: {limit, window}` tuple. Options are validated by NimbleOptions.
  - The `fuse_name` argument/type is now `service`.
  - `reset_fuse/1` is now `reset/1`.
- **Retry options reshaped** (`ExternalService.RetryOptions`):
  - `backoff` is now `:exponential` / `:linear` with separate `:base` and
    `:factor`, instead of `{:exponential, delay}` / `{:linear, delay, factor}`.
  - `randomize` is now `jitter`.
  - `rescue_only` is now `retry_exceptions`, and **defaults to `[]`** — raised
    exceptions are no longer retried by default ([issue #7](https://github.com/jvoegele/external_service/issues/7)).
    List exception modules in `:retry_exceptions` to retry on them.
    `:retry_exceptions` now also governs the circuit breaker: an exception that is
    not retried no longer melts the breaker (it propagates untouched), so a raised
    exception counts as a circuit-breaker failure only when its type is in
    `:retry_exceptions`. Explicit `:retry` / `{:retry, reason}` return values
    always melt the breaker.
  - `call/3` and `call!/3` now also accept a keyword list of retry options. A
    keyword list is treated as per-call *overrides*: it is merged onto the
    service's configured `:retry` defaults (overriding only the keys it lists and
    inheriting the rest). A `%RetryOptions{}` struct still replaces the defaults
    entirely.
- `use ExternalService.Gateway` is **deprecated** in favor of `use ExternalService`.
  It still works (emitting a deprecation warning) and keeps the `external_call/*`
  and `reset_fuse/0` names as aliases, but uses the same new option shape as
  `use ExternalService` — the old `fuse: [...]` options are no longer supported.

### Removed (breaking)
- The `ExternalService.RetriesExhaustedError`, `ExternalService.FuseBlownError`,
  and `ExternalService.FuseNotFoundError` exception modules, replaced by the
  structured error types above.

### Fixed
- `ExternalService.Gateway` now applies the `fuse: [strategy:, refresh:]` options
  it was configured with. Previously these keys did not match the
  `:fuse_strategy`/`:fuse_refresh` keys that `ExternalService.start/2` reads, so
  every gateway silently ran on the default circuit-breaker configuration.
- Added a regression test for the `:fault_injection` strategy (issue #4); the
  `:fuse_monitor` crash no longer reproduces on fuse 2.5.
- Rate limiting now works for a service whose name is any term, not only an atom
  or binary. The rate-limit bucket name is now derived with `inspect/1`;
  previously it used `Module.concat/2`, which raised for names such as tuples
  (circuit breaker and retries already accepted any term).

### Changed
- Raise the minimum Elixir requirement to `~> 1.15`.
- Modernize the build: refreshed dependency versions, added `nimble_options` and
  `telemetry`, ExDoc/Dialyxir bumps, GitHub Actions CI (test matrix, quality, and
  Dialyzer jobs), and Hex package/docs metadata cleanup.
- Store per-service state in `:persistent_term` instead of an unsupervised
  `Agent`, removing a process that could crash and was never linked to a
  supervisor. `ExternalService.stop/1` now accepts any term as a fuse name
  (matching `start/2`), not only atoms, and is idempotent — it is safe to call
  on a service that was never started or has already been stopped.

## 1.1.4 - 2024-01-04
### Fixed
- Replace use of deprecated `System.stacktrace/0` with `__STACKTRACE__/0` ([PR #17 from @iperks](https://github.com/jvoegele/external_service/pull/17))

## [1.1.3] - 2023-05-12
### Changed
- Update to retry 0.18.0
- Update ex_rated to 2.1

## [1.1.2] - 2021-09-30

### Changed
- Make sleep function configurable ([PR #11 from @doorgan](https://github.com/jvoegele/external_service/pull/11))

## [1.1.1] - 2021-09-17
### Changed
- Update to fuse 2.5
- Update ex_rated to 2.0

## [1.1.0] - 2021-09-17
### Added
- Add `ExternalService.stop/1` ([PR #9 from @doorgan](https://github.com/jvoegele/external_service/pull/9))

### Changed
- Allow any term as fuse name ([PR #10 from @doorgan](https://github.com/jvoegele/external_service/pull/10))


## [1.0.1] - 2020-06-08
### Added
- Add ability to reset fuses
- Add documentation for initialization and configuration of gateway modules

## [1.0.0] - 2020-06-05
### Added
- Add new ExternalService.Gateway module for module-based service gateways.
- Add this changelog...better late than never!

[Unreleased]: https://github.com/jvoegele/external_service/compare/3.0.0-rc.1...HEAD
[3.0.0-rc.1]: https://github.com/jvoegele/external_service/compare/2.8.0...3.0.0-rc.1
[2.8.0]: https://github.com/jvoegele/external_service/compare/2.7.0...2.8.0
[2.7.0]: https://github.com/jvoegele/external_service/compare/2.6.0...2.7.0
[2.6.0]: https://github.com/jvoegele/external_service/compare/2.5.0...2.6.0
[2.5.0]: https://github.com/jvoegele/external_service/compare/2.4.0...2.5.0
[2.4.0]: https://github.com/jvoegele/external_service/compare/2.3.0...2.4.0
[2.3.0]: https://github.com/jvoegele/external_service/compare/2.2.0...2.3.0
[2.2.0]: https://github.com/jvoegele/external_service/compare/2.1.0...2.2.0
[2.1.0]: https://github.com/jvoegele/external_service/compare/2.0.0...2.1.0
[2.0.0]: https://github.com/jvoegele/external_service/compare/1.1.4...2.0.0
[1.1.2]: https://github.com/jvoegele/external_service/compare/1.1.1...1.1.2
[1.1.1]: https://github.com/jvoegele/external_service/compare/1.1.0...1.1.1
[1.1.0]: https://github.com/jvoegele/external_service/compare/1.0.1...1.1.0
[1.0.1]: https://github.com/jvoegele/external_service/compare/1.0.0...1.0.1
[1.0.0]: https://github.com/jvoegele/external_service/compare/0.9.3...1.0.0
