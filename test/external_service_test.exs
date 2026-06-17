defmodule ExternalServiceTest do
  use ExUnit.Case
  alias ExternalService
  alias ExternalService.RetryOptions

  @moduletag capture_log: true

  @fuse_name :"test-fuse"

  @retry_opts %RetryOptions{
    backoff: {:linear, 0, 1}
  }

  @expiring_retry_options %RetryOptions{
    backoff: {:linear, 1, 1},
    expiry: 1
  }

  describe "uninitialized fuse" do
    test "call returns :fuse_not_found error" do
      result = ExternalService.call(:testing_nonexistent_fuse, fn -> :noop end)
      assert result == {:error, {:fuse_not_found, :testing_nonexistent_fuse}}
    end

    test "call! raises FuseNotFoundError" do
      assert_raise ExternalService.FuseNotFoundError, fn ->
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
      ExternalService.start(@fuse_name, fuse_strategy: {:standard, @fuse_retries, 10_000})
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

    test "calls function again when it raises a RuntimeError" do
      ExternalService.call(@fuse_name, @retry_opts, fn ->
        Process.put(@fuse_name, Process.get(@fuse_name) + 1)
        raise "KABOOM!"
      end)

      assert Process.get(@fuse_name) == @fuse_retries + 1
    end

    test "calls function again when it raises an exception in the rescue_only list" do
      retry_opts = %{@retry_opts | rescue_only: [ArithmeticError, ArgumentError]}

      ExternalService.call(@fuse_name, retry_opts, fn ->
        Process.put(@fuse_name, Process.get(@fuse_name) + 1)
        raise ArgumentError, message: "KABOOM!"
      end)

      assert Process.get(@fuse_name) == @fuse_retries + 1
    end

    test "does not call function again when it raises an exception not in the rescue_only list" do
      retry_opts = %{@retry_opts | rescue_only: [SystemLimitError, File.Error]}

      assert_raise(RuntimeError, fn ->
        ExternalService.call(@fuse_name, retry_opts, fn ->
          Process.put(@fuse_name, Process.get(@fuse_name) + 1)
          raise "KABOOM!"
        end)
      end)

      assert Process.get(@fuse_name) == 1
    end

    test "returns fuse_blown when the fuse is blown by retries" do
      res =
        ExternalService.call(@fuse_name, @retry_opts, fn ->
          :retry
        end)

      assert res == {:error, {:fuse_blown, @fuse_name}}
    end

    test "returns fuse_blown when the fuse is blown by exceptions" do
      res =
        ExternalService.call(@fuse_name, @retry_opts, fn ->
          raise "KABOOM!"
        end)

      assert res == {:error, {:fuse_blown, @fuse_name}}
    end

    test "returns :error when retries are exhausted with :retry" do
      res =
        ExternalService.call(@fuse_name, @expiring_retry_options, fn ->
          :retry
        end)

      assert res == {:error, {:retries_exhausted, :reason_unknown}}
    end

    test "returns :error when retries are exhausted with a reason" do
      res =
        ExternalService.call(@fuse_name, @expiring_retry_options, fn ->
          {:retry, "reason"}
        end)

      assert res == {:error, {:retries_exhausted, "reason"}}
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
        rate_limit: {5, :timer.minutes(1)},
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

  describe "call!" do
    @fuse_retries 5

    setup do
      Process.put(@fuse_name, 0)
      ExternalService.start(@fuse_name, fuse_strategy: {:standard, @fuse_retries, 10_000})
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
        ExternalService.FuseBlownError -> :ok
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

    test "calls function again when it raises an exception" do
      try do
        ExternalService.call!(@fuse_name, @retry_opts, fn ->
          Process.put(@fuse_name, Process.get(@fuse_name) + 1)
          raise "KABOOM!"
        end)
      rescue
        ExternalService.FuseBlownError -> :ok
      end

      assert Process.get(@fuse_name) == @fuse_retries + 1
    end

    test "raises FuseBlownError when the fuse is blown by retries" do
      assert_raise ExternalService.FuseBlownError, inspect(@fuse_name), fn ->
        ExternalService.call!(@fuse_name, @retry_opts, fn -> :retry end)
      end
    end

    test "raises FuseBlownError when the fuse is blown by exceptions" do
      assert_raise ExternalService.FuseBlownError, inspect(@fuse_name), fn ->
        ExternalService.call!(@fuse_name, @retry_opts, fn -> raise "KABOOM!" end)
      end
    end

    test "raises RetriesExhaustedError when retries are exhausted with :retry" do
      assert_raise ExternalService.RetriesExhaustedError, fn ->
        ExternalService.call!(@fuse_name, @expiring_retry_options, fn -> :retry end)
      end
    end

    test "raises RetriesExhaustedError when retries are exhausted with a reason" do
      assert_raise ExternalService.RetriesExhaustedError, fn ->
        ExternalService.call!(@fuse_name, @expiring_retry_options, fn -> {:retry, "reason"} end)
      end
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
      ExternalService.start(@fuse_name, fuse_strategy: {:standard, @fuse_retries, 10_000})
    end

    test "returns a Task" do
      task = ExternalService.call_async(@fuse_name, fn -> :ok end)
      assert Task.await(task) == :ok
    end
  end

  describe "call_async_stream" do
    setup do
      ExternalService.start(@fuse_name, fuse_strategy: {:standard, @fuse_retries, 10_000})
    end

    def function(:raise), do: raise("KABOOM!")
    def function(arg), do: arg

    @enumerable [42, :ok, :retry, :error, {:error, :reason}, :raise]

    test "with no options" do
      results =
        @enumerable
        |> ExternalService.call_async_stream(@fuse_name, &function/1)
        |> Enum.to_list()

      assert [
               {:ok, _},
               {:ok, _},
               {:ok, {:error, {:fuse_blown, :"test-fuse"}}},
               {:ok, _},
               {:ok, _},
               {:ok, {:error, {:fuse_blown, :"test-fuse"}}}
             ] = results
    end

    test "with retry options" do
      results =
        @enumerable
        |> ExternalService.call_async_stream(@fuse_name, @retry_opts, &function/1)
        |> Enum.to_list()

      assert [
               {:ok, _},
               {:ok, _},
               {:ok, {:error, {:fuse_blown, :"test-fuse"}}},
               {:ok, _},
               {:ok, _},
               {:ok, {:error, {:fuse_blown, :"test-fuse"}}}
             ] = results
    end

    @async_opts [max_concurrency: 100, timeout: 10_000]

    test "with async options" do
      results =
        @enumerable
        |> ExternalService.call_async_stream(@fuse_name, @async_opts, &function/1)
        |> Enum.to_list()

      assert [
               {:ok, _},
               {:ok, _},
               {:ok, {:error, {:fuse_blown, :"test-fuse"}}},
               {:ok, _},
               {:ok, _},
               {:ok, {:error, {:fuse_blown, :"test-fuse"}}}
             ] = results
    end

    test "with retry and async options" do
      results =
        @enumerable
        |> ExternalService.call_async_stream(@fuse_name, @retry_opts, @async_opts, &function/1)
        |> Enum.to_list()

      assert [
               {:ok, _},
               {:ok, _},
               {:ok, {:error, {:fuse_blown, :"test-fuse"}}},
               {:ok, _},
               {:ok, _},
               {:ok, {:error, {:fuse_blown, :"test-fuse"}}}
             ] = results
    end
  end

  describe "start/stop lifecycle" do
    test "stop removes both the fuse and the persisted state" do
      name = :"lifecycle-test"

      assert :ok = ExternalService.start(name)
      assert :fuse.ask(name, :sync) == :ok
      assert %ExternalService.State{fuse_name: ^name} = ExternalService.State.get(name)

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

      assert :ok = ExternalService.start(name, fuse_strategy: {:fault_injection, 0.5, 5, 1_000})
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

  describe "introspection" do
    setup do
      name = :"introspection-test"
      ExternalService.start(name, fuse_strategy: {:standard, 1, 10_000})
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
      ExternalService.start(other, fuse_strategy: {:standard, 1, 10_000})
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
      retry_opts = %RetryOptions{backoff: {:linear, 0, 1}, rescue_only: [ArgumentError]}

      assert_raise RuntimeError, fn ->
        ExternalService.call(name, retry_opts, fn -> raise "boom" end)
      end

      assert_received {:telemetry, [:external_service, :call, :exception], %{duration: _},
                       %{service: ^name, kind: :error, reason: %RuntimeError{}}}
    end

    test "emits a circuit_breaker blown event when the breaker is open" do
      name = start_fuse(:"telemetry-blown", fuse_strategy: {:standard, 1, 10_000})
      blow_fuse(name)
      ExternalService.call(name, fn -> :ok end)

      assert_received {:telemetry, [:external_service, :circuit_breaker, :blown], %{count: 1},
                       %{service: ^name}}
    end

    test "emits a rate_limit sleep event when throttled" do
      name = :"telemetry-rate-limit"
      bucket = ExternalService.RateLimit.bucket_name(name)
      sleep = fn _time -> ExRated.delete_bucket(bucket) end
      ExternalService.start(name, rate_limit: {1, :timer.minutes(1)}, sleep_function: sleep)
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
    ExternalService.call(name, %RetryOptions{backoff: {:linear, 0, 1}}, fn -> :retry end)
  end

  # Starts a service with a high failure tolerance (so it won't blow) unless
  # overridden, registers cleanup, and returns its name.
  defp start_fuse(name, options \\ [fuse_strategy: {:standard, 100, 10_000}]) do
    ExternalService.start(name, options)
    on_exit(fn -> ExternalService.stop(name) end)
    name
  end
end
