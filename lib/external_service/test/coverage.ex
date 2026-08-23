defmodule ExternalService.Test.Coverage do
  @moduledoc """
  Which resilience paths your test suite actually exercised.

  [Testing](testing.md) ends on the point this module gives a mechanism to:

  > **An inert service is not a tested one.** Tests that run with the mechanisms
  > off are not exercising your `:retry` returns, your fallback paths, or your
  > error handling.

  Nothing tells you whether you took that advice. A suite can make ten thousand
  guarded calls, every one on the happy path, and look exactly like a suite that
  exercises every failure path this library exists to provide. Coverage counts
  the calls per service and how many of them went down each path:

      external_service coverage

      service             calls    retried     failed    breaker  throttled  saturated
      MyApp.Geocoder         44         12          4          0          0          0
      MyApp.Search          318          0          0          0          0          0  ⚠
      MyApp.Stripe         1204        142         31          3          7          0

      ⚠ MyApp.Search was called 318 times and never once retried, failed, or was
        rejected. Its `:retry` returns, its fallback path and its error handling are
        not covered by this suite.

  > #### A row of zeros is a prompt, not a verdict {: .info}
  >
  > A dependency your tests stub at your own boundary is *supposed* to have
  > zeros — [Testing](testing.md#what-this-library-does-not-give-you) recommends
  > exactly that for business-logic tests. What the report is for is the service
  > you *believed* you were testing. Either write a test that takes it down a
  > failure path, or know why you did not. This is an opt-in diagnostic you run
  > deliberately, never a threshold and never a build failure.

  ## Enabling

      # test/test_helper.exs
      ExUnit.start()
      ExternalService.Test.Coverage.install_reporter()

  `mix test` then prints the table after the suite. Recording needs no reporter,
  so `entries/0` and `report/0` can be read at any point — including mid-suite,
  which makes "assert this test exercised the breaker" possible on its own:

      attach()
      on_exit(&detach/0)

      ExternalService.call(service, fn -> {:retry, :nope} end)

      assert [%{service: ^service, retried: 1}] = entries()

  > #### Install the reporter from `test_helper.exs` {: .warning}
  >
  > Counts accumulate in an ETS table, and an ETS table dies with the process
  > that created it. `install_reporter/0` creates it from `test/test_helper.exs`,
  > whose process outlives the suite. Creating it inside a *test* discards every
  > count when that test finishes.

  ## What it costs

  Nothing unless attached. Every event it reads is
  [already emitted](telemetry.md), in production too, so there is no
  instrumentation to enable and no build that differs — this is a handler and a
  reporter. While attached it is one `:ets.update_counter/4` per call, plus one
  key in the calling process's dictionary for the duration of a call.

  ## Coverage and `simulate/3`

  `ExternalService.simulate/3` answers whether a configuration *would* work.
  This answers whether your suite ever found out. Neither substitutes for the
  other, and a service with a good simulation and a row of zeros is exactly the
  case worth knowing about.
  """

  alias ExternalService.CircuitBreakerOpen
  alias ExternalService.RateLimited
  alias ExternalService.RetriesExhausted
  alias ExternalService.ServiceSaturated

  @table :external_service_coverage
  @handler_id {__MODULE__, :handler}

  # Every event is read inside `ExternalService`'s own call span and in the same
  # process, so the ones that describe *part* of a call set a flag which the
  # closing `:stop` / `:exception` consumes. That is what makes each column a
  # count of calls rather than of events: a call that retried four times is one
  # retried call.
  @events [
    [:external_service, :call, :stop],
    [:external_service, :call, :exception],
    [:external_service, :call, :retry],
    [:external_service, :circuit_breaker, :blown],
    [:external_service, :rate_limit, :sleep],
    [:external_service, :concurrency, :waited],
    [:external_service, :concurrency, :rejected]
  ]

  # Positions in the per-service counter tuple, whose first element is the
  # service itself.
  @calls 2
  @retried 3
  @failed 4
  @rejected 5
  @throttled 6
  @saturated 7

  @paths [
    {:retried, @retried},
    {:failed, @failed},
    {:rejected, @rejected},
    {:throttled, @throttled},
    {:saturated, @saturated}
  ]

  @typedoc """
  One service's accumulated coverage. Each count is a number of **calls**, not of
  events, so they are all comparable with `:calls` — a call that retried four
  times counts once.

  `:exercised?` is false when a service was called but never once went down any
  of the paths, which is the case the report flags.
  """
  @type entry :: %{
          service: ExternalService.service(),
          calls: non_neg_integer(),
          retried: non_neg_integer(),
          failed: non_neg_integer(),
          rejected: non_neg_integer(),
          throttled: non_neg_integer(),
          saturated: non_neg_integer(),
          exercised?: boolean()
        }

  @doc """
  Starts recording, creating the counter table if it does not exist.

  Called for you by `install_reporter/0`. Call it directly when you want the
  counts without the end-of-suite report — but see the warning in the module
  documentation about which process creates the table.
  """
  @spec attach() :: :ok
  def attach do
    ensure_table()
    :telemetry.attach_many(@handler_id, @events, &__MODULE__.__record__/4, nil)
  end

  @doc """
  Stops recording. The counts already accumulated survive, and `reset/0` clears
  them.
  """
  @spec detach() :: :ok
  def detach, do: :telemetry.detach(@handler_id)

  @doc """
  Starts recording and prints `report/0` after the suite.

  Put it in `test/test_helper.exs`, after `ExUnit.start/1`.
  """
  @spec install_reporter() :: :ok
  def install_reporter do
    :ok = attach()

    ExUnit.after_suite(fn _results ->
      case entries() do
        [] -> :ok
        _entries -> IO.puts("\n" <> report())
      end
    end)

    :ok
  end

  @doc """
  The accumulated coverage, one `t:entry/0` per service the suite called, ordered
  by service.

  A service that was never called does not appear — nothing was recorded for it.
  """
  @spec entries() :: [entry()]
  def entries do
    case :ets.whereis(@table) do
      :undefined ->
        []

      table ->
        table
        |> :ets.tab2list()
        |> Enum.map(&to_entry/1)
        |> Enum.sort_by(&inspect(&1.service))
    end
  end

  @doc """
  Discards every recorded count. Recording continues if it was attached.
  """
  @spec reset() :: :ok
  def reset do
    case :ets.whereis(@table) do
      :undefined -> :ok
      table -> true = :ets.delete_all_objects(table)
    end

    :ok
  end

  @doc """
  `entries/0` rendered as the report shown in the module documentation.

  Returns a message saying so when nothing was recorded, rather than an empty
  table.
  """
  @spec report() :: String.t()
  def report do
    case entries() do
      [] ->
        "external_service coverage\n\nNo guarded calls were recorded."

      entries ->
        "external_service coverage\n\n" <> table(entries) <> warnings(entries)
    end
  end

  @doc false
  # Public because `:telemetry` invokes it by module and function. Not API.
  def __record__([:external_service, :call, closing], _measurements, metadata, _config)
      when closing in [:stop, :exception] do
    service = metadata.service
    flags = Process.delete(flag_key(service)) || %{}

    positions =
      @paths
      |> Enum.filter(fn {path, _position} -> Map.has_key?(flags, path) end)
      |> Enum.map(fn {_path, position} -> position end)
      |> then(&(result_positions(closing, metadata) ++ &1))
      |> Enum.uniq()

    bump(service, [{@calls, 1} | Enum.map(positions, &{&1, 1})])
  end

  def __record__([:external_service | _] = event, _measurements, metadata, _config) do
    flag(metadata.service, path_for(event))
  end

  # A call can end on a path without any of the partial events firing — a
  # `wait: false` limiter never sleeps, it just refuses, and the guides recommend
  # exactly that configuration for tests. So the closing result is read as well,
  # and the two sources are deduplicated.
  defp result_positions(:exception, _metadata), do: [@failed]

  defp result_positions(:stop, %{result: {:error, error}}) do
    case error do
      %RetriesExhausted{} -> [@failed]
      %CircuitBreakerOpen{} -> [@rejected]
      %RateLimited{} -> [@throttled]
      %ServiceSaturated{} -> [@saturated]
      _other -> []
    end
  end

  defp result_positions(:stop, _metadata), do: []

  defp path_for([_, :call, :retry]), do: :retried
  defp path_for([_, :circuit_breaker, :blown]), do: :rejected
  defp path_for([_, :rate_limit, :sleep]), do: :throttled
  defp path_for([_, :concurrency, :waited]), do: :saturated
  defp path_for([_, :concurrency, :rejected]), do: :saturated

  defp flag(service, path) do
    key = flag_key(service)
    Process.put(key, Map.put(Process.get(key) || %{}, path, true))
    :ok
  end

  # Keyed by service so that a guarded call wrapping a call to a *different*
  # service keeps its own flags.
  defp flag_key(service), do: {__MODULE__, service}

  defp bump(service, ops) do
    ensure_table()
    :ets.update_counter(@table, service, ops, {service, 0, 0, 0, 0, 0, 0})
    :ok
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
        :ok

      _table ->
        :ok
    end
  rescue
    # Another process created it between the lookup and the create.
    ArgumentError -> :ok
  end

  defp to_entry({service, calls, retried, failed, rejected, throttled, saturated}) do
    %{
      service: service,
      calls: calls,
      retried: retried,
      failed: failed,
      rejected: rejected,
      throttled: throttled,
      saturated: saturated,
      exercised?: retried + failed + rejected + throttled + saturated > 0
    }
  end

  @columns [
    {"calls", :calls},
    {"retried", :retried},
    {"failed", :failed},
    {"breaker", :rejected},
    {"throttled", :throttled},
    {"saturated", :saturated}
  ]

  defp table(entries) do
    names = Enum.map(entries, &inspect(&1.service))
    name_width = Enum.max([String.length("service") | Enum.map(names, &String.length/1)])

    header =
      ["service" |> String.pad_trailing(name_width)]
      |> Enum.concat(Enum.map(@columns, fn {label, _key} -> pad(label) end))
      |> Enum.join("  ")

    rows =
      entries
      |> Enum.zip(names)
      |> Enum.map_join("\n", fn {entry, name} ->
        cells =
          Enum.map(@columns, fn {_label, key} ->
            entry |> Map.fetch!(key) |> to_string() |> pad()
          end)

        mark = if entry.exercised?, do: "", else: "  ⚠"

        Enum.join([String.pad_trailing(name, name_width) | cells], "  ") <> mark
      end)

    header <> "\n" <> rows <> "\n"
  end

  @column_width 9

  defp pad(value), do: String.pad_leading(value, @column_width)

  defp warnings(entries) do
    entries
    |> Enum.reject(& &1.exercised?)
    |> Enum.map_join("", fn entry ->
      "\n" <>
        wrap(
          "⚠ #{inspect(entry.service)} was called #{entry.calls} #{times(entry.calls)} and " <>
            "never once retried, failed, or was rejected. Its `:retry` returns, its " <>
            "fallback path and its error handling are not covered by this suite."
        ) <> "\n"
    end)
  end

  @wrap_at 78

  # Wrapped here rather than written as a heredoc because the first line starts
  # with a service name of any length, so where the break falls is not knowable
  # in advance.
  defp wrap(text) do
    text
    |> String.split(" ")
    |> Enum.reduce([""], fn word, [line | done] ->
      cond do
        line == "" -> [word | done]
        String.length(line) + 1 + String.length(word) <= @wrap_at -> [line <> " " <> word | done]
        true -> [word, line | done]
      end
    end)
    |> Enum.reverse()
    |> Enum.map_join("\n", fn
      "⚠" <> _ = first -> first
      continuation -> "  " <> continuation
    end)
  end

  defp times(1), do: "time"
  defp times(_), do: "times"
end
