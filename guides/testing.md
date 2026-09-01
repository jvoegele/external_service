# Testing

Once a guarded call is in your application, your tests have to get through it.
This guide covers the sharp edges: keeping tests off the clock, isolating them
from each other, and reaching the failure paths on purpose.

`ExternalService.Test` ships the setup and assertions this guide would otherwise
ask you to hand-write — `use ExternalService.Test` imports them, and each section
below uses them where they apply. The explanations stay, because the helpers
replace the typing, not the model.

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

## Asserting that your configuration works

The tests above check that a *call* behaves. `ExternalService.simulate/3` checks
that the *configuration* behaves — that the breaker opens, that it opens soon
enough, and that a dead dependency does not absorb more load than you meant it to:

```elixir
test "our payments breaker actually opens, and fast enough" do
  assert %ExternalService.Simulation{opens_after: opens, worst_call: worst, attempts: attempts} =
           ExternalService.simulate(MyApp.Payments, :always_failing)

  assert opens <= 5
  assert worst < 2_000
  assert attempts <= 25
end
```

It runs on a virtual clock, so a configuration that would take two minutes of real
failure to trip is simulated in microseconds. Nothing sleeps and no service is
started.

The scenario worth adding once you know your dependency is that a slow one is not
the same as a failing one:

```elixir
# Attempts that succeed but take five seconds each. The breaker never opens —
# nothing is failing — so :worst_call is the number that matters.
assert %ExternalService.Simulation{worst_call: worst} =
         ExternalService.simulate(MyApp.Payments, {:slow, 5_000})
```

Attempt duration is the one thing a configuration cannot state, and the thing that
makes a hand-sized `:within` too narrow. `{:always_failing, attempt_ms}` is how to
find out what your configuration does when attempts are slow *and* failing.

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
>    valid options are: [:circuit_breaker, :rate_limit, :concurrency, :retry, :sleep_function]
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

Where per-test services are impractical — which is most of the time with a
front-door module — reset the shared service instead. `ExternalService.reset_all/1`
clears all three stateful mechanisms, so nothing a test does to the breaker,
the rate limit budget, or the concurrency limit survives into the next one:

```elixir
setup do
  MyApp.Stripe.reset_all()
  :ok
end
```

Use `reset_all/1` rather than `reset/1` here. `reset/1` closes the breaker and
deliberately leaves the rate limiter and concurrency limit alone, because
clearing a limiter in production releases a burst at the service — so a test
that drained the budget would leave the next one throttled.

Resetting **shares** state rather than isolating it, so it does not make
concurrent tests independent: two `async: true` tests can still interleave a
reset with the other's assertions. Which leads to the tiering below.

### Which technique for which test

| Your test | Approach |
| --- | --- |
| Business logic that happens to call through | Make the service **inert** (below). No isolation needed — there is no state to share. |
| Resilience behavior: fallbacks, breaker opening, throttled paths | Real mechanisms + `reset_all/1` in `setup`, and `async: false`. |
| A service you drive with the functional API | A unique service term per test. Fully isolated, works with `async: true`. |

The middle row is the only one that gives up `async: true`, and it is normally
the smallest group — those tests are in-memory and fast, so serializing them
costs little.

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
assert elapsed < 500_000   # three attempts, and none of them waited
```

Note how loose that bound is. It is there to separate *the backoff was removed*
from *production backoff is still on* — an HTTP service's 1.5-second retry window
— and not to measure anything. A tight bound on elapsed time measures the machine
the suite is running on: this assertion used to be `50_000`, and failed on a busy
CI runner at 68ms with nothing wrong. If you want to assert on the delays
themselves, assert on the delays themselves, with `:sleep_function` below.

The generous `:tolerate` is deliberate: a test that exhausts retries melts the
breaker once, and a suite that does it repeatedly against a shared service will
open a breaker configured with production numbers. `ExternalService.reset_all/1`
between tests is the other half of the answer.

When you want to keep the *real* backoff configuration under test — because the
delays are the thing you care about — override `:sleep_function` instead. It is
called with each delay in turn, so the test can record them rather than wait for
them:

```elixir
test "backs off exponentially between attempts" do
  ExternalService.start(service,
    circuit_breaker: [tolerate: 100],
    retry: [max_attempts: 4, backoff: :exponential, base: 100],
    sleep_function: recording_sleep()
  )

  ExternalService.call(service, fn -> :retry end)

  assert_slept([100, 200, 400])
