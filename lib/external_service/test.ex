defmodule ExternalService.Test do
  @moduledoc """
  ExUnit helpers for the setup and assertions the [Testing](testing.md) guide
  otherwise asks you to hand-write.

  Each one replaces a passage of that guide where the work is repeated verbatim,
  is arithmetic the library can do from your own configuration, or is easy to get
  wrong in a way that fails silently:

  | Helper | Replaces |
  | --- | --- |
  | `trip_breaker/1` | melting `:tolerate` + 1 times, with the off-by-one written out |
  | `exhaust_rate_limit/1` | spending `:limit` calls' worth of budget by hand |
  | `record_events/0` and the assertions | twelve lines of `:telemetry.attach` per test |
  | `recording_sleep/1` and `assert_slept/1` | a hand-rolled `:sleep_function` shim |

  The guide still explains *why* each of these is the technique to use. These
  replace the typing, not the model.

  ## Usage

      defmodule MyApp.StripeTest do
        use ExUnit.Case, async: true
        use ExternalService.Test

        setup :record_events

        setup do
          ExternalService.start(MyApp.Stripe,
            circuit_breaker: [tolerate: 2, within: :timer.seconds(10)],
            retry: [max_attempts: 3, base: 0]
          )

          on_exit(fn -> ExternalService.stop(MyApp.Stripe) end)
        end

        test "retries a 503, then gives up" do
          result = ExternalService.call(MyApp.Stripe, fn -> {:retry, :service_unavailable} end)

          assert {:error, %ExternalService.RetriesExhausted{}} = result
          assert_retried(MyApp.Stripe, reason: :service_unavailable)
        end

        test "fails fast once the breaker is open" do
          trip_breaker(MyApp.Stripe)

          assert {:error, %ExternalService.CircuitBreakerOpen{}} =
                   ExternalService.call(MyApp.Stripe, fn -> flunk("should not run") end)

          assert_breaker_blown(MyApp.Stripe)
        end
      end

  `use ExternalService.Test` is exactly `import ExternalService.Test`.

  ## Matching rules

  The assertions take an optional keyword of expectations checked against the
  event's telemetry metadata. An expectation is met when the metadata field is
  equal to it, or — for a `Regex` — when the field's string form matches. A field
  named in the expectations but absent from the metadata never matches.

  Each assertion returns the metadata map it matched, so further assertions can
  be made on it:

      metadata = assert_retried(MyApp.Stripe)
      assert metadata.reason == :service_unavailable

  ## Service state is global

  These helpers do not change that, and none of them isolates one test from
  another. `trip_breaker/1` and `exhaust_rate_limit/1` in particular leave the
  service tripped and spent for whatever runs next against the same service term
  — see [Isolating tests from each other](testing.md#isolating-tests-from-each-other).
  """

  alias ExternalService.CircuitBreaker
  alias ExternalService.RateLimiter
  alias ExternalService.State

  @events [
    [:external_service, :call, :retry],
    [:external_service, :circuit_breaker, :blown],
    [:external_service, :rate_limit, :sleep],
    [:external_service, :concurrency, :rejected]
  ]

  @doc """
  Convenience: `use ExternalService.Test` is equivalent to `import ExternalService.Test`.
  """
  defmacro __using__(_opts) do
    quote do
      import ExternalService.Test
    end
  end

  @doc """
  Opens the circuit breaker for `service`, without needing a failing call.

  `:fuse` tolerates `:tolerate` melts and opens on the next, so this melts
  `:tolerate` + 1 times — reading the number off the service rather than asking
  the test to restate it. Melting is direct, so `melt: :per_attempt` makes no
  difference to the count.

  Returns the service, so it composes in a `setup`.

      setup context do
        ExternalService.start(context.service, circuit_breaker: [tolerate: 2])
        trip_breaker(context.service)
        :ok
      end

  Raises if the service was never started, or if it was started with
  `tolerate: :infinity`, which installs no breaker at all and therefore has
  nothing to open.
  """
  @spec trip_breaker(ExternalService.service()) :: ExternalService.service()
  def trip_breaker(service) do
    case tolerate(service) do
      :infinity ->
        raise ArgumentError,
              "#{inspect(service)} is configured with `tolerate: :infinity`, which installs " <>
                "no circuit breaker, so there is nothing to open. Configure a finite " <>
                "`:tolerate` for tests that need the breaker to trip."

      tolerate ->
        Enum.each(1..(tolerate + 1)//1, fn _ -> CircuitBreaker.melt(service) end)
        service
    end
  end

  @doc """
  Spends the whole rate-limit budget for `service`, without running anything.

  Reads `:limit` off the service and requests that many times, so the next call
  is throttled. Returns the service.

      exhaust_rate_limit(service)

      assert {:error, %ExternalService.RateLimited{}} =
               ExternalService.call(service, fn -> flunk("should not run") end)

  Pair it with `wait: false`, or the throttled call waits for the window rather
  than failing — see
  [Rate limits](testing.md#rate-limits).

  Raises if the service was never started, or was started with no rate limit.
  """
  @spec exhaust_rate_limit(ExternalService.service()) :: ExternalService.service()
  def exhaust_rate_limit(service) do
    case limit(service) do
      nil ->
        raise ArgumentError,
              "#{inspect(service)} was started without a `:rate_limit`, so there is no " <>
                "budget to exhaust."

      limit ->
        Enum.each(1..limit//1, fn _ -> RateLimiter.request(service) end)
        service
    end
  end

  @doc """
  Records this library's telemetry events to the calling process for the rest of
  the test.

  Intended for a `setup` block, though it works anywhere before the code under
  test runs:

      setup :record_events

  Handler IDs are global, so this generates one unique to the calling process and
  detaches it with `ExUnit.Callbacks.on_exit/2` — which is what makes the
  assertions safe under `async: true`.

  Returns `:ok`, so it satisfies `setup`'s contract directly.
  """
  @spec record_events() :: :ok
  def record_events, do: do_record_events()

  @doc """
  Same as `record_events/0`, ignoring the ExUnit context.

  This is the arity `setup :record_events` calls; `record_events/0` is the one to
  call from a test body or from a `setup do` block.
  """
  @spec record_events(term()) :: :ok
  def record_events(_context), do: do_record_events()

  defp do_record_events do
    test_process = self()
    id = {__MODULE__, test_process, System.unique_integer([:positive])}

    # A module-function capture rather than a closure: `:telemetry` logs a
    # performance warning for every anonymous handler, and a helper that logs
    # four lines per test is not one anybody wants in their suite.
    :telemetry.attach_many(id, @events, &__MODULE__.__forward__/4, test_process)

    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(id) end)

    :ok
  end

  @doc false
  # Public because `:telemetry` invokes it by module and function. Not API.
  def __forward__(event, measurements, metadata, test_process) do
    send(test_process, {__MODULE__, event, measurements, metadata})
    :ok
  end

  @doc """
  Asserts that `service` retried at least once.

  A retry is invisible in a call's return value — a call that failed twice and
  then succeeded returns exactly what a call that succeeded first time returns —
  so this is the only way to see one.

      assert_retried(service)
      assert_retried(service, reason: :service_unavailable)

  Requires `record_events/0`. Returns the metadata of the matching event.
  """
  @spec assert_retried(ExternalService.service(), keyword()) :: map()
  def assert_retried(service, expectations \\ []) do
    assert_event([:external_service, :call, :retry], service, expectations, "retry")
  end

  @doc """
  Asserts that `service` did *not* retry.

  Unlike most refutations this is not reflexive symmetry: a retry that did not
  happen leaves nothing in the return value to assert on instead.

      refute_retried(service)

  Requires `record_events/0`.
  """
  @spec refute_retried(ExternalService.service(), keyword()) :: :ok
  def refute_retried(service, expectations \\ []) do
    refute_event([:external_service, :call, :retry], service, expectations, "retry")
  end

  @doc """
  Asserts that a call to `service` was rejected by an open circuit breaker.

      assert_breaker_blown(service)

  Requires `record_events/0`. Returns the metadata of the matching event.

  Note that this asserts a call was *rejected*, which is not the same as the
  breaker being open: use `ExternalService.blown?/1` for the state itself.
  """
  @spec assert_breaker_blown(ExternalService.service(), keyword()) :: map()
  def assert_breaker_blown(service, expectations \\ []) do
    assert_event(
      [:external_service, :circuit_breaker, :blown],
      service,
      expectations,
      "circuit breaker rejection"
    )
  end

  @doc """
  Asserts that a call to `service` was throttled and put to sleep.

      assert_throttled(service)

  Requires `record_events/0`. Returns the metadata of the matching event.

  Only fires when the call actually waits, so a service configured with
  `wait: false` throttles by returning `ExternalService.RateLimited` and this
  never matches. Assert on that error instead.
  """
  @spec assert_throttled(ExternalService.service(), keyword()) :: map()
  def assert_throttled(service, expectations \\ []) do
    assert_event(
      [:external_service, :rate_limit, :sleep],
      service,
      expectations,
      "rate limit sleep"
    )
  end

  @doc """
  Builds a `:sleep_function` that records each delay to `pid` instead of waiting.

      ExternalService.start(service,
        retry: [max_attempts: 4, backoff: :exponential, base: 100],
        sleep_function: recording_sleep()
      )

      ExternalService.call(service, fn -> :retry end)

      assert_slept([100, 200, 400])

  This keeps the real backoff configuration under test while taking the waiting
  off the clock, which a `base: 0` override cannot do.

  > #### Retry backoff only {: .warning}
  >
  > A `:sleep_function` that does not sleep is right for retry backoff, whose
  > delays are a fixed sequence, and wrong for rate limiting and concurrency,
  > which re-check a condition in a loop. There, not sleeping does not skip the
  > wait — the limiter is asked again immediately, still says wait, and the loop
  > spins until real time has passed. Measured at `limit: 1, per: 2_000`, the
  > throttled call still took 2000ms and invoked the function 2,075,418 times.
  >
  > Use `wait: false` for those. See
  > [Keeping tests off the clock](testing.md#keeping-tests-off-the-clock).
  """
  @spec recording_sleep(pid()) :: (non_neg_integer() -> :ok)
  def recording_sleep(pid \\ self()) when is_pid(pid) do
    fn delay ->
      send(pid, {__MODULE__, :slept, delay})
      :ok
    end
  end

  @doc """
  Asserts that the delays recorded by `recording_sleep/1` were exactly `delays`,
  in order.

      assert_slept([100, 200, 400])

  Asserts on the whole sequence rather than on each delay separately, because the
  sequence is the thing a backoff configuration determines — a test that checks
  only the first delay passes against the wrong `:backoff`. Pass `[]` to assert
  that nothing slept at all.

  Returns the delays.
  """
  @spec assert_slept([non_neg_integer()]) :: [non_neg_integer()]
  def assert_slept(delays) when is_list(delays) do
    actual = collect_slept([])

    if actual == delays do
      delays
    else
      ExUnit.Assertions.flunk("""
      expected the recorded sleep delays to be
      #{inspect(delays)}
      got:
      #{inspect(actual)}#{recording_sleep_hint(actual)}
      """)
    end
  end

  # -- internals ---------------------------------------------------------------

  defp assert_event(event, service, expectations, description) do
    case take_event(event, service, expectations, []) do
      {:ok, metadata} ->
        metadata

      {:error, seen} ->
        ExUnit.Assertions.flunk("""
        expected a #{description} for #{inspect(service)}#{expectation_phrase(expectations)}, but none was recorded.
        #{seen_phrase(event, seen)}
        """)
    end
  end

  defp refute_event(event, service, expectations, description) do
    case take_event(event, service, expectations, []) do
      {:error, _seen} ->
        :ok

      {:ok, metadata} ->
        ExUnit.Assertions.flunk("""
        expected no #{description} for #{inspect(service)}#{expectation_phrase(expectations)}, but one was recorded with metadata:
        #{inspect(metadata)}
        """)
    end
  end

  # Drains the mailbox of this library's events, matching as it goes. Events that
  # do not match are put back, so one assertion does not consume another's event
  # regardless of the order the two are written in.
  defp take_event(event, service, expectations, unmatched) do
    receive do
      {__MODULE__, ^event, _measurements, %{service: ^service} = metadata} = message ->
        if matches?(metadata, expectations) do
          restore(unmatched)
          {:ok, metadata}
        else
          take_event(event, service, expectations, [message | unmatched])
        end

      {__MODULE__, _event, _measurements, _metadata} = message ->
        take_event(event, service, expectations, [message | unmatched])
    after
      0 ->
        restore(unmatched)
        {:error, Enum.reverse(unmatched)}
    end
  end

  defp restore(messages) do
    messages
    |> Enum.reverse()
    |> Enum.each(&send(self(), &1))
  end

  defp collect_slept(acc) do
    receive do
      {__MODULE__, :slept, delay} -> collect_slept([delay | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp matches?(metadata, expectations) do
    Enum.all?(expectations, fn {key, expected} ->
      case Map.fetch(metadata, key) do
        {:ok, actual} -> field_matches?(expected, actual)
        :error -> false
      end
    end)
  end

  defp field_matches?(%Regex{} = pattern, actual) when is_binary(actual),
    do: Regex.match?(pattern, actual)

  defp field_matches?(%Regex{} = pattern, actual), do: Regex.match?(pattern, inspect(actual))

  defp field_matches?(expected, actual), do: expected == actual

  defp expectation_phrase([]), do: ""
  defp expectation_phrase(expectations), do: " matching #{inspect(expectations)}"

  defp seen_phrase(_event, []) do
    "No events were recorded at all. Did you call `record_events/0` (`setup :record_events`) before the code under test?"
  end

  defp seen_phrase(event, seen) do
    others =
      Enum.map_join(seen, "\n", fn {_tag, recorded_event, _measurements, metadata} ->
        "  #{inspect(recorded_event)} #{inspect(metadata)}"
      end)

    "Recorded instead:\n#{others}\n(looking for #{inspect(event)})"
  end

  defp recording_sleep_hint([]),
    do:
      "\n\nNothing was recorded. Is the service started with `sleep_function: recording_sleep()`?"

  defp recording_sleep_hint(_actual), do: ""

  defp tolerate(service) do
    service
    |> options!()
    |> get_in([:circuit_breaker, :tolerate])
  end

  defp limit(service) do
    service
    |> options!()
    |> get_in([:rate_limit, :limit])
  end

  defp options!(service) do
    case State.fetch(service) do
      {:ok, %State{options: options}} ->
        options

      :error ->
        raise ArgumentError,
              "#{inspect(service)} has not been started. Call `ExternalService.start/2` " <>
                "(or start the module under a supervisor) before using this helper."
    end
  end
end
