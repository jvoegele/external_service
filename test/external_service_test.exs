defmodule ExternalServiceTest do
  use ExUnit.Case
  alias ExternalService
  alias ExternalService.CircuitBreakerOpen
  alias ExternalService.RetriesExhausted
  alias ExternalService.RetryOptions
  alias ExternalService.ServiceNotStarted

  @moduletag capture_log: true

  @fuse_name :"test-fuse"

  @retry_opts %RetryOptions{
    backoff: :linear,
    base: 0
  }

  # Retries raised RuntimeErrors (the new default is to NOT retry exceptions).
  @retry_on_runtime %RetryOptions{
    backoff: :linear,
    base: 0,
    retry_on: [RuntimeError]
  }

  @expiring_retry_options %RetryOptions{
    backoff: :linear,
    base: 1,
    expiry: 1,
    retry_on: [RuntimeError]
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

    test "calls function again when it raises an exception listed in retry_on" do
      ExternalService.call(@fuse_name, @retry_on_runtime, fn ->
        Process.put(@fuse_name, Process.get(@fuse_name) + 1)
        raise "KABOOM!"
      end)

      assert Process.get(@fuse_name) == @fuse_retries + 1
    end

    test "calls function again when it raises another exception type listed in retry_on" do
      retry_opts = %{@retry_opts | retry_on: [ArithmeticError, ArgumentError]}

      ExternalService.call(@fuse_name, retry_opts, fn ->
        Process.put(@fuse_name, Process.get(@fuse_name) + 1)
        raise ArgumentError, message: "KABOOM!"
      end)

      assert Process.get(@fuse_name) == @fuse_retries + 1
    end

    test "does not call function again when it raises an exception not listed in retry_on" do
      retry_opts = %{@retry_opts | retry_on: [SystemLimitError, File.Error]}

      assert_raise(RuntimeError, fn ->
        ExternalService.call(@fuse_name, retry_opts, fn ->
          Process.put(@fuse_name, Process.get(@fuse_name) + 1)
          raise "KABOOM!"
        end)
      end)

      assert Process.get(@fuse_name) == 1
    end

    test "an exception not listed in retry_on does not melt the circuit breaker" do
      retry_opts = %{@retry_opts | retry_on: [ArgumentError]}

      # Raise far more times than the breaker would tolerate; because the
      # exception is not retriable, none of these should count as a failure.
      for _ <- 1..(@fuse_retries * 3) do
        assert_raise(RuntimeError, fn ->
          ExternalService.call(@fuse_name, retry_opts, fn -> raise "KABOOM!" end)
        end)
      end

      assert ExternalService.available?(@fuse_name)
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
        ExternalService.call(@fuse_name, @retry_on_runtime, fn ->
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

    test "calls sleep function when rate limit is reached" do
      fuse_name = "sleep test fuse"
      bucket = ExternalService.RateLimit.bucket_name(fuse_name)

      Process.put(:call_count, 0)

      sleep = fn _time ->
        Process.put(:sleep_fired, true)
        # Clear the rate-limit window so the throttled call proceeds immediately.
        # The previous version relied on a tiny (10ms) window elapsing during the
        # calls, which made this test flaky on slow CI runners where the calls
        # straddled the window and the limit was never reached.
        ExRated.delete_bucket(bucket)
      end

      # A wide window guarantees that all 10 calls fall within a single window,
      # so the limit is reliably reached on the 6th call regardless of timing.
      ExternalService.start(fuse_name,
        rate_limit: [limit: 5, per: :timer.minutes(1)],
        sleep_function: sleep
      )

      for i <- 1..10 do
        ExternalService.call(fuse_name, fn ->
          unless Process.get(:sleep_fired) do
            Process.put(:call_count, Process.get(:call_count) + 1)
          end

          i
        end)
      end

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

    test "calls function again when it raises an exception listed in retry_on" do
      try do
        ExternalService.call!(@fuse_name, @retry_on_runtime, fn ->
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
        ExternalService.call!(@fuse_name, @retry_on_runtime, fn -> raise "KABOOM!" end)
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

    test "emits a call exception event when the function raises a non-retriable error" do
      name = start_fuse(:"telemetry-exception")
      retry_opts = %RetryOptions{backoff: :linear, base: 0, retry_on: [ArgumentError]}

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
      bucket = ExternalService.RateLimit.bucket_name(name)
      sleep = fn _time -> ExRated.delete_bucket(bucket) end

      ExternalService.start(name,
        rate_limit: [limit: 1, per: :timer.minutes(1)],
        sleep_function: sleep
      )

      on_exit(fn -> ExternalService.stop(name) end)

      ExternalService.call(name, fn -> :ok end)
      ExternalService.call(name, fn -> :ok end)

      assert_received {:telemetry, [:external_service, :rate_limit, :sleep],
                       %{sleep_time: sleep_time}, %{service: ^name}}

      assert is_integer(sleep_time)
    end
  end

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
