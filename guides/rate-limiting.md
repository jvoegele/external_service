# Rate Limiting

Many external services impose a quota: _no more than N requests per time
window._ Exceed it and you get throttled (or billed, or blocked).
`ExternalService` can keep you under that quota automatically, across your entire
application.

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

| Option     | Required | Meaning                                                                  |
| ---------- | -------- | ------------------------------------------------------------------------ |
| `:limit`   | yes      | Maximum number of calls allowed within each `:per` window.               |
| `:per`     | yes      | Length of the rate-limiting window, in milliseconds.                     |
| `:wait`    | no       | How long a throttled call may wait. Defaults to `:infinity`.             |
| `:backend` | no       | The limiter implementation. Defaults to `ExternalService.RateLimiter.Local`. |

`:limit` and `:per` are both required when `:rate_limit` is present.

## How it works

The limit is tracked per service and shared across every caller in your
application — every process that calls the service draws from the same bucket. So
the example above guarantees no more than 100 calls per second _in total_, no
matter how many processes are making them.

The default limiter is a **token bucket**: it allows a burst of up to `:limit`
calls, then paces the rest at one call per `:per / :limit`. Waiting out a full
window does not hand you a fresh burst all at once — the bucket refills one call
at a time. This is deliberately smoother than a fixed window, which allows a full
burst at the end of one window and another at the start of the next, briefly
sending twice your configured limit at the service.

When a call would exceed the limit, `ExternalService` does not fail it. Instead
it **sleeps** until there is room, then proceeds. From your code's point of view
the call simply takes a little longer; it still succeeds.

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

## Bounding the wait

By default a throttled call waits as long as the limiter requires — there is no
upper bound. If callers produce work faster than the limit allows, the backlog
grows and individual calls can block for a long time. Rate limiting paces calls;
by itself it does not shed load.

On latency- or demand-sensitive paths, give the wait a budget with `:wait`:

```elixir
use ExternalService,
  rate_limit: [
    limit: 100,
    per: :timer.seconds(1),
    wait: :timer.seconds(2)    # give up rather than block longer than this
  ]
```

| `:wait` value  | Behavior                                                          |
| -------------- | ----------------------------------------------------------------- |
| `:infinity`    | Wait as long as it takes. **The default.**                        |
| milliseconds   | A budget for the whole call, not for any single sleep.            |
| `false`        | Never wait — fail immediately if the call cannot be made now.     |

When the budget runs out the wrapped function is **not called** and you get an
`ExternalService.RateLimited` error:

```elixir
case MyApp.Api.fetch(id) do
  {:error, %ExternalService.RateLimited{context: %{retry_after: ms}}} ->
    # Shed this request; `ms` is how long until it would have been admitted.
    {:error, :busy}

  result ->
    result
end
```

`RateLimited` reports `http_status/1` of `429`, so it maps straight onto a "Too
Many Requests" response. It does **not** melt the circuit breaker and is **not**
retried — the function never ran, and retrying immediately would only be
throttled again. See the [Error Handling](error-handling.md) guide.

The alternative to a budget is to absorb the wait elsewhere: run the work through
`call_async_stream/2` so a pool of tasks does the sleeping, or apply your own
back-pressure upstream.

## Asking before you commit

Sometimes you want to know whether a call would be throttled *before* doing the
work that leads up to it. `rate_limited?/1` answers that, and consumes nothing —
it is a read, so it is safe to ask as often as you like:

```elixir
if ExternalService.rate_limited?(:payments) do
  {:error, :busy}
else
  charge(build_expensive_request(order))
end
```

When you want to know *how long* the wait would be rather than merely whether
there is one, `ExternalService.RateLimiter.peek/1` reports it:

```elixir
case ExternalService.RateLimiter.peek(:payments) do
  :ok -> start_work()
  {:wait, ms} -> {:error, {:busy, retry_after: ms}}
end
```

Both are best-effort, in the same way `available?/1` is: another process can
spend the budget between your check and your call. They let you bail out early;
they do not replace handling the call's own result.

## Counting calls made elsewhere

If some of your traffic reaches the service by a path that does not go through
`call/3` — a batch endpoint, a streaming client, a library you do not control —
it still counts against the provider's quota even though this library never saw
it. `request/1` spends budget without running anything:

```elixir
# This batch endpoint costs three calls against the quota.
Enum.each(1..3, fn _ -> ExternalService.RateLimiter.request(:payments) end)
```

It blocks according to the service's `:wait` setting, exactly as a guarded call
would, and returns `{:error, %ExternalService.RateLimited{}}` if that budget runs
out.

## Pacing inside a Flow pipeline

`ExternalService.Flow` (the optional `:flow` integration) paces the same way: a
throttled call sleeps inside its stage process, which back-pressures the pipeline
upstream. The rate-limit bucket is global per service, so the configured limit is
honored across all of Flow's parallel stages. Because a sleeping call stalls the
rest of its demand batch, a smaller `:max_demand` gives smoother pacing under a
rate limit. See `ExternalService.Flow` for details.

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

## Rate limiting across a cluster

The default limiter is **node-local**: its counters live in that node's memory.
Run the same service on four nodes with `limit: 100` and the external service can
see up to 400 calls per window, because each node meters only its own traffic.

To enforce one limit across a whole cluster, point the service at a shared
limiter with `:backend`. `ExternalService.RateLimiter.Hammer` meters against a
[Hammer](https://hexdocs.pm/hammer) module, which with a shared backend such as
[`hammer_backend_redis`](https://hexdocs.pm/hammer_backend_redis) gives every
node the same counters:

```elixir
defmodule MyApp.RateLimit do
  use Hammer, backend: Hammer.Redis
end

# in your supervision tree
children = [{MyApp.RateLimit, url: "redis://localhost:6379"}]
```

```elixir
use ExternalService,
  rate_limit: [
    limit: 100,
    per: :timer.seconds(1),
    backend: {ExternalService.RateLimiter.Hammer, module: MyApp.RateLimit}
  ]
```

Hammer is not a dependency of this library — the backend calls `hit/3` on the
module you supply, so you only add Hammer itself.

Writing your own backend is a matter of implementing two callbacks, `init/2` and
`check/2`, where `check/2` answers `:ok` or `{:wait, milliseconds}`. See
`ExternalService.RateLimiter`, and the [Distributed Elixir](distributed.md) guide
for the wider picture of running on more than one node.

## Rate limiting and the circuit breaker

Rate-limit sleeps are independent of the circuit breaker: being throttled is not
a failure and does not melt the breaker. A throttled call waits and then runs
normally, succeeding or failing on its own merits.
