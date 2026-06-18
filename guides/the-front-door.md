# The Module Front Door

`use ExternalService` is the recommended, declarative way to define a gateway to
an external service. You configure the circuit breaker, rate limiting, and
default retry options once at the module level, start the module under a
supervisor, and call the service through a small set of generated functions.

This guide covers what `use ExternalService` generates and how to operate it.
For the mechanics of each subsystem, see the [Circuit breakers](circuit-breakers.md),
[Retries](retries.md), and [Rate limiting](rate-limiting.md) guides.

## Defining a service

```elixir
defmodule MyApp.Stripe do
  use ExternalService,
    circuit_breaker: [tolerate: 5, within: :timer.seconds(1), reset: :timer.seconds(5)],
    rate_limit: [limit: 100, per: :timer.seconds(1)],
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

The options are exactly those accepted by `ExternalService.start/2`
(`:circuit_breaker`, `:rate_limit`, `:retry`, `:sleep_function`), plus:

- `:name` — the term that identifies the service. Defaults to the module name.

You rarely need `:name`; the module name is a perfectly good service identifier
and keeps things unambiguous.

## Starting the service

A service must be started before it is called. Starting installs the circuit
breaker and rate limiter and records the default retry options. Because `use
ExternalService` generates `child_spec/1`, you can place the module directly in
a supervision tree:

```elixir
children = [
  MyApp.Stripe
]

Supervisor.start_link(children, strategy: :one_for_one)
```

Under the hood the generated `start_link/1` installs the service's circuit
breaker and rate limiter. This is the only "process" the front door adds, and it
exists purely to tie the service's lifecycle to your supervision tree.

## Per-environment overrides

The child spec accepts overrides that are **deep merged** with the options given
to `use ExternalService`. This is the idiomatic way to tune a service per
environment — most usefully, to make tests fast and deterministic:

```elixir
# config-driven children
children = [
  {MyApp.Stripe, circuit_breaker: [tolerate: 1], retry: [max_attempts: 1]}
]
```

Because the merge is deep, you only override the keys you care about; everything
else falls back to the module-level configuration. For example, the override
above keeps the `:within` and `:reset` from the module and only changes
`:tolerate`.

## Generated functions

`use ExternalService` generates the following functions on your module:

| Function                       | Delegates to                              | Purpose                             |
| ------------------------------ | ----------------------------------------- | ----------------------------------- |
| `call/1`, `call/2`             | `ExternalService.call/2,3`                | Synchronous guarded call.           |
| `call!/1`, `call!/2`           | `ExternalService.call!/2,3`               | Like `call`, but raises on failure. |
| `call_async/1`, `call_async/2` | `ExternalService.call_async/2,3`          | Returns a `Task`.                   |
| `call_async_stream/2,3,4`      | `ExternalService.call_async_stream/3,4,5` | Parallel, streaming calls.          |
| `available?/0`                 | `ExternalService.available?/1`            | Is the breaker closed?              |
| `blown?/0`                     | `ExternalService.blown?/1`                | Is the breaker open?                |
| `reset/0`                      | `ExternalService.reset/1`                 | Force the breaker closed.           |
| `child_spec/1`, `start_link/1` | —                                         | Supervision integration.            |

The one- and two-argument `call` forms differ only in whether you pass retry
options explicitly:

```elixir
# Uses the module's default :retry options
call fn -> do_work() end

# Overrides them for this call only
call [max_attempts: 2, backoff: :linear, base: 50], fn -> do_work() end
```

See the [Retries](retries.md) guide for what the override keyword list accepts.

## Introspection

The generated `available?/0`, `blown?/0`, and `reset/0` let you inspect and
control the circuit breaker without referring to the service name:

```elixir
if MyApp.Stripe.available?() do
  MyApp.Stripe.charge(params)
else
  {:error, :payments_unavailable}
end
```

`available?/0` returns `true` when the breaker is closed (calls will be
attempted) and `false` when it is open or the service has not been started.
`blown?/0` is the direct "is the breaker open?" question. See
[Circuit breakers](circuit-breakers.md) for the semantics and caveats.

## Relationship to the functional API

Everything the front door generates is a thin wrapper over the functional
`ExternalService` API (`start/2`, `call/3`, `call!/3`, `call_async/3`,
`call_async_stream/5`, `available?/1`, `blown?/1`, `reset/1`). Reach for the
functional API directly when a service identifier isn't naturally a module — for
example, when you start services dynamically or key them on runtime values:

```elixir
ExternalService.start({:tenant, tenant_id},
  circuit_breaker: [tolerate: 5, within: 1_000]
)

ExternalService.call({:tenant, tenant_id}, fn -> fetch(tenant_id) end)
```

The two styles interoperate freely; the front door is just the ergonomic
default.

## Migrating from `ExternalService.Gateway`

`use ExternalService.Gateway` (the 1.x module-based gateway) still works but is
**deprecated** and emits a warning at compile time. It delegates to `use
ExternalService` and keeps the old `external_call/*` and `reset_fuse/0` names as
aliases — but it uses the new option shape, so the old `fuse: [...]` options are
gone. See [Migrating to 2.0](migrating-to-2.0.md) for the mapping.
