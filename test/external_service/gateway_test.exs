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
      {:ok, pid} = TestGateway.start_link(
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
end
