# CLAUDE.md

## Project overview
- `external_service` is an Elixir library that provides retry logic, circuit breaker behavior, and optional rate limiting for external API/service calls.
- Core API and behavior live in `lib/external_service.ex`.
- Supporting modules:
  - `lib/external_service/retry_options.ex`
  - `lib/external_service/errors.ex` — Errata-based structured error types.
  - `lib/external_service/circuit_breaker.ex` — breaker behaviour, with the
    `Fuse` (default) and `Cluster` backends under `circuit_breaker/`.
  - `lib/external_service/rate_limiter.ex` — limiter behaviour, with the
    `Local` (default, GCRA) and `Hammer` backends under `rate_limiter/`.
  - `lib/external_service/decorator.ex` — `@decorate external_call` annotations.
  - `lib/external_service/flow.ex` — optional `:flow` integration.
  - `lib/external_service/gateway.ex` — deprecated 1.x front door.

## Repository structure
- `lib/` — library source code.
- `test/` — ExUnit test suite.
  - `test/external_service_test.exs` covers the main `ExternalService` module.
  - `test/external_service/` contains focused tests per module (front door,
    decorator, backends, rate limiters, cluster breaker, control API).
  - `test/support/` holds helpers compiled only in `:test`.
- `config/config.exs` — project configuration.
- `README.md` — overview that links into `guides/`.
- `guides/` — the user-facing documentation, published as ExDoc extras.
- `doc/` — generated docs output.

## Common development commands
- Install dependencies:
  - `mix deps.get`
- Run tests:
  - `mix test`
- Format code:
  - `mix format`
- Generate docs:
  - `mix docs`
- Optional quality checks (if used in local workflow):
  - `mix credo`
  - `mix dialyzer`

## Editing guidance
- Keep public API behavior in `ExternalService` backward-compatible unless explicitly changing a documented contract.
- Follow existing patterns for:
  - return values (`:retry`, `{:retry, reason}`, and error tuples),
  - error/exception handling (`call/3` vs `call!/3`),
  - typedocs and `@spec` coverage.
- Prefer focused tests near the behavior being changed:
  - add/adjust tests in `test/external_service_test.exs` for core API behavior,
  - use module-specific test files under `test/external_service/` for helper modules.

## Notes
- The project is a library (not a full OTP app with a running supervision tree in this repo).
- Fuse initialization via `ExternalService.start/2` is expected before making guarded calls.
