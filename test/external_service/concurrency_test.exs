defmodule ExternalService.ConcurrencyTest do
  @moduledoc """
  Covers the per-service concurrency limit: that it never admits more than
  `:limit`, that slots come back on every in-process exit path, that a slot lost
  to a caller killed from outside is reclaimed rather than leaked forever, and
  that saturation is treated as our own backpressure rather than the service's
  failure.
  """

  use ExUnit.Case, async: true

  alias ExternalService.Concurrency
  alias ExternalService.RateLimited
  alias ExternalService.ServiceSaturated

  @moduletag capture_log: true

  setup context do
    service = :"#{context.module}.#{context.test}"
    on_exit(fn -> ExternalService.stop(service) end)
    {:ok, service: service}
  end

  defp start(service, options) do
    defaults = [circuit_breaker: [tolerate: :infinity], retry: [max_attempts: 1]]
    :ok = ExternalService.start(service, Keyword.merge(defaults, options))
    service
  end

  # Runs `count` calls concurrently, each blocking until released, and returns
  # the results once they have all finished.
  defp saturate(service, count) do
    test_process = self()

    blocking_call = fn ->
      send(test_process, {:in_call, self()})

      receive do
        :release -> :done
      after
        5_000 -> :timeout
      end
    end

    for _ <- 1..count do
      Task.async(fn -> ExternalService.call(service, blocking_call) end)
    end
  end

  defp await_in_call(n) do
    for _ <- 1..n do
      receive do
        {:in_call, pid} -> pid
      after
        2_000 -> flunk("a call never started")
      end
    end
  end

  describe "admission" do
    test "calls pass through while slots are free", %{service: service} do
      start(service, concurrency: [limit: 2, reclaim_after: :timer.seconds(30)])

      for n <- 1..50 do
        assert ExternalService.call(service, fn -> n end) == n
      end
    end

    test "rejects with ServiceSaturated once every slot is held", %{service: service} do
      start(service, concurrency: [limit: 2, reclaim_after: :timer.seconds(30)])

      tasks = saturate(service, 2)
      held = await_in_call(2)

      assert {:error, %ServiceSaturated{context: context}} =
               ExternalService.call(service, fn -> flunk("should not have run") end)

      assert context.service == service
      assert context.limit == 2
      assert context.in_flight == 2

      Enum.each(held, &send(&1, :release))
      assert Task.await_many(tasks) == [:done, :done]
    end

    test "call!/3 raises it", %{service: service} do
      start(service, concurrency: [limit: 1, reclaim_after: :timer.seconds(30)])

      tasks = saturate(service, 1)
      held = await_in_call(1)

      assert_raise ServiceSaturated, fn ->
        ExternalService.call!(service, fn -> flunk("should not have run") end)
      end

      Enum.each(held, &send(&1, :release))
      Task.await_many(tasks)
    end

    test "never admits more than the limit under contention", %{service: service} do
      limit = 8
      start(service, concurrency: [limit: limit, reclaim_after: :timer.seconds(30)])

      {:ok, gauge} = Agent.start_link(fn -> {0, 0} end)

      results =
        1..400
        |> Enum.map(fn _ ->
          Task.async(fn ->
            ExternalService.call(service, fn ->
              Agent.update(gauge, fn {cur, peak} -> {cur + 1, max(peak, cur + 1)} end)
              Process.sleep(2)
              Agent.update(gauge, fn {cur, peak} -> {cur - 1, peak} end)
              :ok
            end)
          end)
        end)
        |> Task.await_many(60_000)

      {_current, peak} = Agent.get(gauge, & &1)

      assert peak <= limit
      # Fail-fast, not queueing: with everything arriving at once most callers
      # are shed rather than waiting for a slot.
      assert Enum.any?(results, &match?({:error, %ServiceSaturated{}}, &1))
    end
  end

  describe "releasing slots" do
    test "a slot comes back when the call returns", %{service: service} do
      start(service, concurrency: [limit: 1, reclaim_after: :timer.seconds(30)])

      assert ExternalService.call(service, fn -> :ok end) == :ok
      assert Concurrency.in_flight(service) == 0
      refute ExternalService.saturated?(service)
    end

    test "a slot comes back when the call raises", %{service: service} do
      start(service, concurrency: [limit: 1, reclaim_after: :timer.seconds(30)])

      assert_raise RuntimeError, fn ->
        ExternalService.call(service, fn -> raise "boom" end)
      end

      assert Concurrency.in_flight(service) == 0
      assert ExternalService.call(service, fn -> :ok end) == :ok
    end

    test "a slot comes back when the call throws", %{service: service} do
      start(service, concurrency: [limit: 1, reclaim_after: :timer.seconds(30)])

      catch_throw(ExternalService.call(service, fn -> throw(:boom) end))

      assert Concurrency.in_flight(service) == 0
      assert ExternalService.call(service, fn -> :ok end) == :ok
    end

    test "a slot lost to a caller killed from outside is reclaimed", %{service: service} do
      start(service, concurrency: [limit: 1, reclaim_after: 100])

      test_process = self()

      pid =
        spawn(fn ->
          ExternalService.call(service, fn ->
            send(test_process, :in_call)
            Process.sleep(:infinity)
          end)
        end)

      assert_receive :in_call, 2_000

      # `:shutdown` is the ordinary supervisor termination reason, and it does
      # not run `after` blocks — so this leaks the slot.
      Process.exit(pid, :shutdown)

      assert ExternalService.saturated?(service)

      # ...until :reclaim_after makes it reusable, rather than wedging forever.
      Process.sleep(150)
      refute ExternalService.saturated?(service)
      assert ExternalService.call(service, fn -> :recovered end) == :recovered
    end

    test "a reclaimed slot is not clawed back by the original holder", %{service: service} do
      start(service, concurrency: [limit: 1, reclaim_after: 50])

      test_process = self()

      slow =
        Task.async(fn ->
          ExternalService.call(service, fn ->
            send(test_process, :in_call)

            receive do
              :release -> :slow_done
            after
              5_000 -> :timeout
            end
          end)
        end)

      assert_receive :in_call, 2_000

      # Let the slow call's slot expire and be taken by someone else.
      Process.sleep(80)
      assert ExternalService.call(service, fn -> :took_the_slot end) == :took_the_slot

      # The slow caller now finishes and releases. Because release is a
      # compare-and-exchange it must not free a slot it no longer owns.
      send(slow.pid, :release)
      assert Task.await(slow) == :slow_done

      # Prove the released slot belongs to whoever holds it now: take it and
      # confirm the service reports itself saturated.
      tasks = saturate(service, 1)
      held = await_in_call(1)
      assert ExternalService.saturated?(service)

      Enum.each(held, &send(&1, :release))
      Task.await_many(tasks)
    end
  end

  describe "interaction with the other mechanisms" do
    test "saturation does not melt the circuit breaker", %{service: service} do
      :ok =
        ExternalService.start(service,
          circuit_breaker: [tolerate: 1, within: :timer.seconds(10)],
          concurrency: [limit: 1, reclaim_after: :timer.seconds(30)],
          retry: [max_attempts: 1]
        )

      tasks = saturate(service, 1)
      held = await_in_call(1)

      # Comfortably more rejections than `tolerate: 1` would survive if these
      # counted as failures.
      for _ <- 1..5 do
        assert {:error, %ServiceSaturated{}} = ExternalService.call(service, fn -> :nope end)
      end

      assert ExternalService.available?(service)
      refute ExternalService.blown?(service)

      Enum.each(held, &send(&1, :release))
      Task.await_many(tasks)
    end

    test "saturation is not retried", %{service: service} do
      start(service,
        concurrency: [limit: 1, reclaim_after: :timer.seconds(30)],
        retry: [max_attempts: 5, backoff: :linear, base: 0]
      )

      tasks = saturate(service, 1)
      held = await_in_call(1)

      # Retrying would only find the bulkhead full again, so the call gives up
      # immediately rather than burning its attempts.
      assert {:error, %ServiceSaturated{}} = ExternalService.call(service, fn -> :nope end)

      Enum.each(held, &send(&1, :release))
      Task.await_many(tasks)
    end

    test "a rate limited call consumes no slot", %{service: service} do
      start(service,
        rate_limit: [limit: 1, per: :timer.minutes(1), wait: false],
        concurrency: [limit: 1, reclaim_after: :timer.seconds(30)]
      )

      assert ExternalService.call(service, fn -> :first end) == :first

      # The slot is taken inside the rate limiter, so a call rejected by the
      # limiter never reaches it.
      assert {:error, %RateLimited{}} = ExternalService.call(service, fn -> :second end)
      assert Concurrency.in_flight(service) == 0
    end

    test "a call waiting between retries holds no slot", %{service: service} do
      start(service,
        concurrency: [limit: 1, reclaim_after: :timer.seconds(30)],
        retry: [max_attempts: 3, backoff: :linear, base: 200, factor: 1]
      )

      task = Task.async(fn -> ExternalService.call(service, fn -> :retry end) end)

      # The function returns immediately, so by now the call is sitting in
      # backoff — and per-attempt scoping means it is not holding a slot.
      Process.sleep(80)
      assert Concurrency.in_flight(service) == 0
      assert ExternalService.call(service, fn -> :concurrent end) == :concurrent

      assert {:error, %ExternalService.RetriesExhausted{}} = Task.await(task, 5_000)
    end
  end

  describe "introspection and reset" do
    test "in_flight/1 and saturated?/1 track held slots", %{service: service} do
      start(service, concurrency: [limit: 2, reclaim_after: :timer.seconds(30)])

      assert Concurrency.in_flight(service) == 0
      assert Concurrency.limit(service) == 2
      refute ExternalService.saturated?(service)

      tasks = saturate(service, 2)
      held = await_in_call(2)

      assert Concurrency.in_flight(service) == 2
      assert ExternalService.saturated?(service)

      Enum.each(held, &send(&1, :release))
      Task.await_many(tasks)
    end

    test "a service with no concurrency limit is never saturated", %{service: service} do
      start(service, [])

      refute ExternalService.saturated?(service)
      assert Concurrency.in_flight(service) == 0
      assert Concurrency.limit(service) == nil
      assert Concurrency.reset(service) == :ok
    end

    test "an unstarted service is never saturated" do
      refute ExternalService.saturated?(:never_started_concurrency)
      assert Concurrency.in_flight(:never_started_concurrency) == 0
      assert Concurrency.reset(:never_started_concurrency) == {:error, :not_found}
    end

    test "reset_all/1 frees leaked slots", %{service: service} do
      start(service, concurrency: [limit: 1, reclaim_after: :timer.hours(1)])

      test_process = self()

      pid =
        spawn(fn ->
          ExternalService.call(service, fn ->
            send(test_process, :in_call)
            Process.sleep(:infinity)
          end)
        end)

      assert_receive :in_call, 2_000
      Process.exit(pid, :kill)

      # With a one-hour reclaim window this slot is effectively lost, which is
      # what makes an explicit reset worth having.
      assert ExternalService.saturated?(service)

      assert ExternalService.reset_all(service) == :ok
      refute ExternalService.saturated?(service)
    end
  end

  describe "waiting for a slot" do
    test "a burst that clears within the budget is served, not shed", %{service: service} do
      start(service,
        concurrency: [limit: 1, reclaim_after: :timer.seconds(30), wait: 500]
      )

      test_process = self()

      holder =
        Task.async(fn ->
          ExternalService.call(service, fn ->
            send(test_process, :in_call)

            receive do
              :release -> :done
            after
              5_000 -> :timeout
            end
          end)
        end)

      assert_receive :in_call, 2_000

      waiter = Task.async(fn -> ExternalService.call(service, fn -> :served end) end)

      # The slot is busy, so the waiter is parked rather than shed.
      Process.sleep(50)
      refute Task.yield(waiter, 0)

      send(holder.pid, :release)
      assert Task.await(holder) == :done

      # It picks up the freed slot instead of returning ServiceSaturated.
      assert Task.await(waiter, 2_000) == :served
    end

    test "the budget is bounded: it sheds once exhausted", %{service: service} do
      start(service, concurrency: [limit: 1, reclaim_after: :timer.seconds(30), wait: 50])

      tasks = saturate(service, 1)
      held = await_in_call(1)

      {elapsed, result} =
        :timer.tc(fn -> ExternalService.call(service, fn -> flunk("should not run") end) end)

      assert {:error, %ServiceSaturated{}} = result
      # Waited roughly the budget, then gave up rather than parking forever.
      assert elapsed >= 40_000
      assert elapsed < 2_000_000

      Enum.each(held, &send(&1, :release))
      Task.await_many(tasks)
    end

    test "a waiting caller holds no slot", %{service: service} do
      start(service, concurrency: [limit: 2, reclaim_after: :timer.seconds(30), wait: 300])

      tasks = saturate(service, 2)
      held = await_in_call(2)

      # Two slots are held by the calls in flight. A third caller waiting for one
      # must not itself be counted as in flight.
      waiter = Task.async(fn -> ExternalService.call(service, fn -> :served end) end)
      Process.sleep(50)

      assert Concurrency.in_flight(service) == 2

      Enum.each(held, &send(&1, :release))
      Task.await_many(tasks)
      assert Task.await(waiter, 2_000) == :served
    end

    test "waiting emits [:external_service, :concurrency, :waited]", %{service: service} do
      start(service, concurrency: [limit: 1, reclaim_after: :timer.seconds(30), wait: 500])

      test_process = self()
      handler_id = "waited-#{inspect(service)}"

      :telemetry.attach(
        handler_id,
        [:external_service, :concurrency, :waited],
        fn _event, measurements, metadata, _config ->
          send(test_process, {:waited, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      holder =
        Task.async(fn ->
          ExternalService.call(service, fn ->
            send(test_process, :in_call)

            receive do
              :release -> :done
            after
              5_000 -> :timeout
            end
          end)
        end)

      assert_receive :in_call, 2_000
      waiter = Task.async(fn -> ExternalService.call(service, fn -> :served end) end)
      Process.sleep(30)
      send(holder.pid, :release)

      assert Task.await(holder) == :done
      assert Task.await(waiter, 2_000) == :served

      assert_receive {:waited, %{wait_time: wait_time}, %{service: ^service}}, 2_000
      assert wait_time > 0
    end

    test "a call served without waiting emits nothing", %{service: service} do
      start(service, concurrency: [limit: 1, reclaim_after: :timer.seconds(30), wait: 500])

      test_process = self()
      handler_id = "no-wait-#{inspect(service)}"

      :telemetry.attach(
        handler_id,
        [:external_service, :concurrency, :waited],
        fn _event, m, meta, _config -> send(test_process, {:waited, m, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert ExternalService.call(service, fn -> :ok end) == :ok
      refute_receive {:waited, _, _}, 100
    end
  end

  describe "configuration" do
    test "wait: :infinity is rejected with an explanation", %{service: service} do
      message =
        assert_raise ArgumentError, fn ->
          ExternalService.start(service,
            concurrency: [limit: 1, reclaim_after: 1_000, wait: :infinity],
            retry: [max_attempts: 1]
          )
        end

      assert Exception.message(message) =~ "unbounded pile-up"
    end

    test "reclaim_after is required", %{service: service} do
      assert_raise NimbleOptions.ValidationError, ~r/required.*:reclaim_after/, fn ->
        ExternalService.start(service, concurrency: [limit: 5], retry: [max_attempts: 1])
      end
    end

    test "limit is required", %{service: service} do
      assert_raise NimbleOptions.ValidationError, ~r/required.*:limit/, fn ->
        ExternalService.start(service,
          concurrency: [reclaim_after: 1_000],
          retry: [max_attempts: 1]
        )
      end
    end
  end

  describe "telemetry" do
    test "a rejection emits [:external_service, :concurrency, :rejected]", %{service: service} do
      start(service, concurrency: [limit: 1, reclaim_after: :timer.seconds(30)])

      test_process = self()
      handler_id = "concurrency-#{inspect(service)}"

      :telemetry.attach(
        handler_id,
        [:external_service, :concurrency, :rejected],
        fn _event, measurements, metadata, _config ->
          send(test_process, {:rejected, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      tasks = saturate(service, 1)
      held = await_in_call(1)

      ExternalService.call(service, fn -> :nope end)

      assert_receive {:rejected, %{limit: 1}, %{service: ^service}}, 2_000

      Enum.each(held, &send(&1, :release))
      Task.await_many(tasks)
    end
  end
end
