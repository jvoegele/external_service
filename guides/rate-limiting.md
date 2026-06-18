# Rate Limiting

Many external services impose a quota: _no more than N requests per time
window._ Exceed it and you get throttled (or billed, or blocked).
`ExternalService` can keep you under that quota automatically, across your entire
application, using the [ex_rated](https://hex.pm/packages/ex_rated) library.

Rate limiting is **opt-in**: omit the `:rate_limit` option and no limiting is
applied.

## Configuration

Add a `:rate_limit` option with a `:limit` and a `:per` window (in
milliseconds):

```elixir
use ExternalService,
  rate_limit: [
    limit: 100,                # at most 100 calls...
    per: :timer.seconds(1)     # ...per 1-second window
  ]
```

| Option   | Required | Meaning                                                    |
| -------- | -------- | ---------------------------------------------------------- |
| `:limit` | yes      | Maximum number of calls allowed within each `:per` window. |
| `:per`   | yes      | Length of the rate-limiting window, in milliseconds.       |

Both keys are required when `:rate_limit` is present.

## How it works

The limit is tracked per service and shared across every caller in your
application — every process that calls the service draws from the same bucket. So
the example above guarantees no more than 100 calls per second _in total_, no
matter how many processes are making them.

When a call would exceed the limit, `ExternalService` does not fail it. Instead
it **sleeps** until the window has room, then proceeds. From your code's point of
view the call simply takes a little longer; it still succeeds.

```elixir
# This will never make more than 100 calls/second, even in a tight loop —
# excess calls sleep until the window allows them.
Enum.each(1..10_000, fn i ->
  MyApp.Api.fetch(i)
end)
```

## Who sleeps?

The sleeping happens in whichever process is making the call:

- With `call/1` (synchronous), the **calling process** sleeps. Your code blocks
  until the call is allowed.
- With `call_async/1` and `call_async_stream/2`, the **background task(s)**
  sleep, not your calling process. This is often what you want for bulk work:
  kick off the stream and let the workers pace themselves.

```elixir
# Bulk import that respects the rate limit without blocking the caller:
ids
|> MyApp.Api.call_async_stream(fn id -> MyApp.Api.fetch(id) end)
|> Enum.to_list()
```

## Customizing the sleep

By default sleeping uses `Process.sleep/1`. In tests — where you don't want real
delays — you can override it with `:sleep_function`:

```elixir
use ExternalService,
  rate_limit: [limit: 100, per: :timer.seconds(1)],
  sleep_function: fn _ms -> :ok end
```

The function receives the number of milliseconds the library would otherwise
sleep. This is also where you'd hook in deterministic test control or custom
instrumentation.

## Observing throttling

Every time a call is throttled and put to sleep, an
`[:external_service, :rate_limit, :sleep]` telemetry event is emitted, with the
sleep duration in its measurements. Attach a handler to track how often (and how
long) you are being rate limited — a useful signal that you may need a higher
quota or fewer calls. See the [Telemetry](telemetry.md) guide.

## Rate limiting and the circuit breaker

Rate-limit sleeps are independent of the circuit breaker: being throttled is not
a failure and does not melt the breaker. A throttled call waits and then runs
normally, succeeding or failing on its own merits.
