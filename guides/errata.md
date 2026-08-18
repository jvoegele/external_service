# Using Errata in Your Application

`ExternalService`'s own failures are [Errata](https://hexdocs.pm/errata) errors —
see [Error Handling](error-handling.md) for the five types and what they carry.
That is true whether or not you use Errata yourself.

If your application *also* defines Errata errors, the two libraries meet in two
more places: the errors your wrapped functions hand to `ExternalService`, and
what `ExternalService` hands back. This guide covers both.

## Both libraries' errors answer the same questions

An Errata error classifies itself — an HTTP status, a log severity, and whether
it is worth retrying — so error handling at the edge of your application does not
have to know which library produced the failure:

```elixir
require Errata

def to_response({:error, error}) when Errata.is_error(error) do
  Logger.log(Errata.severity(error), Errata.format_chain(error))
  send_resp(conn, Errata.http_status(error), render(error))
end
```

Fed `ExternalService`'s errors and your own, that handler behaves consistently:

| Error                              | `http_status/1` | `retryable?/1` |
| ---------------------------------- | --------------- | -------------- |
| `ExternalService.RetriesExhausted`  | `503`           | `false`        |
| `MyApp.HTTPError` (status 503)      | `503`           | `true`         |
| `MyApp.CardDeclined` (domain error) | `422`           | `false`        |

## Retrying on your own errors' say-so

`Errata.retryable?/1` is a classification, not a retry mechanism. `ExternalService`
is the mechanism, and two retry options connect them: `:retry_on` for errors your
function *returns*, and `:retry_exceptions` for errors it *raises*.

Both take a predicate, so both can ask the error itself:

```elixir
defmodule MyApp.Retry do
  require Errata

  @doc "True when `error` is an Errata error that classifies itself as retryable."
  def retryable_error?(error), do: Errata.is_error(error) and Errata.retryable?(error)

  @doc "The same question, asked of a `{:error, error}` return value."
  def retryable_result?({:error, error}), do: retryable_error?(error)
  def retryable_result?(_other), do: false
end
```

```elixir
defmodule MyApp.Stripe do
  use ExternalService,
    retry: [
      max_attempts: 5,
      backoff: :exponential,
      base: 100,
      retry_on: &MyApp.Retry.retryable_result?/1,
      retry_exceptions: &MyApp.Retry.retryable_error?/1
    ]
end
```

Now the error type decides. An `Errata.InfrastructureError` is retryable by
default, an `Errata.DomainError` is not, and a type that overrides `retryable?/1`
decides per instance:

```elixir
defmodule MyApp.HTTPError do
  use Errata.InfrastructureError, default_message: "the request failed"

  def retryable?(%{context: %{status: status}}) when is_integer(status), do: status >= 500
  def retryable?(_error), do: true
end
```

With the service above, and `max_attempts: 3` for legibility:

| Your function                          | Attempts | Result                       |
| -------------------------------------- | -------- | ---------------------------- |
| returns `{:error, %UpstreamTimeout{}}`  | 3        | `RetriesExhausted`           |
| returns `{:error, %CardDeclined{}}`     | 1        | returned untouched           |
| raises `%UpstreamTimeout{}`             | 3        | re-raised after the last try |
| raises `%CardDeclined{}`                | 1        | raised untouched             |
| returns `{:error, %HTTPError{status: 503}}` | 3    | `RetriesExhausted`           |
| returns `{:error, %HTTPError{status: 404}}` | 1    | returned untouched           |

A retried error melts the circuit breaker; an error that passes through leaves it
alone. That is the same rule as for any other retry: see
[Circuit Breakers](circuit-breakers.md).

> #### Named functions, not anonymous ones, under `use ExternalService` {: .warning}
>
> The options given to `use ExternalService` are stored in a module attribute,
> which cannot hold an anonymous function:
>
> ```elixir
> use ExternalService, retry: [retry_exceptions: fn error -> ... end]
> # ** (ArgumentError) cannot inject attribute @__external_service_opts__ into
> #    function/macro because cannot escape #Function<...>
> ```
>
> A remote capture — `&MyApp.Retry.retryable_error?/1` — is a valid attribute
> value and works fine, which is why the predicates above live in a named module.
> `ExternalService.start/2` and per-call retry options are evaluated at runtime
> and accept either form.

