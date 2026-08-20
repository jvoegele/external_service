defmodule ExternalService.ConcurrencyPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ExternalService.Concurrency
  alias ExternalService.ServiceSaturated

  # The other sequence property, and the one with real processes in it: callers
  # are started and finished in a generated order, overlapping each other, with a
  # model of which of them should be holding a slot at every point.
  #
  # A concurrency limit has exactly one promise — never more than `:limit` calls in
  # flight — and it is a promise about interleavings. A configuration grid cannot
  # express "start three, finish the second, start two more"; this can, and
  # StreamData shrinks a violation to the shortest ordering that still produces it.
  #
  # `reclaim_after` is set far beyond any run, so a slot is only ever freed by its
  # caller finishing. A reclaimed slot mid-property would be the library working as
  # designed and the model being wrong about it.
  @reclaim_after :timer.minutes(1)
  @limits 1..4

  setup_all do
    services =
      Map.new(@limits, fn limit ->
        service = :"concurrency_property_#{limit}"

        :ok =
          ExternalService.start(service,
            concurrency: [limit: limit, reclaim_after: @reclaim_after, wait: false],
            retry: [max_attempts: 1]
          )

        {limit, service}
      end)

    on_exit(fn ->
      Enum.each(services, fn {_limit, service} -> ExternalService.stop(service) end)
    end)

    {:ok, services: services}
  end

  property "no more calls are ever in flight than the limit allows", %{services: services} do
    check all(
            limit <- member_of(Enum.to_list(@limits)),
            operations <- list_of(operation(), min_length: 1, max_length: 12),
            max_runs: 40
          ) do
      service = Map.fetch!(services, limit)
      Concurrency.reset(service)

      held =
        Enum.reduce(operations, [], fn operation, held ->
          held = apply_operation(service, operation, held, limit)

          assert Concurrency.in_flight(service) == length(held),
                 "expected #{length(held)} calls in flight, service reported " <>
                   "#{Concurrency.in_flight(service)}"

          assert length(held) <= limit, "more calls in flight than the limit allows"

          held
        end)

      # Every slot comes back. A caller that finishes and does not release its slot
      # leaks one, which no single-operation assertion would notice.
      Enum.each(held, &finish/1)
      assert Concurrency.in_flight(service) == 0
    end
  end

  defp operation do
    one_of([constant(:start), tuple({constant(:finish), integer(0..11)})])
  end

  defp apply_operation(service, :start, held, limit) when length(held) < limit do
    # A slot is free, so this caller must get it.
    held ++ [start_caller(service, :admitted)]
  end

  defp apply_operation(service, :start, held, _limit) do
    # No slot is free, and `wait: false` means shed rather than queue.
    :shed = start_caller(service, :shed)
    held
  end

  defp apply_operation(_service, {:finish, _index}, [], _limit), do: []

  defp apply_operation(_service, {:finish, index}, held, _limit) do
    caller = Enum.at(held, rem(index, length(held)))
    finish(caller)
    List.delete(held, caller)
  end

  # The model predicts the outcome, so each branch waits for the thing it expects
  # rather than racing to discover which happened. Both are immediate when the
  # prediction holds; only a violated property pays a timeout, which is the right
  # way round.
  defp start_caller(service, expectation) do
    test = self()
    reference = make_ref()

    task =
      Task.async(fn ->
        ExternalService.call(service, fn ->
          send(test, {:admitted, reference})

          receive do
            :finish -> :done
          end
        end)
      end)

    case expectation do
      :admitted ->
        assert_receive {:admitted, ^reference}, 1_000, "a call was shed with a slot free"
        task

      :shed ->
        case Task.yield(task, 1_000) do
          {:ok, {:error, %ServiceSaturated{}}} ->
            :shed

          nil ->
            # Still running, so it was admitted — which is the violation this
            # property exists to catch. Release it before failing, so the failure
            # is the assertion rather than a leaked process.
            finish(task)
            flunk("a call was admitted with every slot held")

          {:ok, other} ->
            flunk("expected the call to be shed, got #{inspect(other)}")
        end
    end
  end

  defp finish(task) do
    send(task.pid, :finish)
    assert Task.await(task, 1_000) == :done
  end
end