end
```

`ExternalService.Test.assert_slept/1` takes the whole sequence rather than one
delay at a time, because the sequence is what a backoff configuration determines
— a test that checks only the first delay passes against the wrong `:backoff`.

This is the one place a no-op sleep function is the right tool — the delays are a
finite sequence, so skipping them ends the retrying sooner rather than spinning.
It is *not* true of rate limiting, as the warning below explains.

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

> #### Do not reach for a no-op `:sleep_function` *here* {: .warning}
>
> `sleep_function: fn _ms -> :ok end` looks like the obvious way to make
> throttled calls instant. For rate limiting it isn't: the limiter is asked again
> immediately, still says wait, and the loop spins until real time has passed. The
> call takes exactly as long and burns a core doing it.
>
> Measured at `limit: 1, per: 2_000`, the throttled call still took **2000ms**
> and invoked the no-op **2,075,418 times**. The same applies to waiting for a
> concurrency slot, which is also waiting on something else to happen.
>
> Retry backoff is the exception, because the delays are a fixed sequence rather
> than a re-check loop — see [Retries](#retries) above.

## Reaching the failure paths on purpose

You rarely want to test your fallback code by making a real dependency fail. The
control API drives the breaker and the limiter directly.

### Opening the breaker

`ExternalService.Test.trip_breaker/1` opens it without a failing call:

```elixir
ExternalService.start(service,
  circuit_breaker: [tolerate: 2, within: :timer.seconds(10)],
  retry: [max_attempts: 1]
)

trip_breaker(service)

assert ExternalService.blown?(service)

assert {:error, %ExternalService.CircuitBreakerOpen{}} =
         ExternalService.call(service, fn -> flunk("should not run") end)
```

Underneath it is `ExternalService.CircuitBreaker.melt/1`, which reports a failure
the library never saw. The reason to use the helper rather than call `melt/1` in
a loop is an off-by-one: `:fuse` tolerates `:tolerate` melts and opens on the
*next*, so `tolerate: n` needs `n + 1` melts. `trip_breaker/1` reads `:tolerate`
off the service and does that arithmetic, so the number is not restated in your
test and cannot drift from the configuration.

`ExternalService.reset/1` closes it again, which is what makes the `setup` helper
above work:

```elixir
ExternalService.reset(service)
assert ExternalService.available?(service)
```

### Exhausting the rate limit

`ExternalService.Test.exhaust_rate_limit/1` puts a service right at its limit
before the code under test runs, reading `:limit` off the service the same way:

```elixir
ExternalService.start(service,
  retry: [max_attempts: 1],
  rate_limit: [limit: 2, per: :timer.minutes(1), wait: false]
)

exhaust_rate_limit(service)

assert {:error, %ExternalService.RateLimited{}} =
         ExternalService.call(service, fn -> flunk("should not run") end)
```

It is `ExternalService.RateLimiter.request/1` underneath, which spends one call's
worth of budget without running anything. Reach for that directly when you want a
service *partly* spent rather than fully.

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

"Did this actually retry?" is a common thing to want to check, and it is the one
question the return value cannot answer: a call that failed twice and then
succeeded returns exactly what a call that succeeded first time returns. The
telemetry events are the only difference, and
`ExternalService.Test.record_events/0` puts them where a test can see them:

```elixir
setup :record_events

test "retries a 503" do
  ExternalService.call(service, fn -> {:retry, :service_unavailable} end)

  assert_retried(service, reason: :service_unavailable)
