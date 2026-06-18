# Error Handling

`ExternalService` distinguishes two kinds of failure:

- **Errors from the service itself** — whatever your wrapped function returns
  or raises. These pass through untouched; they are yours to handle.
- **Errors from `ExternalService`** — retries exhausted, or the circuit
  breaker open. These are surfaced as structured error types.

Keeping the two straight is the key to clean error handling. This guide covers
the structured error types and the choice between `call/3` and `call!/3`.

## The structured error types

`ExternalService` errors are built on [Errata](https://hexdocs.pm/errata)
infrastructure errors. The same struct is _returned_ by `call/3` (inside an
`{:error, struct}` tuple) and _raised_ by `call!/3`.

| Error                                | Returned/raised when                                      | `http_status/1` |
| ------------------------------------ | --------------------------------------------------------- | --------------- |
| `ExternalService.RetriesExhausted`   | retries (count or time budget) were exhausted             | `503`           |
| `ExternalService.CircuitBreakerOpen` | a call was rejected because the breaker is open           | `503`           |
| `ExternalService.ServiceNotStarted`  | a call was made to a service never started with `start/2` | `500`           |

Each carries a `:context` map that always includes the `:service` it relates to.
`RetriesExhausted` additionally carries `:context.reason` — the value from the
function's last `{:retry, reason}` return, or `:reason_unknown` if it returned a
bare `:retry`.

```elixir
{:error, %ExternalService.RetriesExhausted{context: %{service: svc, reason: reason}}} ->
  Logger.error("#{inspect(svc)} exhausted retries: #{inspect(reason)}")
```

Because they are Errata infrastructure errors, they also come with an
`http_status/1` and JSON encoding for free — convenient for turning a failure
into an HTTP response or a structured log entry. `ServiceNotStarted` maps to
`500` (it signals a configuration/programming mistake, not a transient outage);
the other two map to `503`.

## `call` — errors as values

`call/3` returns the structured error in an `{:error, struct}` tuple, alongside
your function's own results. Match on the struct types you care about:

```elixir
case MyApp.Stripe.charge(params) do
  {:ok, result} ->
    {:ok, result}

  {:error, %ExternalService.RetriesExhausted{}} ->
    {:error, :payment_temporarily_unavailable}

  {:error, %ExternalService.CircuitBreakerOpen{}} ->
    {:error, :payment_temporarily_unavailable}

  {:error, reason} ->
    # an error your own function returned, e.g. {:error, :card_declined}
    {:error, reason}
end
```

Notice the last clause: an `{:error, :card_declined}` that your function returned
is _not_ an `ExternalService` error. It flows through `call` unchanged, so you
handle it like any other domain result.

## `call!` — errors as exceptions

When the only thing you'd do with an `ExternalService` error is bail out, the
returned-tuple style adds noise: you must distinguish library errors from your
own results at every call site. `call!/3` raises the structured errors instead,
letting your happy path stay clean and your failure handling live in one
`rescue`:

```elixir
def create(conn, %{"message" => message}) do
  result = MyApp.PubSub.publish!(message, @topic)
  send_resp(conn, 201, encode(result))
rescue
  e in [ExternalService.RetriesExhausted, ExternalService.CircuitBreakerOpen] ->
    Logger.error(Exception.format(:error, e))
    send_resp(conn, 503, "")
end
```

`call!/3` only _raises_ the `ExternalService` errors; values your function
returns are still returned normally. And because every error knows its own
`http_status/1`, you can collapse the handling further:

```elixir
rescue
  e in [ExternalService.RetriesExhausted, ExternalService.CircuitBreakerOpen,
        ExternalService.ServiceNotStarted] ->
    send_resp(conn, ExternalService.RetriesExhausted.http_status(e), "")
end
```

## Which should I use?

- Use **`call/3`** when an `ExternalService` failure is a normal branch in your
  logic — you want to fall back to cached data, return a specific domain error,
  or otherwise react in line.
- Use **`call!/3`** when an `ExternalService` failure should abort the current
  unit of work and be handled uniformly higher up (a Phoenix action, an Oban
  job, a task). It keeps the happy path readable.

Both apply identical retry and circuit-breaker behavior; they differ only in how
the _library's_ failures are delivered.

## A note on exceptions from your function

Remember that, by default, exceptions raised by your wrapped function are **not
retried** — they propagate to the caller (out of both `call/3` and `call!/3`).
They are also not converted into `ExternalService` error types; a raised
`MyApp.HTTPError` comes out of `call` as a raised `MyApp.HTTPError`. If you want
such an exception retried, add its module to the `:retry_on` retry option (see
[Retries](retries.md)). If you want it returned rather than raised, catch it
inside your function and return an `{:error, reason}` (or `{:retry, reason}`)
value.

This matters especially for the async variants. `call_async/1` runs your function
in a linked `Task`, so an exception that propagates out of it crashes the task —
`Task.await/2` then re-raises it in the caller, and the link can take the caller
down if you don't await. In `call_async_stream/2`, an exception raised for one
element exits that task and, by default, propagates out of the stream. So for
background and bulk work, prefer returning `{:error, reason}` / `{:retry, reason}`
values (or listing the exception in `:retry_on`) over letting exceptions escape,
so one bad element can't crash the batch.
