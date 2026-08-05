# Testing

Once a guarded call is in your application, your tests have to get through it.
This guide covers the sharp edges: keeping tests off the clock, isolating them
from each other, and reaching the failure paths on purpose.

Every example here is executed as part of this library's own suite
(`test/testing_guide_examples_test.exs`), so they compile and their assertions
hold.

## The one thing to know first: service state is global

A service is not a process you start per test. Its configuration lives in
`:persistent_term` keyed on the service term, and its circuit breaker lives in
`:fuse` under the same key. Two consequences follow, and both bite quietly:

- **Nothing is torn down for you.** A test that trips the breaker leaves it
  tripped for every test that runs afterwards.
- **`async: true` tests sharing a service share one breaker and one rate-limit
  bucket**, so they can trip each other, and the failure looks like flakiness.

Everything below follows from this.

## Isolating tests from each other

The cleanest fix is to give each test its own service term. Service terms are
arbitrary — any term identifying the service — so derive one from the test name
and tear it down afterwards:

```elixir
setup context do
  service = :"#{context.module}.#{context.test}"
  on_exit(fn -> ExternalService.stop(service) end)
  {:ok, service: service}
end
```

`ExternalService.stop/1` is idempotent, so this is safe whether or not the test
got as far as starting the service.

Distinct terms are genuinely independent — melting one leaves the other
untouched:

```elixir
Enum.each(1..2, fn _ -> ExternalService.CircuitBreaker.melt(one) end)

assert ExternalService.blown?(one)
refute ExternalService.blown?(two)
```

> #### `use ExternalService` fixes the service name at compile time {: .warning}
>
> The module front door takes its `:name` when the module is compiled. The
> child-spec overrides that tune everything else cannot change it — `:name` is
> consumed by the `use` macro and is not a `start/2` option, so passing it as an
> override fails validation rather than being quietly ignored:
>
> ```
> ** (NimbleOptions.ValidationError) unknown options [:name],
>    valid options are: [:circuit_breaker, :rate_limit, :retry, :sleep_function]
> ```
>
> So every test exercising `MyApp.Stripe` shares one breaker and one bucket, no
> matter how you configure it.
>
> If you need per-test isolation for a front-door module, either drive the
> functional API (`ExternalService.start/2` with a unique term) in the tests that
> need it, or mark those tests `async: false`. Reaching for `ExternalService.reset/1`
> in `setup` works too, but only for the breaker, and only if nothing else is
> running concurrently.

Where per-test services are impractical, resetting in `setup` gets you most of
the way:

```elixir
setup do
  ExternalService.reset(MyApp.Stripe)
  :ok
end
```

## Keeping tests off the clock

### Retries

Retry delays are the usual culprit. `base: 0` with a linear backoff removes them
entirely:

```elixir
ExternalService.start(service,
  circuit_breaker: [tolerate: 100, within: :timer.seconds(10)],
  retry: [max_attempts: 3, backoff: :linear, base: 0]
)

{elapsed, result} = :timer.tc(fn -> ExternalService.call(service, fn -> :retry end) end)

assert {:error, %ExternalService.RetriesExhausted{}} = result
assert elapsed < 50_000    # three attempts, no waiting between them
```

