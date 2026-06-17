defmodule ExternalService.FrontDoorTest do
  use ExUnit.Case

  alias ExternalService.CircuitBreakerOpen
  alias ExternalService.RetriesExhausted

  @moduletag capture_log: true

  defmodule Service do
    use ExternalService,
      name: :front_door_service,
      circuit_breaker: [tolerate: 3, within: 10_000, reset: 4_321],
      rate_limit: [limit: 100, per: 1_000],
      retry: [backoff: :linear, base: 0, max_attempts: 2]
  end

  describe "child_spec/1" do
    test "generates a child spec for starting under a supervisor" do
      assert %{id: Service, type: :worker, start: {Service, :start_link, [[]]}} =
               Service.child_spec([])
    end
  end

  describe "start_link/1" do
    test "installs the configured circuit breaker" do
      start_supervised!(Service)

      fuse = installed_fuse(:front_door_service)
      assert elem(fuse, 2) == 3, "expected configured tolerate, got #{inspect(fuse)}"
      assert elem(fuse, 4) == 4_321, "expected configured reset, got #{inspect(fuse)}"
    end

    test "deep merges overrides with the options given to use" do
      start_supervised!({Service, circuit_breaker: [tolerate: 1]})

      fuse = installed_fuse(:front_door_service)
      # Overridden tolerate, but the un-overridden reset is preserved.
      assert elem(fuse, 2) == 1
      assert elem(fuse, 4) == 4_321
    end
  end

  describe "generated call functions" do
    setup do
      start_supervised!(Service)
      :ok
    end

    test "call/1 succeeds and returns the function result" do
      assert Service.call(fn -> {:ok, 42} end) == {:ok, 42}
    end

    test "call/1 uses the service's configured retry default (max_attempts: 2)" do
      Process.put(:count, 0)

      result =
        Service.call(fn ->
          Process.put(:count, Process.get(:count) + 1)
          :retry
        end)

      assert Process.get(:count) == 2
      assert {:error, %RetriesExhausted{}} = result
    end

    test "call/2 overrides the retry options" do
      Process.put(:count, 0)

      Service.call([backoff: :linear, base: 0, max_attempts: 1], fn ->
        Process.put(:count, Process.get(:count) + 1)
        :retry
      end)

      assert Process.get(:count) == 1
    end

    test "call!/1 raises on failure" do
      assert_raise RetriesExhausted, fn -> Service.call!(fn -> :retry end) end
    end

    test "call_async/1 returns a Task" do
      task = Service.call_async(fn -> :ok end)
      assert Task.await(task) == :ok
    end

    test "call_async_stream/2 maps over an enumerable" do
      results = [1, 2, 3] |> Service.call_async_stream(&{:ok, &1}) |> Enum.to_list()
      assert results == [ok: {:ok, 1}, ok: {:ok, 2}, ok: {:ok, 3}]
    end

    test "available?/blown?/reset reflect and control circuit breaker state" do
      assert Service.available?()
      refute Service.blown?()

      # No max_attempts so the breaker is driven past its tolerance of 3.
      Service.call([backoff: :linear, base: 0], fn -> :retry end)

      assert Service.blown?()
      refute Service.available?()
      assert {:error, %CircuitBreakerOpen{}} = Service.call(fn -> :ok end)

      assert Service.reset() == :ok
      assert Service.available?()
    end
  end

  describe "deprecated ExternalService.Gateway" do
    defmodule LegacyGateway do
      use ExternalService.Gateway,
        name: :legacy_gateway,
        circuit_breaker: [tolerate: 5, within: 10_000]
    end

    test "external_call/1 delegates to call/1" do
      start_supervised!(LegacyGateway)
      assert LegacyGateway.external_call(fn -> :ok end) == :ok
      assert LegacyGateway.available?()
    end
  end

  # Reads the installed fuse record straight out of the :fuse_server state. This
  # is the only way to assert on the circuit-breaker config that was actually
  # installed (fuse exposes no public accessor for it). The record is
  # {:fuse, name, tolerate, period, reset, ...}.
  defp installed_fuse(name) do
    :fuse_server
    |> :sys.get_state()
    |> elem(1)
    |> Enum.find(fn fuse -> elem(fuse, 1) == name end)
  end
end
