defmodule ExternalServiceTest do
  use ExUnit.Case
  alias ExternalService
  alias ExternalService.RetryOptions

  @fuse_name :"test-fuse"

  @retry_opts %RetryOptions{
    backoff: {:linear, 0, 1}
  }

  @expiring_retry_options %RetryOptions{
    backoff: {:linear, 1, 1},
    expiry: 1
  }

  describe "start" do
    test "installs a fuse" do
      ExternalService.start(@fuse_name)
      assert :ok = :fuse.ask(@fuse_name, :sync)
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

      assert 1 = Process.get(@fuse_name)
    end

    test "calls function again when it returns retry" do
      ExternalService.call(@fuse_name, @retry_opts, fn ->
        Process.put(@fuse_name, Process.get(@fuse_name) + 1)
        :retry
      end)

      assert @fuse_retries + 1 == Process.get(@fuse_name)
    end

    test "stops retrying on success" do
      ExternalService.call(@fuse_name, @retry_opts, fn ->
        Process.put(@fuse_name, Process.get(@fuse_name) + 1)

        case Process.get(@fuse_name) do
          1 -> :retry
          _ -> :ok
        end
      end)

      assert 2 == Process.get(@fuse_name)
    end

    test "calls function again when it raises an exception" do
      ExternalService.call(@fuse_name, @retry_opts, fn ->
        Process.put(@fuse_name, Process.get(@fuse_name) + 1)
        raise "KABOOM!"
      end)

      assert @fuse_retries + 1 == Process.get(@fuse_name)
    end

    test "returns fuse_blown when the fuse is blown by retries" do
      res =
        ExternalService.call(@fuse_name, @retry_opts, fn ->
          :retry
        end)

      assert {:error, {:fuse_blown, @fuse_name}} = res
    end

    test "returns fuse_blown when the fuse is blown by exceptions" do
      res =
        ExternalService.call(@fuse_name, @retry_opts, fn ->
          raise "KABOOM!"
        end)

      assert {:error, {:fuse_blown, @fuse_name}} = res
    end

    test "returns :error when retries are exhausted with :retry" do
      res =
        ExternalService.call(@fuse_name, @expiring_retry_options, fn ->
          :retry
        end)

      assert {:error, {:retries_exhausted, :reason_unknown}} = res
    end

    test "returns :error when retries are exhausted with a reason" do
      res =
        ExternalService.call(@fuse_name, @expiring_retry_options, fn ->
          {:retry, "reason"}
        end)

      assert {:error, {:retries_exhausted, "reason"}} = res
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

      assert {:error, "reason"} = res
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

      assert 1 = Process.get(@fuse_name)
    end

    test "calls function again when it returns retry" do
      try do
        ExternalService.call!(@fuse_name, @retry_opts, fn ->
          Process.put(@fuse_name, Process.get(@fuse_name) + 1)
          :retry
        end)
      rescue
        ExternalService.FuseBlown -> :ok
      end

      assert @fuse_retries + 1 == Process.get(@fuse_name)
    end

    test "stops retrying on success" do
      ExternalService.call!(@fuse_name, @retry_opts, fn ->
        Process.put(@fuse_name, Process.get(@fuse_name) + 1)

        case Process.get(@fuse_name) do
          1 -> :retry
          _ -> :ok
        end
      end)

      assert 2 == Process.get(@fuse_name)
    end

    test "calls function again when it raises an exception" do
      try do
        ExternalService.call!(@fuse_name, @retry_opts, fn ->
          Process.put(@fuse_name, Process.get(@fuse_name) + 1)
          raise "KABOOM!"
        end)
      rescue
        ExternalService.FuseBlown -> :ok
      end

      assert @fuse_retries + 1 == Process.get(@fuse_name)
    end

    test "raises FuseBlown when the fuse is blown by retries" do
      assert_raise ExternalService.FuseBlown, Atom.to_string(@fuse_name), fn ->
        ExternalService.call!(@fuse_name, @retry_opts, fn -> :retry end)
      end
    end

    test "raises FuseBlown when the fuse is blown by exceptions" do
      assert_raise ExternalService.FuseBlown, Atom.to_string(@fuse_name), fn ->
        ExternalService.call!(@fuse_name, @retry_opts, fn -> raise "KABOOM!" end)
      end
    end

    test "raises RetriesExhausted when retries are exhausted with :retry" do
      assert_raise ExternalService.RetriesExhausted, fn ->
        ExternalService.call!(@fuse_name, @expiring_retry_options, fn -> :retry end)
      end
    end

    test "raises RetriesExhausted when retries are exhausted with a reason" do
      assert_raise ExternalService.RetriesExhausted, fn ->
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

      assert {:error, "reason"} = res
    end
  end

  describe "call_async" do
    setup do
      ExternalService.start(@fuse_name, fuse_strategy: {:standard, @fuse_retries, 10_000})
    end

    test "returns a Task" do
      task = ExternalService.call_async(@fuse_name, fn -> :ok end)
      assert :ok = Task.await(task)
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
end