The generous `:tolerate` is deliberate: every failing attempt melts the breaker,
so a test that exhausts retries can open a breaker configured with production
numbers. See [`:tolerate` counts attempts, not calls](circuit-breakers.md#what-counts-as-a-failure).

### Rate limits

Use `wait: false`. A throttled call then fails immediately instead of waiting,
which is both fast and assertable:

```elixir
ExternalService.start(service,
  retry: [max_attempts: 1],
  rate_limit: [limit: 1, per: :timer.minutes(1), wait: false]
)

assert ExternalService.call(service, fn -> :first end) == :first

assert {:error, %ExternalService.RateLimited{}} =
         ExternalService.call(service, fn -> flunk("should not run") end)
```

The alternative is to configure a limit your tests never reach, so the limiter
never comes into play at all.

> #### Do not reach for a no-op `:sleep_function` {: .warning}
>
> `sleep_function: fn _ms -> :ok end` looks like the obvious way to make
> throttled calls instant. It isn't: the limiter is asked again immediately,
> still says wait, and the loop spins until real time has passed. The call takes
> exactly as long and burns a core doing it.
>
> Measured at `limit: 1, per: 2_000`, the throttled call still took **2000ms**
> and invoked the no-op **2,075,418 times**. `:sleep_function` is an
> instrumentation hook — see
> [Customizing the sleep](rate-limiting.md#customizing-the-sleep).

## Reaching the failure paths on purpose

You rarely want to test your fallback code by making a real dependency fail. The
control API drives the breaker and the limiter directly.

### Opening the breaker

`melt/1` reports a failure the library never saw. `:fuse` tolerates `:tolerate`
melts and opens on the next, so `tolerate: n` needs `n + 1` melts:

```elixir
ExternalService.start(service,
  circuit_breaker: [tolerate: 2, within: :timer.seconds(10)],
  retry: [max_attempts: 1]
)

Enum.each(1..3, fn _ -> ExternalService.CircuitBreaker.melt(service) end)

assert ExternalService.blown?(service)

assert {:error, %ExternalService.CircuitBreakerOpen{}} =
         ExternalService.call(service, fn -> flunk("should not run") end)
```

`ExternalService.reset/1` closes it again, which is what makes the `setup` helper
above work:

```elixir
ExternalService.reset(service)
assert ExternalService.available?(service)
```

### Exhausting the rate limit

`ExternalService.RateLimiter.request/1` spends one call's worth of budget without
running anything, so you can put a service right at its limit before the code
under test runs:

```elixir
ExternalService.start(service,
  retry: [max_attempts: 1],
  rate_limit: [limit: 2, per: :timer.minutes(1), wait: false]
)

assert ExternalService.RateLimiter.request(service) == :ok
assert ExternalService.RateLimiter.request(service) == :ok

assert {:error, %ExternalService.RateLimited{}} =
         ExternalService.call(service, fn -> flunk("should not run") end)
```

### Degrading a service without touching your code

`:fault_injection` fails a fraction of calls at the breaker, which is useful for
exercising fallback paths under something closer to real conditions. A rate of
`1.0` fails every call:

```elixir
ExternalService.start(service,
  circuit_breaker: [tolerate: 100, within: :timer.seconds(10), fault_injection: 1.0],
  retry: [max_attempts: 1]
)

assert {:error, %ExternalService.CircuitBreakerOpen{}} =
         ExternalService.call(service, fn -> flunk("should not run") end)
```

Rates between `0.0` and `1.0` are random, so assert on aggregate behavior rather
than on any individual call.

## Asserting that a retry happened

"Did this actually retry?" is a common thing to want to check, and the telemetry
events answer it. Attach a handler that sends to the test process:

```elixir
test_process = self()

:telemetry.attach(
  "retry-handler",
  [:external_service, :call, :retry],
  fn _event, measurements, metadata, _config ->
    send(test_process, {:retried, measurements, metadata})
  end,
  nil
)

on_exit(fn -> :telemetry.detach("retry-handler") end)

ExternalService.call(service, fn -> {:retry, :service_unavailable} end)

assert_received {:retried, _measurements, %{service: ^service, reason: :service_unavailable}}
```

Use a handler ID unique to the test — handler IDs are global, so a shared one
breaks under `async: true`. The other events are listed in the
[Telemetry](telemetry.md) guide; `[:external_service, :circuit_breaker, :blown]`
and `[:external_service, :rate_limit, :sleep]` are the other two worth asserting
on.

## Per-environment configuration

Child-spec overrides are deep merged with the options given to
`use ExternalService`, which is the idiomatic way to make a service fast in
`test.exs` without a second module:

```elixir
children = [
  {MyApp.Stripe,
   circuit_breaker: [tolerate: 1],
   retry: [max_attempts: 1],
   rate_limit: [wait: false]}
]
```

Because the merge is deep, you override only the keys you name; `:within`,
`:reset`, `:limit`, and `:per` all fall back to the module-level configuration.
See [Per-environment overrides](the-front-door.md#per-environment-overrides).

## What this library does not give you

There is no first-class test mode — no documented way to make a service a
pass-through no-op. The closest thing is `retry: [max_attempts: 1]` with a
generous `:tolerate` and `rate_limit: [wait: false]`, which is a workaround
rather than an answer. If you want a guarded call to be transparent in tests,
stub at your own boundary — the function you pass to `call/3` — rather than
trying to neutralize the service.