end
```

`record_events/0` attaches handlers for this library's events, generating a
handler ID unique to the calling process and detaching it on exit. That last part
matters: handler IDs are global, so a shared one breaks under `async: true`.

The assertions return the metadata they matched, so you can go further:

```elixir
metadata = assert_retried(service)
assert metadata.reason == :service_unavailable
```

`refute_retried/2` is the negative case for the same retry event.
`assert_breaker_blown/2` and `assert_throttled/2` cover the two other events —
the breaker tripping and a call being throttled. `refute_retried/2` earns its
place rather than being reflexive symmetry — a retry that did *not* happen
leaves nothing in the return value to assert on instead. All the events are
listed in the [Telemetry](telemetry.md) guide.

## Making a service inert

Everything above makes a service *fast*. Sometimes you want it *absent*: the
guarded call should run your function and otherwise stay out of the way, because
what you're testing is the code around it.

Child-spec overrides are deep merged with the options given to
`use ExternalService`, so `test.exs` can neutralize a service without a second
module:

```elixir
children = [
  {MyApp.Stripe,
   circuit_breaker: [tolerate: :infinity],
   rate_limit: [limit: :infinity],
   retry: [max_attempts: 1]}
]
```

Each key turns off exactly one mechanism, and each is exact rather than merely
large:

| Key | Effect |
| --- | --- |
| `circuit_breaker: [tolerate: :infinity]` | Installs no breaker. Never opens, holds no state. |
| `rate_limit: [limit: :infinity]` | Installs no limiter. Calls pass straight through. |
| `retry: [max_attempts: 1]` | One attempt; a `:retry` return becomes `RetriesExhausted`. |

`:infinity` matters more than it looks. The breaker, the rate limiter, and the
concurrency limit are the three **stateful** mechanisms — the ones that
accumulate across tests — and until the breaker and the limiter had an off
switch you could only set them very large. Large is finite: a suite long enough
to accumulate `:tolerate` melts starts failing tests that have nothing to do
with the breaker, and the failure looks like flakiness. `:infinity` removes the
state rather than postponing it, which also means it no longer matters that a
front-door module can't vary its `:name` per test — inert mechanisms have
nothing to share.

The concurrency limit has no `:infinity` off switch — `:limit` is a required
positive integer — so omit `:concurrency` from a shared test service's
configuration if you don't need it exercised, or reach for
`ExternalService.reset_all/1` (see above) to clear whatever state it
accumulated.

Because the merge is deep, you override only the keys you name; `:within`,
`:reset`, and `:per` all fall back to the module-level configuration. See
[Per-environment overrides](the-front-door.md#per-environment-overrides).

Swap in `retry: [max_attempts: 3, base: 0]` when you *do* want the retry logic
exercised — `base: 0` keeps it instant. And note that `rate_limit: [wait: false]`
is a different thing from `limit: :infinity`: it makes throttled calls fail fast,
which is interference, just quick interference. Use it when you're testing the
throttled path, not when you want the limiter gone.

## What this library does not give you

There is no single `mode: :passthrough` switch — the three keys above are the
whole of it, deliberately, because each also means something on its own in
production. There is also no way to make a guarded call *transparent*: with
`max_attempts: 1`, a function returning `:retry` yields `RetriesExhausted` rather
than the raw `:retry`, because the sentinel belongs to the library.

The broader point: an inert service is not a tested one. Tests that run with the
mechanisms off are not exercising your `:retry` returns, your fallback paths, or
your error handling — so keep some that do, using the techniques above. If what
you want is for the external call not to happen at all, stub at your own
boundary, in the function you pass to `call/3`, rather than neutralizing the
service around it.

## Which paths your suite actually exercised

That last point is advice with nothing behind it: nothing tells you whether you
took it. A suite can make ten thousand guarded calls, every one on the happy
path, and look exactly like a suite that exercises every failure path this
library provides.

`ExternalService.Test.Coverage` answers it, from the telemetry the library
already emits:

```elixir
# test/test_helper.exs
ExUnit.start()
ExternalService.Test.Coverage.install_reporter()
```

```
external_service coverage

service             calls    retried     failed    breaker  throttled  saturated
MyApp.Geocoder         44         12          4          0          0          0
MyApp.Search          318          0          0          0          0          0  ⚠
MyApp.Stripe         1204        142         31          3          7          0

⚠ MyApp.Search was called 318 times and never once retried, failed, or was
  rejected. Its `:retry` returns, its fallback path and its error handling are
  not covered by this suite.
```

Every count is a number of *calls*, so they are all comparable with the first
column — a call that retried four times counts once.

A row of zeros is a **prompt, not a verdict**. A dependency you stub at your own
boundary is supposed to have zeros; that is the recommendation directly above.
What the report is for is the service you *believed* you were testing. It is
never a threshold and never a build failure.

The counts can also be read mid-suite, without the reporter, which makes "assert
this test exercised the breaker" a thing you can write directly — see
`ExternalService.Test.Coverage.entries/0`.
