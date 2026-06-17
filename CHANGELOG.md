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