Note that `retryable_result?/1` matches `{:error, error}` because that is the
shape *these* functions return. Yours is yours to match — a function returning
`{:error, error, metadata}`, or the error bare, wants a clause for that shape.
This is why `ExternalService` has no built-in "retry Errata errors" switch:
there is no single return shape it could assume on your behalf.

## Retryability is not idempotency

`Errata.retryable?/1` answers *"could this failure succeed on another attempt?"*
It does not answer *"is it safe to make this call twice?"* — and only the second
question decides whether a retry is correct.

Retryability is a claim the error's author made about the failure. Idempotency is
a property of the call site. A `%MyApp.PaymentGatewayTimeout{}` is a genuine
infrastructure error and genuinely retryable in the abstract; retrying it against
`POST /charges` may bill the customer twice, because a timeout is precisely the
case where you do not know whether the first call landed.

So wire these predicates per service — or per call — rather than reaching for a
global default:

```elixir
defmodule MyApp.Stripe do
  use ExternalService,
    retry: [
      max_attempts: 5,
      # Safe: reads can be repeated freely.
      retry_on: &MyApp.Retry.retryable_result?/1
    ]
end

# ...and for a charge, either don't retry...
MyApp.Stripe.call([max_attempts: 1], fn -> create_charge(params) end)

# ...or make the call idempotent first, and then retrying is safe.
MyApp.Stripe.call(fn -> create_charge(params, idempotency_key: key) end)
```

## What comes back

When retries run out, `ExternalService.RetriesExhausted` carries what happened in
`:context.reason`. When that reason is an exception — including any Errata error
— it is also the error's `:cause`, so your failure is reachable through Errata's
own accessors:

```elixir
{:error, error} = MyApp.Stripe.call(fn -> {:retry, MyApp.UpstreamTimeout.new()} end)

Errata.cause(error)       #=> %MyApp.UpstreamTimeout{}
Errata.root_cause(error)  #=> the deepest cause, following the chain
Errata.format_chain(error)
#=> ExternalService.RetriesExhausted: exhausted all retries while calling the external service
#=> Caused by: MyApp.UpstreamTimeout: the upstream service timed out
```

The `:cause` is set from the retry *reason*, so it engages when your function
raised, and when it returned `{:retry, error}` as above. A retry driven by the
`:retry_on` predicate records the whole return value as the reason — `{:error,
%MyApp.UpstreamTimeout{}}` is a tuple, not an exception, so no `:cause` is set
and the error stays in `:context.reason`. Where you control the function and want
the chain, return `{:retry, error}` rather than leaning on the predicate.

Note also that `RetriesExhausted` is itself *not* retryable, so a caller of yours
that branches on `Errata.retryable?/1` will not loop on it. See
[Error Handling](error-handling.md#retryability).

## Sharp edges

**`Errata.is_error/1` is a guard macro, so its module needs `require Errata`.**
Without it the predicate raises `UndefinedFunctionError` the first time it runs.
A predicate that fails is treated as "not retriable" and logs a warning, leaving
your call's own result or exception untouched — so this shows up as retries that
never happen, plus a warning naming the option and the service, rather than as a
mystery exception.

**`Errata.retryable?/1` raises on values that are not Errata errors.** Any
predicate will eventually be handed something else — a `DBConnection` error, a
`RuntimeError` from a bug — so guard with `Errata.is_error/1` first, as
`retryable_error?/1` does above, rather than calling `retryable?/1` bare.

**An aggregate is retryable only when every member is.** `Errata.Aggregate` takes
the conservative reading: one permanent failure among five makes retrying the
whole aggregate pointless. A validation failure holding one timeout and one
declined card is not retryable, and these predicates will pass it through.
