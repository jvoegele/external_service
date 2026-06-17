defmodule ExternalService.GatewayTest do
  use ExUnit.Case

  defmodule TestGateway do
    use ExternalService.Gateway,
      fuse: [
        name: SomeService,
        strategy: {:standard, 5, 10_000},
        refresh: 5_000
      ],
      rate_limit: {5, :timer.seconds(1)},
      retry: [
        backoff: {:linear, 100, 1},
        expiry: 5_000
      ]

    def get_foo(foo_id) do
      external_call(fn ->
        %{foo: foo_id}
      end)
    end
  end

  defmodule ConfiguredGateway do
    use ExternalService.Gateway,
      fuse: [name: :configured_gateway_fuse, strategy: {:standard, 3, 7_000}, refresh: 4_321]
  end

  defmodule IntrospectionGateway do
    use ExternalService.Gateway,
      fuse: [name: :introspection_gateway_fuse, strategy: {:standard, 1, 10_000}],
      retry: [backoff: :linear, base: 0]
  end

  describe "child_spec" do
    test "generates a child spec for starting under a supervisor" do
      assert %{id: TestGateway, type: :worker, start: start_tuple} =
               TestGateway.child_spec(foo: :bar)

      assert start_tuple == {TestGateway, :start_link, [[foo: :bar]]}
    end
  end

  describe "start_link" do
    test "starts gateway process with configuration" do
      {:ok, pid} = TestGateway.start_link([])
      assert is_pid(pid)

      assert TestGateway.gateway_config() == [
               fuse: [
                 name: SomeService,
                 strategy: {:standard, 5, 10_000},
                 refresh: 5_000
               ],
               rate_limit: {5, :timer.seconds(1)},
               retry: [
                 backoff: {:linear, 100, 1},
                 expiry: 5_000
               ]
             ]
    end

    test "merges gateway configuration with start options" do
      {:ok, pid} =
        TestGateway.start_link(
          fuse: [
            refresh: 999
          ],
          rate_limit: {9, 999},
          retry: [
            expiry: 999
          ]
        )

      assert is_pid(pid)

      assert TestGateway.gateway_config() == [
               fuse: [
                 name: SomeService,
                 strategy: {:standard, 5, 10_000},
                 refresh: 999
               ],
               rate_limit: {9, 999},
               retry: [
                 backoff: {:linear, 100, 1},
                 expiry: 999
               ]
             ]
    end

    test "can be restarted by supervisor" do
      {:ok, pid} = start_supervised({TestGateway, [rate_limit: {9, 999}]})
      assert Process.whereis(Module.concat(TestGateway, Config)) == pid
      assert TestGateway.gateway_config()[:rate_limit] == {9, 999}

      Process.exit(pid, :testing_restart)
      refute Process.alive?(pid)
      refute Process.whereis(Module.concat(TestGateway, Config)) == pid

      # Give the supervisor a little time to restart the process
      Process.sleep(50)
      assert TestGateway.gateway_config()[:rate_limit] == {9, 999}
    end
  end

  describe "fuse configuration (regression for gateway fuse-config drop)" do
    test "applies the gateway's configured fuse strategy and refresh" do
      {:ok, _pid} = ConfiguredGateway.start_link([])

      fuse = installed_fuse(:configured_gateway_fuse)

      # The fuse server stores each fuse as the record
      # {:fuse, name, intensity, period, heal_time, ...} (fuse 2.5). Previously
      # the gateway's strategy/refresh were dropped and every gateway installed
      # the default {:standard, 10, 10_000}/60_000 fuse.
      assert elem(fuse, 2) == 3, "expected configured intensity (max melts), got #{inspect(fuse)}"
      assert elem(fuse, 4) == 4_321, "expected configured refresh, got #{inspect(fuse)}"
    end
  end

  describe "introspection" do
    test "available?/blown? reflect the gateway's circuit breaker state" do
      {:ok, _pid} = IntrospectionGateway.start_link([])

      assert IntrospectionGateway.available?()
      refute IntrospectionGateway.blown?()

      # Drive the fuse past its tolerance of 1 melt so the breaker trips.
      IntrospectionGateway.external_call(fn -> :retry end)

      assert IntrospectionGateway.blown?()
      refute IntrospectionGateway.available?()
    end
  end

  # Reads the installed fuse record straight out of the :fuse_server state. This
  # is the only way to assert on the circuit-breaker config that was actually
  # installed (fuse exposes no public accessor for it).
  defp installed_fuse(name) do
    :fuse_server
    |> :sys.get_state()
    |> elem(1)
    |> Enum.find(fn fuse -> elem(fuse, 1) == name end)
  end
end
