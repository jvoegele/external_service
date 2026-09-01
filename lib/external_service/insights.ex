defmodule ExternalService.Insights do
  @moduledoc """
  Watches a service's telemetry and reports when its configuration is not doing
  what it was meant to do.

      ExternalService.Insights.attach()

  `ExternalService.explain/1` and `ExternalService.simulate/3` answer questions
  about a configuration from the configuration. This answers the one question they
  cannot: whether *what is actually happening* matches it.

  The gap is attempt duration. Nothing in a configuration states how long a single
  attempt takes, so a breaker sized correctly on the day it was written becomes
  inert when the dependency slows down — same configuration, different behavior,
  and the symptom is a service failing every call with its breaker still closed.
  That is a bad thing to discover during an incident and a cheap thing to notice
  beforehand.

      [ExternalService.Insights] :payments has failed 14 consecutive calls over
      21.7s with its circuit breaker still closed. It tolerates 5 failures within
      10s, but these are arriving about 1.7s apart, so at most 6 are ever counted
      together. Try `circuit_breaker: [within: :timer.seconds(21)]`.

  ## Attaching

  Off by default, and free when it is not attached — no handlers, no storage, no
  cost on any call.

      # in your application's start/2, after the supervision tree is up
      ExternalService.Insights.attach()

  `attach/1` watches every service that has been started at that moment. A service
  started later needs its own call:

      ExternalService.Insights.attach(services: [MyApp.Stripe])

  ## Options

    * `:services` — which services to watch. Defaults to every started service.
    * `:log` — whether to log findings as they appear. Defaults to `true`.
    * `:log_every` — the minimum gap between log lines for one service, in
      milliseconds. Defaults to 5 minutes. A diagnostic that fires on every call is
      a diagnostic people detach.

  ## Reading findings as data

  `report/1` returns what is being observed and what it means, so the same
  findings can drive a health endpoint or an assertion rather than a log line:

      %ExternalService.Insights.Report{
        service: :payments,
        calls: 214,
        findings: [%{check: :inert_breaker, message: "..."}],
        ...
      }

  ## What it costs

  One `:atomics` array per watched service — a fixed dozen integers, updated
  without locks — and one key in the calling process's dictionary for the duration
  of a call. Nothing accumulates, and no process is started.
  """

  alias ExternalService.Explanation
  alias ExternalService.RetryOptions

  require Logger

  defmodule Report do
    @moduledoc """
    What `ExternalService.Insights` has observed for one service.

    Counters are cumulative since `attach/1`. `:findings` carries the same shape
    as the configuration checks: a `:check` naming the kind, and a `:message`
    saying what to do about it.
    """

    @type t :: %__MODULE__{
            service: ExternalService.service(),
            calls: non_neg_integer(),
            succeeded: non_neg_integer(),
            failed: non_neg_integer(),
            rejected: non_neg_integer(),
            degraded: non_neg_integer(),
            attempts: non_neg_integer(),
            consecutive_failures: non_neg_integer(),
            worst_consecutive_failures: non_neg_integer(),
            mean_call: non_neg_integer(),
            worst_call: non_neg_integer(),
            findings: [%{check: atom(), message: String.t()}]
          }

    defstruct service: nil,
              calls: 0,
              succeeded: 0,
              failed: 0,
              rejected: 0,
              degraded: 0,
              attempts: 0,
              consecutive_failures: 0,
              worst_consecutive_failures: 0,
              mean_call: 0,
              worst_call: 0,
              findings: []
  end

  @events [
    [:external_service, :call, :stop],
    [:external_service, :call, :exception],
    [:external_service, :call, :retry]
  ]

  # Slots in the per-service `:atomics` array. Fixed size, so nothing accumulates
  # however long a service runs.
  @calls 1
  @succeeded 2
  @failed 3
  @rejected 4
  @degraded 5
  @attempts 6
  @streak 7
  @worst_streak 8
  @streak_started 9
  @total_duration 10
  @worst_duration 11
  @last_logged 12
  @slots 12

  @default_log_every :timer.minutes(5)

  @doc """
  Starts watching. See the module documentation for the options.
  """
  @spec attach(keyword()) :: :ok
  def attach(opts \\ []) do
    services = Keyword.get_lazy(opts, :services, &started_services/0)
    Enum.each(services, &:persistent_term.put(key(&1), :atomics.new(@slots, signed: false)))

    config = %{
      log: Keyword.get(opts, :log, true),
      log_every: Keyword.get(opts, :log_every, @default_log_every)
    }

    :telemetry.attach_many(handler_id(), @events, &__MODULE__.handle_event/4, config)
  end

  @doc """
  Stops watching, and discards what has been observed.
  """
  @spec detach() :: :ok
  def detach do
    Enum.each(started_services(), &:persistent_term.erase(key(&1)))
    :telemetry.detach(handler_id())
    :ok
  end

  @doc """
  What has been observed for `service`, and what it means.

  Answers `{:error, :not_attached}` for a service that is not being watched.
  """
  @spec report(ExternalService.service()) :: Report.t() | {:error, :not_attached}
  def report(service) do
    case fetch(service) do
      {:ok, counters} -> build_report(service, counters)
      :error -> {:error, :not_attached}
    end
  end

  @doc false
  def handle_event(
        [:external_service, :call, :retry],
        _measurements,
        %{service: service},
        _config
      ) do
    with {:ok, counters} <- fetch(service) do
      :atomics.add(counters, @attempts, 1)
      # Correlates the attempt with the call it belongs to. The retry loop runs in
      # the caller's process, so this is the same process the `:stop` below runs
      # in, and it is cleared there.
      Process.put({__MODULE__, service}, true)
    end

    :ok
  end

  def handle_event([:external_service, :call, event], measurements, metadata, config)
      when event in [:stop, :exception] do
    %{service: service} = metadata

    retried? = Process.delete({__MODULE__, service}) == true

    with {:ok, counters} <- fetch(service) do
      duration = System.convert_time_unit(measurements.duration, :native, :millisecond)
      record_call(counters, outcome(event, metadata), retried?, duration)
      maybe_log(service, counters, config)
    end

    :ok
  end

  # A call the breaker rejected never ran, so it is neither a success nor a
  # failure of the dependency — but it is the strongest evidence the breaker *is*
  # working, so it ends a failure streak.
  defp outcome(:exception, _metadata), do: :failed

  defp outcome(:stop, %{result: {:error, %ExternalService.CircuitBreakerOpen{}}}), do: :rejected
  defp outcome(:stop, %{result: {:error, %ExternalService.RetriesExhausted{}}}), do: :failed
  defp outcome(:stop, _metadata), do: :succeeded

  defp record_call(counters, outcome, retried?, duration) do
    :atomics.add(counters, @calls, 1)

    case outcome do
      :failed ->
        :atomics.add(counters, @failed, 1)
        streak = :atomics.add_get(counters, @streak, 1)
        if streak == 1, do: :atomics.put(counters, @streak_started, now())

        if streak > :atomics.get(counters, @worst_streak),
          do: :atomics.put(counters, @worst_streak, streak)

      :rejected ->
        :atomics.add(counters, @rejected, 1)
        :atomics.put(counters, @streak, 0)

      :succeeded ->
        :atomics.add(counters, @succeeded, 1)
        :atomics.put(counters, @streak, 0)
        if retried?, do: :atomics.add(counters, @degraded, 1)
    end

    # Rejected calls return immediately and would drag the mean down, hiding the
    # very slowness this is watching for.
    unless outcome == :rejected do
      :atomics.add(counters, @total_duration, duration)

      if duration > :atomics.get(counters, @worst_duration) do
        :atomics.put(counters, @worst_duration, duration)
      end
    end
  end

  defp build_report(service, counters) do
    read = &:atomics.get(counters, &1)
    calls = read.(@calls)
    rejected = read.(@rejected)
    ran = calls - rejected

    report = %Report{
      service: service,
      calls: calls,
      succeeded: read.(@succeeded),
      failed: read.(@failed),
      rejected: rejected,
      degraded: read.(@degraded),
      attempts: read.(@attempts),
      consecutive_failures: read.(@streak),
      worst_consecutive_failures: read.(@worst_streak),
      mean_call: if(ran > 0, do: div(read.(@total_duration), ran), else: 0),
      worst_call: read.(@worst_duration)
    }

    %Report{report | findings: findings(report, counters)}
  end

  defp findings(report, counters) do
    case ExternalService.State.fetch(report.service) do
      {:ok, state} ->
        options = state.options

        # `attempt_time_dominates/3` is suppressed while `inert_breaker/3` stands.
        # Slow attempts are *why* the breaker went inert, and the inert-breaker
        # message says so — reporting both would be telling someone twice, once
        # urgently and once as background, about one problem.
        inert = inert_breaker(report, options, counters)
        slow = if inert == [], do: attempt_time_dominates(report, options, counters), else: []

        Enum.concat([inert, slow, degraded_but_succeeding(report, options, counters)])

      :error ->
        []
    end
  end

  # The headline detection, and the one no static check can make. The breaker
  # tolerates a stated number of failures; more than that have happened in a row
  # and it is still closed, so whatever `:within` was sized against is not what is
  # happening.
  defp inert_breaker(report, options, counters) do
    breaker = Keyword.get(options, :circuit_breaker, [])
    tolerate = Keyword.get(breaker, :tolerate, 10)
    within = Keyword.get(breaker, :within)

    with false <- tolerate == :infinity,
         true <- report.consecutive_failures > tolerate,
         false <- ExternalService.blown?(report.service) do
      elapsed = now() - :atomics.get(counters, @streak_started)
      interval = div(elapsed, max(report.consecutive_failures - 1, 1))
      counted = if interval > 0, do: div(within, interval) + 1, else: report.consecutive_failures
      suggested = interval * (tolerate + 1) * 2

      [
        finding(:inert_breaker, """
        #{inspect(report.service)} has failed #{report.consecutive_failures} consecutive calls over \
        #{Explanation.duration(elapsed)} with its circuit breaker still closed. It tolerates \
        #{tolerate} failures within #{Explanation.duration(within)}, but these are arriving about \
        #{Explanation.duration(interval)} apart, so at most #{counted} are ever counted together.

            circuit_breaker: [within: :timer.seconds(#{ceil(suggested / 1000)})]

        A failing call takes its retry window plus however long its attempts run for, and only the \
        first of those is in the configuration — which is why a window that fitted when it was \
        written stops fitting when the dependency slows down.\
        """)
      ]
    else
      _ -> []
    end
  end

  # The same gap, seen before it has caused anything: calls are taking much longer
  # than their backoff accounts for, so the attempts are what is slow.
  defp attempt_time_dominates(report, options, _counters) do
    retry = RetryOptions.new(Keyword.get(options, :retry, []))
    window = RetryOptions.window(retry)

    with true <- report.calls >= 20,
         true <- is_integer(window) and window > 0,
         true <- report.mean_call > window * 2 do
      [
        finding(:attempt_time_dominates, """
        #{inspect(report.service)} is taking #{Explanation.duration(report.mean_call)} per call on \
        average (worst #{Explanation.duration(report.worst_call)}), against a retry window of \
        #{Explanation.duration(window)}. Most of a call is the attempts themselves rather than the \
        backoff between them, so the thing to bound is a single attempt — a timeout in your HTTP \
        client — and `:expiry` is what stops the retrying once attempts are that slow.

            retry: [expiry: :timer.seconds(#{ceil(report.mean_call / 1000)})]

        Note that `:within` is sized from the retry window, which is the half of a call's duration \
        this library knows about. See `ExternalService.explain/1`.\
        """)
      ]
    else
      _ -> []
    end
  end

  # What per-call melting deliberately hides from the breaker. Retrying is doing
  # its job, so nothing fails and nothing melts — but the dependency is unwell and
  # someone should know before it stops succeeding.
  defp degraded_but_succeeding(report, _options, _counters) do
    with true <- report.succeeded >= 20,
         proportion = report.degraded / report.succeeded,
         true <- proportion >= 0.2 do
      [
        finding(:degraded_but_succeeding, """
        #{inspect(report.service)} is succeeding, but #{round(proportion * 100)}% of its successful \
        calls needed at least one retry (#{report.degraded} of #{report.succeeded}). The circuit \
        breaker will not react to this and should not: the calls are working, and opening on them \
        would turn traffic that succeeds into errors.

        It is worth knowing about anyway — retrying is absorbing a fault rather than riding out a \
        blip, and every absorbed fault is latency your callers are paying for.\
        """)
      ]
    else
      _ -> []
    end
  end

  defp finding(check, message), do: %{check: check, message: String.trim_trailing(message)}

  # Throttled without a timer or a process: one atomics slot holds when this
  # service last reported, and a compare-and-exchange decides who reports next.
  #
  # The slot is claimed only when there is something to say. Claiming it on a
  # quiet check would spend the interval on silence, and a finding appearing a
  # second later would then wait out the whole of it — which is how a five-minute
  # throttle turns into "the first thing that went wrong was reported five minutes
  # after it did".
  defp maybe_log(_service, _counters, %{log: false}), do: :ok

  defp maybe_log(service, counters, %{log_every: log_every}) do
    last = :atomics.get(counters, @last_logged)
    now = now()

    # Zero means never, not "at VM start".
    due? = last == 0 or now - last >= log_every

    if due? and worth_checking?(counters) do
      report_findings(service, counters, last, now)
    end

    :ok
  end

  # Building a report is cheap but not free, and this runs inside a call. A
  # failing call is not a hot path — a healthy service has none — so every one of
  # those is worth a look; otherwise a periodic look is enough to catch the
  # findings that are about succeeding traffic.
  defp worth_checking?(counters) do
    :atomics.get(counters, @streak) > 0 or rem(:atomics.get(counters, @calls), 25) == 0
  end

  defp report_findings(service, counters, last, now) do
    case build_report(service, counters) do
      %Report{findings: []} ->
        :ok

      %Report{findings: findings} ->
        if :atomics.compare_exchange(counters, @last_logged, last, now) == :ok do
          Enum.each(findings, &Logger.warning("[ExternalService.Insights] " <> &1.message))
        end
    end
  end

  # Milliseconds since the VM started. `:atomics` here is unsigned and the
  # monotonic clock is not — it starts at a large negative offset — so times are
  # stored relative to the start rather than raw. Both sides of the subtraction
  # have to be in the same unit; `:erlang.system_info(:start_time)` is native.
  defp now do
    System.monotonic_time(:millisecond) -
      System.convert_time_unit(:erlang.system_info(:start_time), :native, :millisecond)
  end

  defp started_services do
    for {{ExternalService.State, service}, _state} <- :persistent_term.get(), do: service
  end

  defp fetch(service) do
    {:ok, :persistent_term.get(key(service))}
  rescue
    ArgumentError -> :error
  end

  defp key(service), do: {__MODULE__, service}

  defp handler_id, do: {__MODULE__, :handler}
end
