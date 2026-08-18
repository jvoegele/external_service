defmodule ExternalServiceTest.Upstream do
  @moduledoc false
  # An exception whose retriability depends on the *instance* rather than the
  # type, which is what a `:retry_exceptions` predicate exists to express.
  defexception [:message, :status]
end

defmodule ExternalServiceTest.Raiser do
  @moduledoc false
  # Raises from a named function in a compiled module, so that the stacktrace has
  # a frame a test can recognise.
  def boom, do: raise("KABOOM!")
end

defmodule ExternalServiceTest do
  use ExUnit.Case
  import ExUnit.CaptureLog
  alias ExternalService
  alias ExternalService.CircuitBreakerOpen
  alias ExternalService.RetriesExhausted
  alias ExternalService.RetryOptions
  alias ExternalService.ServiceNotStarted

  @moduletag capture_log: true

  @fuse_name :"test-fuse"

  # Most tests here are about what drives a retry, and assert that a failing
  # function keeps being called until the circuit breaker opens. That needs
  # retrying not to stop first, so they opt out of the `:max_attempts` default of
  # 5 — which is exactly the migration an application relying on unbounded
  # retrying has to make.
  @retry_opts %RetryOptions{
    backoff: :linear,
    base: 0,
    max_attempts: :infinity
  }

  # Retries raised RuntimeErrors (the new default is to NOT retry exceptions).
  @retry_runtime_errors %RetryOptions{
    backoff: :linear,
    base: 0,
    max_attempts: :infinity,
    retry_exceptions: [RuntimeError]
  }

  @expiring_retry_options %RetryOptions{
    backoff: :linear,
    base: 1,
    expiry: 1,
    retry_exceptions: [RuntimeError]
  }

  describe "uninitialized fuse" do
    test "call returns a ServiceNotStarted error" do
      result = ExternalService.call(:testing_nonexistent_fuse, fn -> :noop end)

      assert {:error, %ServiceNotStarted{context: %{service: :testing_nonexistent_fuse}}} = result
    end

    test "call! raises ServiceNotStarted" do
      assert_raise ServiceNotStarted, fn ->
        ExternalService.call!(:testing_nonexistent_fuse, fn -> :noop end)
      end
    end
  end

  describe "start" do
    test "installs a fuse" do
      ExternalService.start(@fuse_name)
      assert :fuse.ask(@fuse_name, :sync) == :ok
    end

    test "a service that configures nothing still bounds its retries" do
      # There is no unbounded-retries warning any more, because there are no
      # unbounded retries by default. This is what replaced it.
      service =
        start_fuse(:"default-retry-bound", circuit_breaker: [tolerate: 100, within: 10_000])

      Process.put(service, 0)

      ExternalService.call(service, fn ->
        Process.put(service, Process.get(service) + 1)
        :retry
      end)

      assert Process.get(service) == 5
    end

    test "unbounded retrying is still available, explicitly" do
      service =
        start_fuse(:"explicit-infinity",
          circuit_breaker: [tolerate: 3, within: 10_000],
          retry: [max_attempts: :infinity, backoff: :linear, base: 0]
        )

      Process.put(service, 0)

      ExternalService.call(service, fn ->
        Process.put(service, Process.get(service) + 1)
        :retry
      end)

      # Nothing bounds the count, so it kept going until the breaker opened.
      assert Process.get(service) == 4
    end

    test "warns when a rate limited service sets no wait budget" do
      log =
        capture_log(fn ->
          start_fuse(:"unbounded-wait-warning",
            retry: [max_attempts: 5],
            rate_limit: [limit: 10, per: 1_000]
          )
        end)

      assert log =~ "sets no rate limit wait budget"
      assert log =~ "wait: :infinity"
    end

    test "the suggested budget is the service's own :per" do
      log =
        capture_log(fn ->
          start_fuse(:"unbounded-wait-per",
            retry: [max_attempts: 5],
            rate_limit: [limit: 10, per: 30_000]
          )
        end)

      assert log =~ "wait: 30000"
    end

    for {label, wait} <- [
          {"an explicit :infinity", :infinity},
          {"false", false},
          {"a millisecond budget", 2_000}
        ] do
      test "does not warn when :wait is #{label}" do
        log =
          capture_log(fn ->
            start_fuse(:"bounded-wait-#{unquote(label)}",
              retry: [max_attempts: 5],
              rate_limit: [limit: 10, per: 1_000, wait: unquote(Macro.escape(wait))]
            )
          end)

        refute log =~ "sets no rate limit wait budget"
      end
    end

    test "does not warn for a service with no rate limit at all" do
      log = capture_log(fn -> start_fuse(:"no-rate-limit", retry: [max_attempts: 5]) end)

      refute log =~ "sets no rate limit wait budget"
    end
  end

  describe "stop" do
    test "removes a fuse" do
      # Start the fuse here rather than relying on another test having installed
      # it first; ExUnit randomizes test order, so this test must be independent.
      ExternalService.start(@fuse_name)
      assert :fuse.ask(@fuse_name, :sync) == :ok

      ExternalService.stop(@fuse_name)
      assert :fuse.ask(@fuse_name, :sync) == {:error, :not_found}
    end
  end

  describe "call" do
    @fuse_retries 5

    setup do
      Process.put(@fuse_name, 0)

      ExternalService.start(@fuse_name,
        circuit_breaker: [tolerate: @fuse_retries, within: 10_000]
      )
    end

    test "calls function once when successful" do
      ExternalService.call(@fuse_name, @retry_opts, fn ->
        Process.put(@fuse_name, Process.get(@fuse_name) + 1)
        :ok
      end)

      assert Process.get(@fuse_name) == 1
    end

    test "calls function again when it returns retry" do
      ExternalService.call(@fuse_name, @retry_opts, fn ->
        Process.put(@fuse_name, Process.get(@fuse_name) + 1)
        :retry
      end)

      assert Process.get(@fuse_name) == @fuse_retries + 1
    end

    test "stops retrying on success" do
      ExternalService.call(@fuse_name, @retry_opts, fn ->
        Process.put(@fuse_name, Process.get(@fuse_name) + 1)

        case Process.get(@fuse_name) do
          1 -> :retry
          _ -> :ok
        end
      end)

      assert Process.get(@fuse_name) == 2
    end

    test "does not retry raised exceptions by default" do
      assert_raise(RuntimeError, fn ->
        ExternalService.call(@fuse_name, @retry_opts, fn ->
          Process.put(@fuse_name, Process.get(@fuse_name) + 1)
          raise "KABOOM!"
        end)
      end)

      assert Process.get(@fuse_name) == 1
    end

    test "calls function again when it raises an exception listed in retry_exceptions" do
      ExternalService.call(@fuse_name, @retry_runtime_errors, fn ->
        Process.put(@fuse_name, Process.get(@fuse_name) + 1)
        raise "KABOOM!"
      end)

      assert Process.get(@fuse_name) == @fuse_retries + 1
    end

    test "calls function again when it raises another exception type listed in retry_exceptions" do
      retry_opts = %{@retry_opts | retry_exceptions: [ArithmeticError, ArgumentError]}

      ExternalService.call(@fuse_name, retry_opts, fn ->
        Process.put(@fuse_name, Process.get(@fuse_name) + 1)
        raise ArgumentError, message: "KABOOM!"
      end)

      assert Process.get(@fuse_name) == @fuse_retries + 1
    end

    test "does not call function again when it raises an exception not listed in retry_exceptions" do
      retry_opts = %{@retry_opts | retry_exceptions: [SystemLimitError, File.Error]}

      assert_raise(RuntimeError, fn ->
        ExternalService.call(@fuse_name, retry_opts, fn ->
          Process.put(@fuse_name, Process.get(@fuse_name) + 1)
          raise "KABOOM!"
        end)
      end)

      assert Process.get(@fuse_name) == 1
    end

    test "an exception not listed in retry_exceptions does not melt the circuit breaker" do
      retry_opts = %{@retry_opts | retry_exceptions: [ArgumentError]}

      # Raise far more times than the breaker would tolerate; because the
      # exception is not retriable, none of these should count as a failure.
      for _ <- 1..(@fuse_retries * 3) do
        assert_raise(RuntimeError, fn ->
          ExternalService.call(@fuse_name, retry_opts, fn -> raise "KABOOM!" end)
        end)
      end

      assert ExternalService.available?(@fuse_name)
    end

    test "retry_exceptions accepts a predicate that decides per instance" do
      # Given as per-call overrides rather than a struct, so the predicate also
      # goes through option validation and merging on its way in.
      retry_opts = [
        backoff: :linear,
        base: 0,
        max_attempts: :infinity,
        retry_exceptions: &transient_upstream?/1
      ]

      ExternalService.call(@fuse_name, retry_opts, fn ->
        Process.put(@fuse_name, Process.get(@fuse_name) + 1)
        raise ExternalServiceTest.Upstream, message: "gateway timeout", status: 504
      end)

      assert Process.get(@fuse_name) == @fuse_retries + 1
    end

    test "an exception the retry_exceptions predicate rejects is not retried or melted" do
      retry_opts = %{@retry_opts | retry_exceptions: &transient_upstream?/1}

      # Same type as the test above, but a status the predicate calls permanent.
      for _ <- 1..(@fuse_retries * 3) do
        assert_raise(ExternalServiceTest.Upstream, fn ->
          ExternalService.call(@fuse_name, retry_opts, fn ->
            Process.put(@fuse_name, Process.get(@fuse_name) + 1)
            raise ExternalServiceTest.Upstream, message: "not found", status: 404
          end)
        end)
      end

      assert Process.get(@fuse_name) == @fuse_retries * 3
      assert ExternalService.available?(@fuse_name)
    end

    test "re-raises the original exception with its original stacktrace once retries are spent" do
      retry_opts = %{@retry_runtime_errors | max_attempts: 2}

      {exception, stacktrace} =
        try do
          ExternalService.call(@fuse_name, retry_opts, &ExternalServiceTest.Raiser.boom/0)
          flunk("expected the exhausted call to re-raise")
        rescue
          error -> {error, __STACKTRACE__}
        end

      assert %RuntimeError{message: "KABOOM!"} = exception

      # The trace must still point at the code that raised, not at the retry loop
      # that carried the exception around.
      assert {ExternalServiceTest.Raiser, :boom, 0, _location} = hd(stacktrace)
    end

    test "returns CircuitBreakerOpen when the fuse is blown by retries" do
      res =
        ExternalService.call(@fuse_name, @retry_opts, fn ->
          :retry
        end)

      assert {:error, %CircuitBreakerOpen{context: %{service: @fuse_name}}} = res
    end

    test "returns CircuitBreakerOpen when the fuse is blown by exceptions" do
      res =
        ExternalService.call(@fuse_name, @retry_runtime_errors, fn ->
          raise "KABOOM!"
        end)

      assert {:error, %CircuitBreakerOpen{context: %{service: @fuse_name}}} = res
    end

    test "returns RetriesExhausted when retries are exhausted with :retry" do
      res =
        ExternalService.call(@fuse_name, @expiring_retry_options, fn ->
          :retry
        end)

      assert {:error, %RetriesExhausted{context: %{reason: :reason_unknown}}} = res
    end

    test "returns RetriesExhausted carrying the reason when retries are exhausted with a reason" do
      res =
        ExternalService.call(@fuse_name, @expiring_retry_options, fn ->
          {:retry, "reason"}
        end)

      assert {:error, %RetriesExhausted{context: %{service: @fuse_name, reason: "reason"}}} = res
    end

    test "propagates original exception when retries are exhausted by an exception" do
      assert_raise RuntimeError, "KABOOM!", fn ->
        ExternalService.call(@fuse_name, @expiring_retry_options, fn ->
          raise "KABOOM!"
        end)
      end
    end

    test "returns original result value when given a function that is not retriable" do
      res =
        ExternalService.call(@fuse_name, @retry_opts, fn ->
          {:error, "reason"}
        end)

      assert res == {:error, "reason"}
    end

    test "calls function again when the retry_on predicate matches the result" do
      retry_opts = %{@retry_opts | retry_on: &match?({:error, _}, &1)}

      ExternalService.call(@fuse_name, retry_opts, fn ->
        Process.put(@fuse_name, Process.get(@fuse_name) + 1)
        {:error, :nope}
      end)

      assert Process.get(@fuse_name) == @fuse_retries + 1
    end

    test "returns the result unchanged when the retry_on predicate does not match" do
      retry_opts = %{@retry_opts | retry_on: &match?({:error, _}, &1)}

      res =
        ExternalService.call(@fuse_name, retry_opts, fn ->
          Process.put(@fuse_name, Process.get(@fuse_name) + 1)
          {:ok, :good}
        end)

      assert res == {:ok, :good}
      assert Process.get(@fuse_name) == 1
    end

    test "a result matched by the retry_on predicate melts the circuit breaker" do
      retry_opts = %{@retry_opts | retry_on: &match?({:error, _}, &1)}

      res = ExternalService.call(@fuse_name, retry_opts, fn -> {:error, :boom} end)

      assert {:error, %CircuitBreakerOpen{context: %{service: @fuse_name}}} = res
    end

    test "exhausting retries via the retry_on predicate surfaces the result as the reason" do
      retry_opts = %RetryOptions{
        backoff: :linear,
        base: 1,
        expiry: 1,
        retry_on: &match?({:error, _}, &1)
      }

      res = ExternalService.call(@fuse_name, retry_opts, fn -> {:error, :boom} end)

      assert {:error, %RetriesExhausted{context: %{reason: {:error, :boom}}}} = res
    end

    test "an explicit :retry return takes precedence over the retry_on predicate" do
      # The predicate never matches, yet an explicit `:retry` must still retry:
      # the `:retry` protocol is handled before the predicate is ever consulted.
      retry_opts = %{@retry_opts | retry_on: fn _ -> false end}

      ExternalService.call(@fuse_name, retry_opts, fn ->
        Process.put(@fuse_name, Process.get(@fuse_name) + 1)
        :retry
      end)

      assert Process.get(@fuse_name) == @fuse_retries + 1
    end

    test "a retry_exceptions predicate that fails leaves the original exception alone" do
      for {label, predicate} <- [
            {"raise", fn _error -> raise "predicate blew up" end},
            {"throw", fn _error -> throw(:predicate_threw) end},
            {"exit", fn _error -> exit(:predicate_exited) end}
          ] do
        retry_opts = %{@retry_opts | retry_exceptions: predicate}
        Process.put(@fuse_name, 0)

        # The caller must see the exception the function actually raised — not
        # whatever the predicate did — with its own stacktrace.
        {error, stacktrace} =
          try do
            ExternalService.call(@fuse_name, retry_opts, fn ->
              Process.put(@fuse_name, Process.get(@fuse_name) + 1)
              ExternalServiceTest.Raiser.boom()
            end)

            flunk("expected the original exception to propagate (#{label})")
          rescue
            error -> {error, __STACKTRACE__}
          end

        assert %RuntimeError{message: "KABOOM!"} = error, label
        assert {ExternalServiceTest.Raiser, :boom, 0, _location} = hd(stacktrace)

        # A predicate that could not answer means "not retriable", which governs
        # melting too.
        assert Process.get(@fuse_name) == 1, label
        assert ExternalService.available?(@fuse_name), label
      end
    end

    test "a failing retry_exceptions predicate logs a warning naming the option and service" do
      retry_opts = %{@retry_opts | retry_exceptions: fn _error -> raise "predicate blew up" end}

      log =
        capture_log(fn ->
          assert_raise(RuntimeError, "KABOOM!", fn ->
            ExternalService.call(@fuse_name, retry_opts, fn -> raise "KABOOM!" end)
          end)
        end)

      assert log =~ ":retry_exceptions predicate for #{inspect(@fuse_name)}"
      # The predicate's own failure is reported, so it can be found and fixed.
      assert log =~ "predicate blew up"
    end

    test "a retry_on predicate that fails leaves a successful result alone" do
      # Before this was guarded, the predicate's exception escaped as the call's
      # result — and if `:retry_exceptions` happened to match it, the successful
      # function was run again for every remaining attempt.
      retry_opts = %{
        @retry_opts
        | retry_on: fn _result -> raise "predicate blew up" end,
          retry_exceptions: [RuntimeError]
      }

      result =
        ExternalService.call(@fuse_name, retry_opts, fn ->
          Process.put(@fuse_name, Process.get(@fuse_name) + 1)
          :ok
        end)

      assert result == :ok
      assert Process.get(@fuse_name) == 1
      assert ExternalService.available?(@fuse_name)
    end

    test "an :expiry budget is spent but not overshot" do
      service = "expiry budget service"
      ExternalService.start(service, circuit_breaker: [tolerate: 100, within: 10_000])
      on_exit(fn -> ExternalService.stop(service) end)

      Process.put(:attempts, 0)

      # This one asserts on the clock, because the clock is the behavior: a 50ms
      # budget used to cost 100ms and buy exactly one retry, since the final delay
      # was floored at 100ms (#70). The bounds are loose enough to survive a busy
      # machine while still separating the two behaviors.
      {microseconds, _result} =
        :timer.tc(fn ->
          ExternalService.call(service, [backoff: :exponential, base: 10, expiry: 50], fn ->
            Process.put(:attempts, Process.get(:attempts) + 1)
            :retry
          end)
        end)

      elapsed = div(microseconds, 1000)

      assert elapsed < 95, "a 50ms budget took #{elapsed}ms"

      assert Process.get(:attempts) >= 3,
             "the budget bought only #{Process.get(:attempts)} attempts"
    end

    test "calls the sleep function for retry backoff, without waiting" do
      service = "retry backoff sleep service"

      sleep = fn delay -> Process.put(:slept, [delay | Process.get(:slept, [])]) end

      ExternalService.start(service,
        circuit_breaker: [tolerate: 100, within: 10_000],
        sleep_function: sleep
      )

      on_exit(fn -> ExternalService.stop(service) end)

      {microseconds, _result} =
        :timer.tc(fn ->
          ExternalService.call(
            service,
            [backoff: :linear, base: 100, factor: 100, max_attempts: 4],
            fn -> :retry end
          )
        end)

      # Every backoff delay went to the sleep function rather than to the
      # scheduler, in order, and none of it was actually waited for.
      assert Enum.reverse(Process.get(:slept)) == [100, 200, 300]
      assert microseconds < 100_000
    end

    test "calls sleep function when rate limit is reached" do
      service = "sleep test service"

      Process.put(:call_count, 0)

      sleep = fn time ->
        Process.put(:sleep_fired, true)
        # The limiter admits calls against a real clock, so the stub has to let
        # the time actually pass for a throttled call to make progress.
        Process.sleep(time)
      end

      # The token bucket's burst capacity is exactly `:limit`, so the first five
      # calls go straight through and the sixth is throttled. A short window
      # keeps the resulting sleeps (one emission interval, 10ms) brief.
      ExternalService.start(service,
        rate_limit: [limit: 5, per: 50],
        sleep_function: sleep
      )

      on_exit(fn -> ExternalService.stop(service) end)

      results =
        for i <- 1..10 do
          ExternalService.call(service, fn ->
            unless Process.get(:sleep_fired) do
              Process.put(:call_count, Process.get(:call_count) + 1)
            end

            i
          end)
        end

      assert results == Enum.to_list(1..10)
      assert Process.get(:sleep_fired) == true
      assert Process.get(:call_count) == 5
    end
  end

  describe "per-call retry options" do
    setup do
      Process.put(@fuse_name, 0)

      # Configure a distinctive default so we can tell merge from replace.
      ExternalService.start(@fuse_name,
        circuit_breaker: [tolerate: 50, within: 10_000],
        retry: [backoff: :linear, base: 0, max_attempts: 2]
      )
    end

    defp count_retries(opts) do
      ExternalService.call(@fuse_name, opts, fn ->
        Process.put(@fuse_name, Process.get(@fuse_name) + 1)
        :retry
      end)

      Process.get(@fuse_name)
    end

    test "call/2 uses the service's configured retry defaults" do
      ExternalService.call(@fuse_name, fn ->
        Process.put(@fuse_name, Process.get(@fuse_name) + 1)
        :retry
      end)

      assert Process.get(@fuse_name) == 2
    end

    test "a keyword override leaves unspecified keys at the service default" do
      # Overriding an unrelated key must NOT reset max_attempts back to its
      # library default of `nil` (unbounded) — it stays at the service's 2.
      assert count_retries(jitter: true) == 2
    end

    test "a keyword override changes only the keys it lists" do
      assert count_retries(max_attempts: 4) == 4
    end

    test "a RetryOptions struct replaces the service defaults entirely" do
      # The struct omits max_attempts, so retries are bounded only by the breaker
      # (tolerate: 50), proving the service's max_attempts: 2 was discarded.
      ExternalService.call(@fuse_name, %RetryOptions{backoff: :linear, base: 0}, fn ->
        Process.put(@fuse_name, Process.get(@fuse_name) + 1)
        :retry
      end)

      assert Process.get(@fuse_name) > 2
    end
  end

  describe "call!" do
    @fuse_retries 5

    setup do
      Process.put(@fuse_name, 0)

      ExternalService.start(@fuse_name,
        circuit_breaker: [tolerate: @fuse_retries, within: 10_000]
      )
    end

    test "calls function once when successful" do
      ExternalService.call!(@fuse_name, @retry_opts, fn ->
        Process.put(@fuse_name, Process.get(@fuse_name) + 1)
        :ok
      end)

      assert Process.get(@fuse_name) == 1
    end

    test "calls function again when it returns retry" do
      try do
        ExternalService.call!(@fuse_name, @retry_opts, fn ->
          Process.put(@fuse_name, Process.get(@fuse_name) + 1)
          :retry
        end)
      rescue
        CircuitBreakerOpen -> :ok
      end

      assert Process.get(@fuse_name) == @fuse_retries + 1
    end

    test "stops retrying on success" do
      ExternalService.call!(@fuse_name, @retry_opts, fn ->
        Process.put(@fuse_name, Process.get(@fuse_name) + 1)

        case Process.get(@fuse_name) do
          1 -> :retry
          _ -> :ok
        end
      end)

      assert Process.get(@fuse_name) == 2
    end

    test "calls function again when it raises an exception listed in retry_exceptions" do
      try do
        ExternalService.call!(@fuse_name, @retry_runtime_errors, fn ->
          Process.put(@fuse_name, Process.get(@fuse_name) + 1)
          raise "KABOOM!"
        end)
      rescue
        CircuitBreakerOpen -> :ok
      end

      assert Process.get(@fuse_name) == @fuse_retries + 1
    end

    test "raises CircuitBreakerOpen when the fuse is blown by retries" do
      error =
        assert_raise CircuitBreakerOpen, fn ->
          ExternalService.call!(@fuse_name, @retry_opts, fn -> :retry end)
        end

      assert error.context.service == @fuse_name
    end

    test "raises CircuitBreakerOpen when the fuse is blown by exceptions" do
      assert_raise CircuitBreakerOpen, fn ->
        ExternalService.call!(@fuse_name, @retry_runtime_errors, fn -> raise "KABOOM!" end)
      end
    end

    test "raises RetriesExhausted when retries are exhausted with :retry" do
      assert_raise RetriesExhausted, fn ->
        ExternalService.call!(@fuse_name, @expiring_retry_options, fn -> :retry end)
      end
    end

    test "raises RetriesExhausted when retries are exhausted with a reason" do
      error =
        assert_raise RetriesExhausted, fn ->
          ExternalService.call!(@fuse_name, @expiring_retry_options, fn -> {:retry, "reason"} end)
        end

      assert error.context.reason == "reason"
    end

    test "propagates original exception when retries are exhausted by an exception" do
      assert_raise RuntimeError, "KABOOM!", fn ->
        ExternalService.call!(@fuse_name, @expiring_retry_options, fn -> raise "KABOOM!" end)
      end
    end

    test "returns original result value when given a function that is not retriable" do
      res =
        ExternalService.call!(@fuse_name, @retry_opts, fn ->
          {:error, "reason"}
        end)

      assert res == {:error, "reason"}
    end
  end

  describe "call_async" do
    setup do
      ExternalService.start(@fuse_name,
        circuit_breaker: [tolerate: @fuse_retries, within: 10_000]
      )
    end

    test "returns a Task" do
      task = ExternalService.call_async(@fuse_name, fn -> :ok end)
      assert Task.await(task) == :ok
    end
  end

  describe "call_async_stream" do
    setup do
      # A high failure tolerance keeps the shared fuse from blowing, so each
      # element's result is deterministic regardless of how the stream is
      # scheduled across processes.
      ExternalService.start(@fuse_name, circuit_breaker: [tolerate: 100, within: 10_000])
    end

    def function(arg), do: arg

    # Each element is a non-retriable value, so its result passes straight
    # through and the assertions do not depend on retry timing or fuse state.
    @enumerable [42, :ok, {:error, :reason}, {:ok, :done}]
    @expected [{:ok, 42}, {:ok, :ok}, {:ok, {:error, :reason}}, {:ok, {:ok, :done}}]
    @async_opts [max_concurrency: 100, timeout: 10_000]

    test "with no options" do
      results =
        @enumerable
        |> ExternalService.call_async_stream(@fuse_name, &function/1)
        |> Enum.to_list()

      assert results == @expected
    end

    test "with retry options" do
      results =
        @enumerable
        |> ExternalService.call_async_stream(@fuse_name, @retry_opts, &function/1)
        |> Enum.to_list()

      assert results == @expected
    end

    test "with async options" do
      results =
        @enumerable
        |> ExternalService.call_async_stream(@fuse_name, @async_opts, &function/1)
        |> Enum.to_list()

      assert results == @expected
    end

    test "with retry and async options" do
      results =
        @enumerable
        |> ExternalService.call_async_stream(@fuse_name, @retry_opts, @async_opts, &function/1)
        |> Enum.to_list()

      assert results == @expected
    end

    test "applies retry options to each element" do
      opts = %RetryOptions{backoff: :linear, base: 0, max_attempts: 2}

      results =
        [:retry, :ok]
        |> ExternalService.call_async_stream(@fuse_name, opts, &function/1)
        |> Enum.to_list()

      assert [{:ok, {:error, %RetriesExhausted{}}}, {:ok, :ok}] = results
    end
  end

  describe "start/stop lifecycle" do
    test "stop removes both the fuse and the persisted state" do
      name = :"lifecycle-test"

      assert :ok = ExternalService.start(name)
      assert :fuse.ask(name, :sync) == :ok
      assert %ExternalService.State{service: ^name} = ExternalService.State.get(name)

      assert :ok = ExternalService.stop(name)
      assert :fuse.ask(name, :sync) == {:error, :not_found}
      # State is stored in :persistent_term, which raises when the key is absent.
      assert_raise ArgumentError, fn -> ExternalService.State.get(name) end
    end

    test "stop is idempotent and safe on a service that was never started" do
      assert :ok = ExternalService.stop(:"never-started-service")
    end
  end

  describe "fault_injection strategy (regression for #4)" do
    test "exercising the fuse monitor does not crash it" do
      name = :"fault-injection-test"

      assert :ok =
               ExternalService.start(name,
                 circuit_breaker: [tolerate: 5, within: 1_000, fault_injection: 0.5]
               )

      monitor = Process.whereis(:fuse_monitor)
      assert is_pid(monitor)

      for _ <- 1..20 do
        ExternalService.call(name, @expiring_retry_options, fn -> :ok end)
      end

      # Force the periodic bookkeeping that historically raised a
      # FunctionClauseError in :fuse_monitor.update/2 for gradual (fault
      # injection) fuses. fuse 2.5 fixed this; the synchronous sync/0 call below
      # is serialized after the :timeout message, so it only returns once the
      # monitor has processed it — if the monitor had crashed, this would exit.
      send(:fuse_monitor, :timeout)
      assert :fuse_monitor.sync() == :ok
      assert Process.whereis(:fuse_monitor) == monitor

      ExternalService.stop(name)
    end
  end

  describe "retry options" do
    test "max_attempts limits the total number of attempts" do
      name = start_fuse(:"max-attempts-test")
      Process.put(:count, 0)
      opts = %RetryOptions{backoff: :linear, base: 0, max_attempts: 3}

      result =
        ExternalService.call(name, opts, fn ->
          Process.put(:count, Process.get(:count) + 1)
          :retry
        end)

      assert Process.get(:count) == 3
      assert {:error, %RetriesExhausted{context: %{reason: :reason_unknown}}} = result
    end

    test "max_attempts of 1 makes a single attempt with no retries" do
      name = start_fuse(:"max-attempts-one")
      Process.put(:count, 0)
      opts = %RetryOptions{backoff: :linear, base: 0, max_attempts: 1}

      ExternalService.call(name, opts, fn ->
        Process.put(:count, Process.get(:count) + 1)
        :retry
      end)

      assert Process.get(:count) == 1
    end

    test "max_attempts of :infinity does not limit the attempt count" do
      # Only the breaker stops this, exactly as an unset :max_attempts would.
      name = start_fuse(:"max-attempts-infinity", circuit_breaker: [tolerate: 5, within: 10_000])
      Process.put(:count, 0)
      opts = %RetryOptions{backoff: :linear, base: 0, max_attempts: :infinity}

      ExternalService.call(name, opts, fn ->
        Process.put(:count, Process.get(:count) + 1)
        :retry
      end)

      assert Process.get(:count) > 5
    end

    test "expiry of :infinity imposes no time budget" do
      name = start_fuse(:"expiry-infinity", circuit_breaker: [tolerate: 5, within: 10_000])
      Process.put(:count, 0)
      # `:max_attempts` is set to :infinity so that this asserts about `:expiry`
      # alone rather than about the attempt-count default.
      opts = %RetryOptions{backoff: :linear, base: 0, expiry: :infinity, max_attempts: :infinity}

      ExternalService.call(name, opts, fn ->
        Process.put(:count, Process.get(:count) + 1)
        :retry
      end)

      assert Process.get(:count) > 5
    end

    test "expiry is evaluated between attempts, so it cannot bound a slow one" do
      # Documented in guides/retries.md and guides/circuit-breakers.md: the
      # library imposes no timeout, and :expiry does not supply one. If this ever
      # starts bounding attempt duration, those sections are wrong.
      name = start_fuse(:"expiry-slow-attempt", circuit_breaker: [tolerate: 100, within: 60_000])
      Process.put(:count, 0)
      opts = %RetryOptions{backoff: :linear, base: 0, max_attempts: 4, expiry: 100}

      {elapsed, _result} =
        :timer.tc(fn ->
          ExternalService.call(name, opts, fn ->
            Process.put(:count, Process.get(:count) + 1)
            Process.sleep(300)
            :retry
          end)
        end)

      # At least one whole attempt ran to completion despite a 100ms budget, so
      # the call overran it by several times.
      assert Process.get(:count) >= 2
      assert elapsed > 500_000
    end

    test "a call in flight does not melt the breaker" do
      name = start_fuse(:"slow-call-no-melt", circuit_breaker: [tolerate: 1, within: 60_000])

      task =
        Task.async(fn ->
          ExternalService.call(name, %RetryOptions{max_attempts: 1}, fn ->
            Process.sleep(300)
            :ok
          end)
        end)

      Process.sleep(100)

      # No failure has been observed yet, so there is nothing for the breaker to
      # count -- which is exactly why a hang is invisible to it.
      assert ExternalService.available?(name)
      refute ExternalService.blown?(name)

      assert Task.await(task) == :ok
    end

    test "jitter affects only delay, not the attempt count" do
      for jitter <- [true, 0.5] do
        name = start_fuse(:"jitter-test-#{inspect(jitter)}")
        counter = {:jitter_count, jitter}
        Process.put(counter, 0)
        opts = %RetryOptions{backoff: :linear, base: 0, jitter: jitter, max_attempts: 3}

        ExternalService.call(name, opts, fn ->
          Process.put(counter, Process.get(counter) + 1)
          :retry
        end)

        assert Process.get(counter) == 3
      end
    end
  end

  describe "structured errors" do
    @one_attempt %RetryOptions{backoff: :linear, base: 0, max_attempts: 1}

    setup do
      ExternalService.start(@fuse_name, circuit_breaker: [tolerate: 50, within: 10_000])
    end

    test "errors returned by call/3 are exceptions that can also be raised" do
      {:error, error} = ExternalService.call(:not_started, fn -> :noop end)

      assert %ServiceNotStarted{} = error
      assert is_exception(error)
      assert Exception.message(error) =~ "not been started"
    end

    test "http_status reflects the kind of failure" do
      # Transient infrastructure failures map to 503 (Service Unavailable)...
      assert ExternalService.RetriesExhausted.http_status(%RetriesExhausted{}) == 503
      assert ExternalService.CircuitBreakerOpen.http_status(%CircuitBreakerOpen{}) == 503
      # ...but a service that was never started is a programming error (500).
      assert ExternalService.ServiceNotStarted.http_status(%ServiceNotStarted{}) == 500
    end

    test "retryable? distinguishes conditions that clear on their own" do
      # The wrapped function never ran and the condition passes: worth another go.
      assert Errata.retryable?(%CircuitBreakerOpen{})
      assert Errata.retryable?(%ExternalService.RateLimited{})
      assert Errata.retryable?(%ExternalService.ServiceSaturated{})

      # Retrying is exactly what already failed...
      refute Errata.retryable?(%RetriesExhausted{})
      # ...and nothing changes until the service is actually started.
      refute Errata.retryable?(%ServiceNotStarted{})
    end

    test "an exception retry reason is chained as the cause" do
      cause = ArgumentError.exception("upstream said no")

      {:error, error} =
        ExternalService.call(@fuse_name, @one_attempt, fn -> {:retry, cause} end)

      assert %RetriesExhausted{context: %{reason: ^cause}} = error
      assert Errata.cause(error) == cause
      assert Errata.root_cause(error) == cause
      assert Errata.format_chain(error) =~ "Caused by: "
      assert Errata.format_chain(error) =~ "upstream said no"
    end

    test "a non-exception retry reason leaves the cause unset" do
      {:error, error} =
        ExternalService.call(@fuse_name, @one_attempt, fn -> {:retry, :timeout} end)

      assert %RetriesExhausted{context: %{reason: :timeout}} = error
      assert Errata.cause(error) == nil
    end
  end

  describe "introspection" do
    setup do
      name = :"introspection-test"
      ExternalService.start(name, circuit_breaker: [tolerate: 1, within: 10_000])
      on_exit(fn -> ExternalService.stop(name) end)
      [name: name]
    end

    test "available?/blown? for a freshly started service", %{name: name} do
      assert ExternalService.available?(name)
      refute ExternalService.blown?(name)
    end

    test "available?/blown? once the breaker is blown", %{name: name} do
      blow_fuse(name)

      assert ExternalService.blown?(name)
      refute ExternalService.available?(name)
    end

    test "a service that was never started is neither available nor blown" do
      refute ExternalService.available?(:"never-started-service")
      refute ExternalService.blown?(:"never-started-service")
    end

    test "all_available? requires every service to be available", %{name: name} do
      other = :"introspection-test-2"
      ExternalService.start(other, circuit_breaker: [tolerate: 1, within: 10_000])
      on_exit(fn -> ExternalService.stop(other) end)

      assert ExternalService.all_available?([name, other])

      blow_fuse(other)
      refute ExternalService.all_available?([name, other])
    end
  end

  describe "telemetry" do
    @telemetry_events [
      [:external_service, :call, :start],
      [:external_service, :call, :stop],
      [:external_service, :call, :exception],
      [:external_service, :call, :retry],
      [:external_service, :circuit_breaker, :blown],
      [:external_service, :rate_limit, :sleep]
    ]

    setup do
      test_pid = self()
      handler_id = "telemetry-test-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler_id,
        @telemetry_events,
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end

    test "emits call start and stop for a successful call" do
      name = start_fuse(:"telemetry-success")
      assert ExternalService.call(name, fn -> {:ok, 42} end) == {:ok, 42}

      assert_received {:telemetry, [:external_service, :call, :start], measurements,
                       %{service: ^name}}

      assert is_integer(measurements.system_time)

      assert_received {:telemetry, [:external_service, :call, :stop], %{duration: duration},
                       %{service: ^name, result: {:ok, 42}}}

      assert is_integer(duration)
    end

    test "emits a retry event when the function asks to retry" do
      name = start_fuse(:"telemetry-retry")
      ExternalService.call(name, @expiring_retry_options, fn -> {:retry, :boom} end)

      assert_received {:telemetry, [:external_service, :call, :retry], %{count: 1},
                       %{service: ^name, reason: :boom}}
    end

    test "emits a retry event carrying the result when the retry_on predicate matches" do
      name = start_fuse(:"telemetry-retry-on")

      retry_opts = %RetryOptions{
        backoff: :linear,
        base: 1,
        expiry: 1,
        retry_on: &match?({:error, _}, &1)
      }

      ExternalService.call(name, retry_opts, fn -> {:error, :boom} end)

      assert_received {:telemetry, [:external_service, :call, :retry], %{count: 1},
                       %{service: ^name, reason: {:error, :boom}}}
    end

    test "emits a call exception event when the function raises a non-retriable error" do
      name = start_fuse(:"telemetry-exception")
      retry_opts = %RetryOptions{backoff: :linear, base: 0, retry_exceptions: [ArgumentError]}

      assert_raise RuntimeError, fn ->
        ExternalService.call(name, retry_opts, fn -> raise "boom" end)
      end

      assert_received {:telemetry, [:external_service, :call, :exception], %{duration: _},
                       %{service: ^name, kind: :error, reason: %RuntimeError{}}}
    end

    test "emits a circuit_breaker blown event when the breaker is open" do
      name = start_fuse(:"telemetry-blown", circuit_breaker: [tolerate: 1, within: 10_000])
      blow_fuse(name)
      ExternalService.call(name, fn -> :ok end)

      assert_received {:telemetry, [:external_service, :circuit_breaker, :blown], %{count: 1},
                       %{service: ^name}}
    end

    test "emits a rate_limit sleep event when throttled" do
      name = :"telemetry-rate-limit"

      # One call per 50ms window, so the second call is throttled for a single
      # emission interval before it is admitted.
      ExternalService.start(name,
        rate_limit: [limit: 1, per: 50],
        sleep_function: &Process.sleep/1
      )

      on_exit(fn -> ExternalService.stop(name) end)

      ExternalService.call(name, fn -> :ok end)
      ExternalService.call(name, fn -> :ok end)

      assert_received {:telemetry, [:external_service, :rate_limit, :sleep],
                       %{sleep_time: sleep_time}, %{service: ^name}}

      assert is_integer(sleep_time)
    end
  end

  # A `:retry_exceptions` predicate: the same exception type is transient or
  # permanent depending on the status it carries.
  defp transient_upstream?(%ExternalServiceTest.Upstream{status: status}), do: status >= 500
  defp transient_upstream?(_error), do: false

  # Trips a service's circuit breaker by melting it past its configured tolerance.
  defp blow_fuse(name) do
    ExternalService.call(name, %RetryOptions{backoff: :linear, base: 0}, fn -> :retry end)
  end

  # Starts a service with a high failure tolerance (so it won't blow) unless
  # overridden, registers cleanup, and returns its name.
  defp start_fuse(name, options \\ [circuit_breaker: [tolerate: 100, within: 10_000]]) do
    ExternalService.start(name, options)
    on_exit(fn -> ExternalService.stop(name) end)
    name
  end
end
