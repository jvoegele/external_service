defmodule ExternalService.CircuitBreaker.ClusterDistributedTest do
  @moduledoc """
  Exercises the cluster circuit breaker across two genuinely separate nodes.

  The rest of the suite covers the halves of the mechanism in isolation; this
  covers the claim the feature actually makes — that tripping a breaker on one
  node trips it on another.

  Tagged `:distributed`, so a machine where starting a distributed node is not
  possible can skip it with `mix test --exclude distributed`.
  """

  use ExUnit.Case

  alias ExternalService.CircuitBreaker.Cluster
  alias ExternalService.CircuitBreakerOpen
  alias ExternalService.Test.ClusterHelper

  @moduletag :distributed
  @moduletag capture_log: true
  # Booting a second BEAM is slow relative to everything else in the suite.
  @moduletag timeout: 120_000

  @cookie :external_service_test
  @breaker [tolerate: 2, within: 10_000, reset: 60_000, backend: Cluster]

  setup_all do
    start_distribution!()

    # `:peer.start/1` rather than `start_link/1`: linking would tie the peer's
    # control process to the transient `setup_all` process, which exits as soon
    # as this callback returns, taking the peer down before any test runs.
    {:ok, peer, peer_node} =
      :peer.start(%{
        name: :external_service_peer,
        host: ~c"127.0.0.1",
        longnames: true,
        args: [~c"-setcookie", ~c"#{@cookie}"]
      })

    # The peer boots with a bare code path, so it needs this project's build
    # directories and the applications the library depends on. Note that
    # `:peer.call/4` only works over an alternative connection; everything here
    # goes over ordinary distribution, so it uses `:erpc`.
    :ok = :erpc.call(peer_node, :code, :add_paths, [:code.get_path()])
    {:ok, _apps} = :erpc.call(peer_node, :application, :ensure_all_started, [:external_service])

    on_exit(fn -> :peer.stop(peer) end)

    %{peer: peer, peer_node: peer_node}
  end

  setup %{peer_node: peer_node} do
    assert peer_node in Node.list(), "the peer node should be connected"

    service = :"distributed_#{System.unique_integer([:positive])}"
    :ok = ExternalService.start(service, circuit_breaker: @breaker)
    :ok = :erpc.call(peer_node, ExternalService, :start, [service, [circuit_breaker: @breaker]])

    on_exit(fn ->
      ExternalService.stop(service)
      :erpc.call(peer_node, ExternalService, :stop, [service])
    end)

    %{service: service}
  end

  test "a breaker tripped on this node trips on the peer", ctx do
    %{peer_node: peer_node, service: service} = ctx

    assert ExternalService.available?(service)
    assert peer_available?(peer_node, service)

    assert {:error, %CircuitBreakerOpen{}} = ClusterHelper.trip(service)
    assert ExternalService.blown?(service)

    # The multicast is fire-and-forget, so the peer converges rather than
    # flipping in lockstep.
    assert eventually(fn -> peer_blown?(peer_node, service) end),
           "the peer node's breaker should have opened"
  end

  test "a breaker tripped on the peer trips on this node", ctx do
    %{peer_node: peer_node, service: service} = ctx

    assert {:error, %CircuitBreakerOpen{}} =
             :erpc.call(peer_node, ClusterHelper, :trip, [service])

    assert peer_blown?(peer_node, service)

    assert eventually(fn -> ExternalService.blown?(service) end),
           "this node's breaker should have opened"
  end

  test "an explicit reset on one node closes the breaker on the other", ctx do
    %{peer_node: peer_node, service: service} = ctx

    assert {:error, %CircuitBreakerOpen{}} = ClusterHelper.trip(service)
    assert eventually(fn -> peer_blown?(peer_node, service) end)

    assert ExternalService.reset(service) == :ok

    assert eventually(fn -> peer_available?(peer_node, service) end),
           "the peer node's breaker should have closed"
  end

  test "a trip does not echo back and forth between the nodes", ctx do
    %{peer_node: peer_node, service: service} = ctx

    assert {:error, %CircuitBreakerOpen{}} = ClusterHelper.trip(service)
    assert eventually(fn -> peer_blown?(peer_node, service) end)

    # If the peer re-broadcast what it received, the two nodes would keep
    # tripping each other and a reset could never settle. Resetting and finding
    # both still closed a moment later shows the propagation terminates.
    assert ExternalService.reset(service) == :ok
    assert eventually(fn -> peer_available?(peer_node, service) end)

    Process.sleep(100)

    assert ExternalService.available?(service)
    assert peer_available?(peer_node, service)
  end

  test "a node not running the service ignores a peer's trip", ctx do
    %{peer_node: peer_node} = ctx

    unknown = :"never_started_#{System.unique_integer([:positive])}"

    # Delivered for real over distribution; the peer has no such service, so it
    # must simply do nothing rather than crash the erpc worker.
    assert :ok = :erpc.call(peer_node, Cluster, :remote_trip, [unknown])
  end

  defp peer_blown?(peer_node, service),
    do: :erpc.call(peer_node, ExternalService, :blown?, [service])

  defp peer_available?(peer_node, service),
    do: :erpc.call(peer_node, ExternalService, :available?, [service])

  defp start_distribution! do
    case :net_kernel.start(:"external_service_primary@127.0.0.1", %{name_domain: :longnames}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> flunk("could not start distribution: #{inspect(reason)}")
    end

    :erlang.set_cookie(node(), @cookie)
  end

  # Propagation is asynchronous, so assertions poll rather than assuming the
  # remote node has already caught up.
  defp eventually(fun, remaining \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, remaining) do
    if fun.() do
      true
    else
      Process.sleep(20)
      eventually(fun, remaining - 1)
    end
  end
end
