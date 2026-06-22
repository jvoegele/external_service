# CLAUDE.md

## Project overview
- `external_service` is an Elixir library that provides retry logic, circuit breaker behavior, and optional rate limiting for external API/service calls.
- Core API and behavior live in `lib/external_service.ex`.
- Supporting modules:
  - `lib/external_service/retry_options.ex`
  - `lib/external_service/rate_limit.ex`
  - `lib/external_service/gateway.ex`

## Repository structure
- `lib/` — library source code.
- `test/` — ExUnit test suite.
  - `test/external_service_test.exs` covers the main `ExternalService` module.
  - `test/external_service/` contains focused tests for gateway and rate limiting.
- `config/config.exs` — project configuration.
- `README.md` — detailed usage docs and examples.
- `doc/` — additional documentation assets.

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
