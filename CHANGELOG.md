# Changelog

All notable changes to this project, from version 1.0.0 onward, will be documented in this file.

The format is based on [Keep a Changelog](http://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](http://semver.org/spec/v2.0.0.html).

## [Unreleased]

Work toward 2.0 (see `ROADMAP.md`). The 2.0 line modernizes the project and
introduces breaking changes; a migration guide will accompany the release.

### Added
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
  `{:error, reason}` values) are unchanged. A full migration guide will ship with
  2.0.
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
  - `rescue_only` is now `retry_on`, and **defaults to `[]`** — raised exceptions
    are no longer retried by default ([issue #7](https://github.com/jvoegele/external_service/issues/7)).
    List exception modules in `:retry_on` to retry on them.
  - `call/3` and `call!/3` now also accept a keyword list of retry options.
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

[Unreleased]: https://github.com/jvoegele/external_service/compare/1.0.1...HEAD
[1.1.2]: https://github.com/jvoegele/external_service/compare/1.1.1...1.1.2
[1.1.1]: https://github.com/jvoegele/external_service/compare/1.1.0...1.1.1
[1.1.0]: https://github.com/jvoegele/external_service/compare/1.0.1...1.1.0
[1.0.1]: https://github.com/jvoegele/external_service/compare/1.0.0...1.0.1
[1.0.0]: https://github.com/jvoegele/external_service/compare/0.9.3...1.0.0
