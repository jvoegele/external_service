defmodule ExternalService.CircuitBreaker.ClusterTest do
  @moduledoc """
  Covers the cluster-aware circuit breaker: that a local trip is broadcast (and
  only a trip, once), that the receiving half trips this node's own breaker, and
  — in `ClusterDistributedTest` — that two real nodes actually converge.
  """

  use ExUnit.Case

  alias ExternalService.CircuitBreaker.Cluster

  @moduletag capture_log: true

  setup do
    Process.put(:broadcast_targets, [])
    :ok
  end

  # Records every time the backend asks which nodes to notify, and reports no
  # nodes so that nothing is actually sent. This isolates the decision to
  # broadcast from the delivery of the broadcast.
  defp recording_nodes do
    fn ->
      Process.put(:broadcast_targets, [:asked | Process.get(:broadcast_targets, [])])
      []
    end
  end

  defp broadcast_count, do: length(Process.get(:broadcast_targets, []))

  defp start_clustered(service, options \\ []) do
    options =
      Keyword.merge(
        [tolerate: 2, within: 10_000, reset: 60_000, nodes: recording_nodes()],
        options
      )

    :ok = ExternalService.start(service, circuit_breaker: [backend: {Cluster, options}])
    on_exit(fn -> ExternalService.stop(service) end)
    service
  end

  defp unique_service, do: :"cluster_test_#{System.unique_integer([:positive])}"

  describe "install/2" do
    test "defaults to broadcasting to every connected node" do
      service = unique_service()
      :ok = ExternalService.start(service, circuit_breaker: [backend: Cluster])
      on_exit(fn -> ExternalService.stop(service) end)

      assert {Cluster, config} = ExternalService.State.get(service).circuit_breaker
      assert config.nodes == (&Node.list/0)
      assert config.tolerate == 10
    end

    test "records this node's own tolerance so a peer trip melts far enough" do
      service = start_clustered(unique_service(), tolerate: 7)

      assert {Cluster, %{tolerate: 7}} = ExternalService.State.get(service).circuit_breaker
    end

    test "rejects a :nodes option that is neither a list nor a zero-arity function" do
      assert_raise ArgumentError, ~r/expects :nodes to be/, fn ->
        ExternalService.start(unique_service(),
          circuit_breaker: [backend: {Cluster, nodes: :everywhere}]
        )
      end
    end
  end

  describe "broadcasting a trip" do
    test "broadcasts once, only when the breaker actually opens" do
      service = start_clustered(unique_service())
      {Cluster, config} = ExternalService.State.get(service).circuit_breaker

      # Tolerating 2 failures means the breaker survives two melts and opens on
      # the third; only that third melt should broadcast.
      Cluster.melt(service, config)
      assert broadcast_count() == 0

      Cluster.melt(service, config)
      assert broadcast_count() == 0

      Cluster.melt(service, config)
      assert broadcast_count() == 1
    end

    test "does not broadcast again for melts that arrive while already open" do
      service = start_clustered(unique_service())
      {Cluster, config} = ExternalService.State.get(service).circuit_breaker

      Enum.each(1..3, fn _ -> Cluster.melt(service, config) end)
      assert broadcast_count() == 1

      Enum.each(1..5, fn _ -> Cluster.melt(service, config) end)
      assert broadcast_count() == 1
    end

    test "broadcasts an explicit reset" do
      service = start_clustered(unique_service())
      {Cluster, config} = ExternalService.State.get(service).circuit_breaker

      assert Cluster.reset(service, config) == :ok
      assert broadcast_count() == 1
    end

    test "tripping through a guarded call broadcasts" do
      service = start_clustered(unique_service())

      # `tolerate: 2` with the default `melt: :per_call`: a failing call charges
      # the breaker once, when its retrying gives up, so it takes three of them.
      # The call that opens the breaker still reports its own failure — only the
      # next one is rejected.
      for _ <- 1..3 do
        assert {:error, %ExternalService.RetriesExhausted{}} =
                 ExternalService.call(service, [base: 1, max_attempts: 5], fn -> :retry end)
      end

      assert {:error, %ExternalService.CircuitBreakerOpen{}} =
               ExternalService.call(service, [base: 1, max_attempts: 5], fn -> :retry end)

      # Still one broadcast: only the closed-to-open transition is sent.
      assert broadcast_count() == 1
      assert ExternalService.blown?(service)
    end
  end

  describe "receiving a peer's trip" do
    test "remote_trip/1 opens this node's breaker" do
      service = start_clustered(unique_service(), tolerate: 5)

      assert ExternalService.available?(service)
      assert Cluster.remote_trip(service) == :ok
      assert ExternalService.blown?(service)
    end

    test "remote_trip/1 does not broadcast onward, so trips cannot echo" do
      service = start_clustered(unique_service())

      assert Cluster.remote_trip(service) == :ok
      assert broadcast_count() == 0
    end

    test "remote_reset/1 closes this node's breaker" do
      service = start_clustered(unique_service())

      assert Cluster.remote_trip(service) == :ok
      assert ExternalService.blown?(service)

      assert Cluster.remote_reset(service) == :ok
      assert ExternalService.available?(service)
    end

    test "a trip for a service this node does not run is ignored" do
      assert Cluster.remote_trip(:never_started_anywhere) == :ok
      assert Cluster.remote_reset(:never_started_anywhere) == :ok
    end

    test "a trip for a service using a different backend is ignored" do
      service = unique_service()
      :ok = ExternalService.start(service, circuit_breaker: [tolerate: 1])
      on_exit(fn -> ExternalService.stop(service) end)

      assert Cluster.remote_trip(service) == :ok
      # The default backend's breaker is untouched: this node is not part of the
      # cluster for that service.
      assert ExternalService.available?(service)
    end
  end

  describe "broadcast delivery" do
    test "a trip delivered to this node through :erpc opens the breaker" do
      # Pointing :nodes at this node exercises the real erpc.multicast path --
      # send, dispatch, and receive -- without needing a second node.
      service = unique_service()

      :ok =
        ExternalService.start(service,
          circuit_breaker: [backend: {Cluster, tolerate: 3, nodes: [node()]}]
        )

      on_exit(fn -> ExternalService.stop(service) end)

      {Cluster, config} = ExternalService.State.get(service).circuit_breaker

      # A melt short of the tolerance broadcasts nothing, so the breaker is only
      # opened here by the delivered message, not by the melts themselves.
      assert Cluster.remote_trip(service) == :ok
      assert ExternalService.blown?(service)

      assert Cluster.remote_reset(service) == :ok
      assert ExternalService.available?(service)

      # Now trip it for real and let the broadcast come back around.
      Enum.each(0..3, fn _ -> Cluster.melt(service, config) end)
      assert ExternalService.blown?(service)
    end
  end
end
