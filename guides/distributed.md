# Distributed Elixir

`ExternalService` works out of the box on a single node. Run the same
application on several nodes and two of its three pieces of state need a second
look, because each node keeps its own copy.

This guide covers what actually changes in a cluster, which part is a genuine
correctness problem and which is a design choice, and what to configure for each.

## What is node-local, and how much it matters

| State | Where it lives | In a cluster |
| ----- | -------------- | ------------ |
| Rate limit counters | This node's memory | **A correctness problem.** N nodes each admit `:limit` calls per window, so the service sees up to N × your limit. |
| Circuit breaker | This node's memory | **A design choice.** Each node learns independently that the service is failing. |
| Service configuration | `:persistent_term` | **Not a problem.** Every node runs `start/2` itself. |

The asymmetry is the important part, and the two get different solutions.

## Rate limiting: share the counters

This one is not a matter of taste. If you configure `limit: 100, per: 1_000`
because your provider allows 100 requests per second, and you run four nodes,
your provider sees up to 400 — you are violating the quota you carefully
configured.

Point the service at a shared limiter with `:backend`.
`ExternalService.RateLimiter.Hammer` meters against a
[Hammer](https://hexdocs.pm/hammer) module, so a shared Hammer backend such as
[`hammer_backend_redis`](https://hexdocs.pm/hammer_backend_redis) gives every
node the same counters:

```elixir
defmodule MyApp.RateLimit do
  use Hammer, backend: Hammer.Redis
end

# in your supervision tree, before the services that use it
children = [
  {MyApp.RateLimit, url: "redis://localhost:6379"},
  MyApp.Api
]
```

```elixir
defmodule MyApp.Api do
  use ExternalService,
    rate_limit: [
      limit: 100,
      per: :timer.seconds(1),
      backend: {ExternalService.RateLimiter.Hammer, module: MyApp.RateLimit}
    ]
end
```

Now the limit is enforced across the cluster, whatever the node count.

Hammer is not a dependency of this library — the backend calls `hit/3` on the
module you supply, so you add only Hammer itself. Any other shared store works
too; see `ExternalService.RateLimiter` for the two callbacks a backend
implements.

> #### The quick and dirty alternative {: .tip}
>
> If you cannot add shared infrastructure, dividing the limit by your node count
> (`limit: div(100, 4)`) keeps you under quota. It is wasteful when load is
> uneven, and wrong whenever the cluster size changes, but it is honest about
> the constraint and needs nothing new deployed.

## Circuit breakers: local by default, and often correctly so

Unlike rate limiting, a node-local circuit breaker is a defensible design rather
than a bug — arguably the better one:

- A node with a bad network path to the service should stop calling it **without
  taking the rest of the cluster down with it**. That is the bulkhead argument,
  and it is why the default breaker is local.
- Recovery probing is naturally spread out: nodes reset on their own schedules,
  so the service is not hit by every node at once the moment the breaker closes.

What you give up is speed of convergence. Each node has to learn about the
outage separately, so a cluster of N nodes sends roughly N times the failing
traffic before all of them have tripped, and for a while some nodes serve
degraded responses while others still try.

### Trip the whole cluster together

If you would rather the cluster converge quickly, use
`ExternalService.CircuitBreaker.Cluster`:

```elixir
use ExternalService,
  circuit_breaker: [
    tolerate: 5,
    within: :timer.seconds(1),
    reset: :timer.seconds(5),
    backend: ExternalService.CircuitBreaker.Cluster
  ]
```

Each node still keeps its own ordinary breaker. When one **transitions** from
closed to open, it sends a fire-and-forget `:erpc.multicast/4` to the other
nodes, and each of those trips its own breaker — which means its own reset timer
then closes it on the normal schedule.

There is no shared store, no distributed state, and no process or supervision
tree that this library has to run for it. Only locally originated trips are
broadcast, so a trip costs one round of messages rather than one per node per
node, and a message lost to a netsplit just means that node keeps its own
counsel until it trips by itself — which is exactly the default behavior.

By default every connected node is notified. When only part of your cluster
calls the service, narrow it:

```elixir
circuit_breaker: [
  backend: {ExternalService.CircuitBreaker.Cluster, nodes: &MyApp.api_nodes/0}
]
```

`:nodes` takes a list or a zero-arity function returning one.

### What that costs you

Read these before turning it on — this backend trades isolation for convergence,
and the trade is not always right:

- **One node can trip the whole cluster.** A single node with a bad route will
  take everyone's breakers with it, even though the service is healthy for the
  rest. If that worries you more than slow convergence does, stay on the default.
- **Propagation is best-effort.** Nothing is retried or acknowledged. A dropped
  message costs convergence speed, not correctness.
- **Recovery is not coordinated.** Nodes trip at about the same moment and so
  reset at about the same moment, but they do not agree on it, and whichever
  closes first probes the service alone.
- **A node that joins later does not catch up.** It learns the service is
  unhealthy the first time one of its own calls fails.

An explicit `ExternalService.reset/1` is broadcast, since that is a deliberate
administrative action. Automatic resets are not — each node's timer handles its
own.

## Configuration is not shared, and does not need to be

Service configuration lives in `:persistent_term` on each node, written by
`start/2`. Every node runs its own application start, so every node installs its
own configuration; there is nothing to distribute. Just make sure the nodes agree
— deploying one node with `tolerate: 5` and another with `tolerate: 50` gives you
a cluster whose breakers behave differently, which is confusing rather than
broken.

## Putting it together

A service configured for a cluster, sharing its rate limit and its breaker:

```elixir
defmodule MyApp.Api do
  use ExternalService,
    circuit_breaker: [
      tolerate: 5,
      within: :timer.seconds(1),
      reset: :timer.seconds(5),
      backend: ExternalService.CircuitBreaker.Cluster
    ],
    rate_limit: [
      limit: 100,
      per: :timer.seconds(1),
      wait: :timer.seconds(2),
      backend: {ExternalService.RateLimiter.Hammer, module: MyApp.RateLimit}
    ],
    retry: [max_attempts: 5, backoff: :exponential, jitter: true]
end
```

The `:wait` budget is worth adding once the limiter is shared: with every node
drawing from the same bucket, a throttled call can wait considerably longer than
it would on a single node. See [Rate limiting](rate-limiting.md).
