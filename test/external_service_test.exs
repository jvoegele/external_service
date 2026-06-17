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
end
