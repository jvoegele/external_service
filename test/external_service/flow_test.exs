defmodule ExternalService.FlowTest do
  use ExUnit.Case

  alias ExternalService.RetriesExhausted

  @moduletag capture_log: true

  @service :flow_test_service

  setup do
    ExternalService.start(@service,
      circuit_breaker: [tolerate: 100, within: 10_000],
      retry: [backoff: :linear, base: 0]
    )

    on_exit(fn -> ExternalService.stop(@service) end)
    :ok
  end

  test "maps an enumerable source through guarded calls" do
    results =
      1..5
      |> ExternalService.Flow.map(@service, fn n -> {:ok, n * 2} end)
      |> Enum.to_list()
      # Flow is unordered, so sort before asserting.
      |> Enum.sort()

    assert results == [{:ok, 2}, {:ok, 4}, {:ok, 6}, {:ok, 8}, {:ok, 10}]
  end

  test "continues an existing Flow as a middle stage" do
    results =
      [1, 2, 3]
      |> Flow.from_enumerable()
      |> Flow.map(&(&1 * 10))
      |> ExternalService.Flow.map(@service, fn n -> {:ok, n} end)
      |> Enum.to_list()
      |> Enum.sort()

    assert results == [{:ok, 10}, {:ok, 20}, {:ok, 30}]
  end

  test "structured errors arrive as elements" do
    results =
      [1, 2, 3]
      |> ExternalService.Flow.map(
        @service,
        [backoff: :linear, base: 0, max_attempts: 2],
        fn _ -> :retry end
      )
      |> Enum.to_list()

    assert length(results) == 3

    assert Enum.all?(
             results,
             &match?({:error, %RetriesExhausted{context: %{service: @service}}}, &1)
           )
  end

  test "per-call retry options (including a retry_on predicate) thread through" do
    results =
      [:item]
      |> ExternalService.Flow.map(
        @service,
        [backoff: :linear, base: 0, max_attempts: 2, retry_on: &match?({:error, _}, &1)],
        fn _ -> {:error, :nope} end
      )
      |> Enum.to_list()

    assert [{:error, %RetriesExhausted{context: %{reason: {:error, :nope}}}}] = results
  end

  test "flow_opts are passed through to the source" do
    results =
      1..4
      |> ExternalService.Flow.map(@service, [], fn n -> {:ok, n} end, stages: 1, max_demand: 1)
      |> Enum.to_list()
      |> Enum.sort()

    assert results == [{:ok, 1}, {:ok, 2}, {:ok, 3}, {:ok, 4}]
  end
end
