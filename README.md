# ExternalService

[![Hex.pm](https://img.shields.io/hexpm/v/external_service.svg)](https://hex.pm/packages/external_service)
[![Documentation](https://img.shields.io/badge/docs-hexdocs-blue.svg)](https://hexdocs.pm/external_service)

An Elixir library for safely calling external services and APIs with
customizable **retry logic**, the **circuit breaker** pattern, optional
**rate limiting**, and an optional **concurrency limit**. Calls can be
synchronous, asynchronous background tasks, or fanned out in parallel for
MapReduce-style processing — all under the same protection.

## Why?

Calling an external service is risky: the network hiccups, the service is briefly
overloaded, or it goes down entirely. `ExternalService` wraps those calls with
four complementary safety mechanisms:

- **Retries** smooth over *transient* failures by trying again with configurable
  backoff and jitter.
- A **circuit breaker** protects against a *persistently* failing service: once
  failures cross a threshold the breaker opens and calls fail fast instead of
  piling up against a service that is already down.
- A **rate limiter** keeps you under the call quota the service imposes.
- A **concurrency limit** (the bulkhead pattern) bounds how many calls can be
  in flight at once, catching a service that has degraded rather than failed.

You wrap your call in a function, hand it to `ExternalService`, and all of the
above is applied on every call.

## Installation

Add `external_service` to your dependencies in `mix.exs`:

```elixir
def deps do
  [{:external_service, "~> 3.0"}]
end
```

## Quick start

Define a module for the service, configuring it declaratively, and start it
under your supervisor:

```elixir
defmodule MyApp.Stripe do
  use ExternalService,
    circuit_breaker: [tolerate: 5, within: :timer.seconds(1), reset: :timer.seconds(5)],
    rate_limit: [limit: 100, per: :timer.seconds(1), wait: :timer.seconds(1)],
    retry: [max_attempts: 5, backoff: :exponential, jitter: true]

  def charge(params) do
    call fn ->
      case Stripe.charge(params) do
        {:ok, result} -> {:ok, result}
        {:error, %{status: status}} when status in 500..599 -> :retry
        other -> other
      end
    end
  end
end
```

```elixir
# In your supervision tree:
children = [MyApp.Stripe]
Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
```

Now call it from anywhere; retries, circuit breaking, rate limiting, and (if
configured) the concurrency limit are applied automatically:

```elixir
case MyApp.Stripe.charge(%{amount: 1000, currency: "usd", source: token}) do
  {:ok, result} ->
    handle_success(result)

  {:error, %ExternalService.RetriesExhausted{}} ->
    {:error, :payment_unavailable}

  {:error, %ExternalService.CircuitBreakerOpen{}} ->
    {:error, :payment_unavailable}

  {:error, reason} ->
    {:error, reason}
end
```

Inside the function you pass to `call/1`, return `:retry` or `{:retry, reason}`
to ask for another attempt; any other value is treated as success and returned
as-is.

## Documentation

Full documentation is on [HexDocs](https://hexdocs.pm/external_service). Start
with these guides:

- **[Getting Started](guides/getting-started.md)** — your first reliable call.
- **[The Module Front Door](guides/the-front-door.md)** — everything `use
  ExternalService` generates, plus supervision and overrides.
- **[Circuit Breakers](guides/circuit-breakers.md)** — how the breaker trips,
  resets, and how to introspect it.
- **[Retries](guides/retries.md)** — backoff, jitter, attempt/time budgets, and
  retrying on exceptions.
- **[Rate Limiting](guides/rate-limiting.md)** — staying under a quota.
- **[Concurrency](guides/concurrency.md)** — bounding how many calls are in
  flight at once with the bulkhead pattern.
- **[Tuning](guides/tuning.md)** — choosing the retry, breaker and limiter
  settings *together*, with the measurements behind each rule.
- **[Error Handling](guides/error-handling.md)** — `call` vs `call!` and the
  structured error types.
- **[Using Errata](guides/errata.md)** — for applications that define their own
  [Errata](https://hexdocs.pm/errata) errors: letting them drive retries, and
  what comes back when they don't succeed.
- **[Telemetry](guides/telemetry.md)** — observing calls, retries, and trips.
- **[Testing](guides/testing.md)** — driving retries, breaker trips, and
  throttling from your test suite.
- **[Running on more than one node](guides/distributed.md)** — sharing the
  circuit breaker and rate limit across a cluster.
- **[Flow Pipelines](guides/flow.md)** — guarded calls inside a `Flow`.
- **[Cheatsheet](guides/cheatsheet.cheatmd)** — a one-page reference.
- **[Migrating to 3.0](guides/migrating-to-3.0.md)** — upgrading from 2.x.
- **[Migrating to 2.0](guides/migrating-to-2.0.md)** — upgrading from 1.x.
- **[About](guides/about.md)** — the ideas behind the library and its history.

## Upgrading

Version 3.0 changes several defaults and one behavior, and renames nothing: your
code compiles unchanged and behaves differently. Start with the
[3.0 migration guide](guides/migrating-to-3.0.md), whose first section tells you
in about a minute which changes affect you.

Version 2.0 was a breaking modernization of the library; see the
[2.0 migration guide](guides/migrating-to-2.0.md). The
[CHANGELOG](CHANGELOG.md) has the full list of changes for both.

## License

Released under the Apache 2.0 license. Originally sponsored by Ropig.
