# Flow Pipelines

`ExternalService.Flow` runs an enumerable — or an existing
[`Flow`](https://hexdocs.pm/flow) — through guarded `ExternalService` calls as a
stage of a Flow pipeline. Reach for it when a guarded call is **one step in a
larger computation**: partitioned, back-pressured processing with downstream
`map`/`filter`/`reduce` stages.

If all you want is an ordered, bounded-concurrency parallel map, use
`ExternalService.call_async_stream/5` instead — it's simpler and preserves input
order. Flow only earns its keep when you're building a pipeline.

## Adding the dependency

The integration lives behind the optional [`:flow`](https://hex.pm/packages/flow)
dependency. Add it to your application's deps:

```elixir
{:flow, "~> 1.2"}
```

`ExternalService.Flow` is compiled only when `:flow` is present. Without it, the
module simply doesn't exist and the rest of `ExternalService` is unaffected — it
never references Flow.

## What the helper actually does

`ExternalService.Flow.map/3,4,5` is deliberately thin: it reuses
`ExternalService.call/3` for every element, so retries, the circuit breaker, rate
limiting, telemetry, and the structured-error returns behave **exactly** as they
do for a direct call. It is not a new engine — it's a small adapter that smooths
the rough edges of wiring a guarded call into Flow by hand.

Written out by hand, a guarded Flow stage looks like this:

```elixir
enum
|> Flow.from_enumerable()
|> Flow.map(fn item ->
  ExternalService.call(MyApp.Stripe, retry_opts, fn -> work(item) end)
end)
```

With the helper:

```elixir
ExternalService.Flow.map(enum, MyApp.Stripe, retry_opts, fn item -> work(item) end)
```

Concretely, it buys you three small things:

1. **The arity bridge.** `call/3` expects a zero-arity function (`fn -> … end`),
   but a `Flow.map` mapper receives the element (`fn item -> … end`). The helper
   does the `fn item -> call(svc, fn -> fun.(item) end) end` nesting for you, so
   you don't fumble the inner closure.
2. **Enumerable *or* Flow in one entry point.** Pass a plain enumerable and it
   becomes a Flow source (via `Flow.from_enumerable/2`); pass an existing `Flow`
   and it's used as-is. The same call works whether the guard is the **source** of
   a pipeline or a **middle stage**:

   ```elixir
   ids
   |> Flow.from_enumerable()
   |> Flow.map(&build_request/1)
   |> ExternalService.Flow.map(MyApp.Stripe, &charge/1)   # middle stage
   |> Flow.filter(&match?({:ok, _}, &1))
   ```
3. **A documented home for the gotchas.** The non-obvious parts of mixing a
   guarded call with Flow (below) live in one place, so they're not folded
   incorrectly into hand-rolled code.

That's the whole value: convenience plus a canonical, supported integration
point. The parallelism, partitioning, and back-pressure are all Flow's — the
helper adds none of that, and you could inline `call/3` yourself to the same
effect.

## A worked example

Charge a batch of orders, keeping only the successes:

```elixir
orders
|> ExternalService.Flow.map(MyApp.Stripe, fn order ->
  case Stripe.charge(order) do
    {:error, %{status: s}} when s in 500..599 -> :retry   # transient: retry
    other -> other
  end
end)
|> Flow.filter(&match?({:ok, _}, &1))
|> Enum.to_list()
```

Each element is guarded: transient 5xx responses are retried with backoff, a
sustained run of failures melts the circuit breaker, and a configured rate limit
paces the whole pipeline.

## Things to know

These are the behaviors worth internalizing before you lean on a guarded Flow —
they're the reason a documented helper is preferable to scattered hand-rolled
stages.

### Errors are elements, not exceptions

The helper uses `call/3` (never `call!`, which would crash a stage), so a failed
element flows downstream as the `{:error, …}` tuple `call/3` returns:

```elixir
results = ExternalService.Flow.map(items, MyApp.Stripe, &work/1) |> Enum.to_list()

# results may contain, alongside your successful values:
#   {:error, %ExternalService.RetriesExhausted{...}}
#   {:error, %ExternalService.CircuitBreakerOpen{...}}
#   {:error, %ExternalService.ServiceNotStarted{...}}
```

`filter`, `partition`, or pattern-match on them downstream — they are ordinary
data in the stream, not crashes.

### Results are unordered

Flow partitions reorder elements, so the output order does not match the input
order. If you need results in input order, use
`ExternalService.call_async_stream/5` instead.

### Rate-limit pacing

The rate-limit bucket is global per service, so the configured limit is honored
across all of Flow's parallel stages. Throttling works by sleeping the stage
process, which naturally back-pressures the pipeline upstream. Because a sleeping
call stalls the rest of its demand batch, a smaller `:max_demand` gives smoother
pacing under a rate limit. See the [Rate limiting](rate-limiting.md) guide.

### Passing Flow options

The optional last argument is passed straight to `Flow.from_enumerable/2` (for
example `:stages`, `:min_demand`, `:max_demand`):

```elixir
ExternalService.Flow.map(enum, MyApp.Stripe, [], &work/1, stages: 4, max_demand: 10)
```

These apply only when the source is an enumerable. When you pass an existing
`Flow`, its stage configuration already governs and the options are ignored.

## Flow vs. `call_async_stream`

| | `ExternalService.Flow.map` | `call_async_stream/5` |
| --- | --- | --- |
| Returns | a `Flow` (keep composing) | a `Stream` of `{:ok, _} \| {:exit, _}` |
| Order | unordered | preserves input order |
| Best for | a stage in a multi-stage pipeline | a standalone parallel map |
| Dependency | optional `:flow` | none (built in) |

Both run each element through the same guarded `call`, so the protection is
identical; they differ only in orchestration and shape.
