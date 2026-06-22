# Getting Started

This guide walks you through adding `ExternalService` to a project and making
your first reliable call to an external API — with retries, a circuit breaker,
and (optionally) rate limiting all working for you out of the box.

For full reference material, see the `ExternalService` module docs.

## Installation

Add `external_service` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:external_service, "~> 2.0"}
  ]
end
```

Then run `mix deps.get`.

## The big idea

Calling an external service is risky: the network hiccups, the service is
briefly overloaded, or it goes down entirely. `ExternalService` wraps those
calls with two complementary safety mechanisms:

- **Retries** smooth over _transient_ failures by trying a failed request
  again, with configurable backoff.
- A **circuit breaker** protects you from a service that is _persistently_
  failing: once failures cross a threshold the breaker "opens" and further
  calls fail fast instead of piling up against a service that is already down.
- Optionally, a **rate limiter** keeps you under the call quota the external
  service imposes.

You wrap your call to the external service in a function, hand that function to
`ExternalService`, and it applies all of the above on every call.

## Your first service

The recommended way to use the library is the declarative **module front door**,
`use ExternalService`. Define a module for the service you depend on and
configure its behavior in one place:

```elixir
defmodule MyApp.Stripe do
  use ExternalService,
    circuit_breaker: [tolerate: 5, within: :timer.seconds(1), reset: :timer.seconds(5)],
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

A few things to notice:

- The module configures its own circuit breaker and retry policy. No fuse
  names to juggle at the call site.
- `charge/1` wraps the real Stripe call in a zero-argument function and passes
  it to the generated `call/1`.
- The function returns `:retry` (or `{:retry, reason}`) to ask for another
  attempt; any other value is treated as success and returned as-is.

## Start it under your supervisor

A service must be started before it can be called — starting installs its
circuit breaker (and rate limiter, if configured). Add the module to your
supervision tree:

```elixir
def start(_type, _args) do
  children = [
    MyApp.Stripe
    # ... the rest of your children
  ]

  Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
end
```

That's it. Anywhere in your application you can now call:

```elixir
MyApp.Stripe.charge(%{amount: 1000, currency: "usd", source: token})
```

and the retry, circuit-breaker, and rate-limit logic is applied automatically.

## Triggering a retry

Inside the function you pass to `call/1`, you decide what counts as a retriable
failure. There are two ways to ask for a retry:

1. return the atom `:retry`, or
2. return a tuple `{:retry, reason}`, where `reason` is any term (handy for
   logging and telemetry).

Any other return value is considered a success and is returned to the caller
untouched — including the function's own `{:error, reason}` values. This is the
key distinction: an `{:error, ...}` you return is _your_ error and passes
through; only `:retry`/`{:retry, reason}` drive the retry machinery.

```elixir
def fetch(id) do
  call fn ->
    case HTTP.get("/widgets/#{id}") do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} when status in 500..599 -> {:retry, status}
      {:ok, %{status: 404}} -> {:error, :not_found}   # not retried — your error
      {:error, %HTTPError{}} = err -> err             # not retried — your error
    end
  end
end
```

By default, **raised exceptions are not retried** — they propagate to the
caller. If you want an exception type to trigger a retry, list it in the
`:retry_exceptions` retry option; to retry based on the return value of a function
you don't want to modify, use the `:retry_on` predicate. See the
[Retries](retries.md) guide for the full set of retry knobs.

## Handling failures

When retries are exhausted or the circuit breaker is open, `call/1` returns a
structured error:

```elixir
case MyApp.Stripe.charge(params) do
  {:ok, result} ->
    handle_success(result)

  {:error, %ExternalService.RetriesExhausted{}} ->
    # transient failure outlasted our retry budget
    {:error, :payment_unavailable}

  {:error, %ExternalService.CircuitBreakerOpen{}} ->
    # the breaker is open; fail fast
    {:error, :payment_unavailable}

  {:error, reason} ->
    # an error your own function returned
    {:error, reason}
end
```

If you'd rather these failures raise instead of being returned, use the
generated `call!/1`. See the [Error handling](error-handling.md) guide for the
full picture.

## Where to go next

- **[The module front door](the-front-door.md)** — everything `use
ExternalService` generates, plus supervision and per-environment overrides.
- **[Circuit breakers](circuit-breakers.md)** — how the breaker trips and
  resets, and how to introspect it.
- **[Retries](retries.md)** — backoff strategies, jitter, attempt and time
  budgets, and retrying on exceptions.
- **[Rate limiting](rate-limiting.md)** — staying under a service's quota.
- **[Error handling](error-handling.md)** — `call` vs `call!` and the
  structured error types.
- **[Telemetry](telemetry.md)** — observing calls, retries, and breaker trips.
- **[Migrating to 2.0](migrating-to-2.0.md)** — upgrading from 1.x.
