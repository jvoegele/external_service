# About ExternalService

`ExternalService` is an Elixir library for safely calling external services and
APIs, combining three well-established reliability techniques behind one small
interface:

  * **Retries** for transient failures,
  * the **Circuit Breaker** pattern for persistent failures, and
  * **rate limiting** for staying within a service's quota.

Calls can be synchronous, asynchronous background tasks, or fanned out in
parallel for MapReduce-style processing — all under the same retry, circuit
breaker, and rate-limiting protection.

## The ideas

### Retrying failed requests

Many failures when accessing an external service are transient: network
congestion causing a timeout, or a service briefly under heavy load. The best
response is often simply to try again after a short backoff. `ExternalService`
automates retry logic — linear or exponential backoff, jitter, delay caps, and
both attempt-count and time budgets — using
[Safwan Kamarrudin's retry library](https://hex.pm/packages/retry). See
[Retries](retries.md).

### Circuit breakers

The Circuit Breaker pattern was first described in Michael Nygard's *Release It!*
and later popularized by Martin Fowler. To quote Nygard, "Circuit breakers are a
way to automatically degrade functionality when the system is under stress."

Like the electrical breakers they're named for, software circuit breakers protect
a system from damage caused by a faulty component. By monitoring calls to an
external service, a breaker can "trip" once failures cross a threshold, after
which further calls fail fast instead of piling up against a service that is
already in trouble. After a cool-down it resets and calls resume. Crucially, the
breaker is global to the service, so a trip protects every caller at once and
prevents cascading failures.

`ExternalService` implements circuit breakers on top of
[Jesper Louis Andersen's Erlang fuse library](https://github.com/jlouis/fuse),
managing the underlying fuse for you — you never call `:fuse.ask` or
`:fuse.melt` yourself. See [Circuit breakers](circuit-breakers.md).

### Rate limiting

Many services impose a request quota. `ExternalService` can keep you under it
automatically and application-wide, using
[ex_rated](https://hex.pm/packages/ex_rated): excess calls sleep until the window
allows them, rather than failing. See [Rate limiting](rate-limiting.md).

## History

`ExternalService` grew out of production code at Ropig, where it was first used
to make reliable calls to Google's Pub/Sub messaging service. It was one of
author Jason Voegele's first open-source Elixir libraries and went on to see wide
production adoption. The original overview is described in
[this blog post](https://ropig.com/blog/use-external-services-safely-reliably-elixir-applications/).

The 2.0 line is a ground-up modernization of that original library — validated
and self-documenting options, telemetry, circuit-breaker introspection,
structured errors, and a declarative module front door (`use ExternalService`) —
while keeping the core idea unchanged: wrap a call in a function, hand it over,
and let retries, the circuit breaker, and rate limiting just work.

## License

`ExternalService` is released under the Apache 2.0 license.
