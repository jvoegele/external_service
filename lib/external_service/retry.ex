defmodule ExternalService.Retry do
  @moduledoc false

  # The retry mechanism: the delay sequence a set of `RetryOptions` describes, the
  # loop that sleeps through it, and the decision about whether a given outcome
  # counts as a retry at all.
  #
  # This is the fourth mechanism module, alongside `CircuitBreaker`, `RateLimiter`
  # and `Concurrency`. Each of those owns its configuration, its state and its
  # behavior; retrying is the one that did not, because until #69 the loop was a
  # dependency's macro and there was nothing of ours to put anywhere.
  #
  # `ExternalService.RetryOptions` stays public and unchanged: retry options are
  # the only per-call configuration, so callers construct, validate and merge them.
  # It just no longer carries behavior.
  #
  # What deliberately does not live here is what a failed attempt *costs* a
  # service. Retrying decides that an attempt failed retriably; melting the circuit
  # breaker and emitting telemetry are `ExternalService`'s, because they are about
  # composing mechanisms rather than about retrying.

  alias ExternalService.RetryOptions

  require Logger

  @type service :: ExternalService.service()

  @typedoc """
  What one attempt decided: a settled result, or a request for another attempt.

  A bare `:retry` and a `{:retry, reason}` stay distinct all the way out to
  `ExternalService.call/3`, which turns the former into a `RetriesExhausted` whose
  reason is `:reason_unknown`.
  """
  @type outcome ::
          {:no_retry, result :: term()}
          | {:error, :retry}
          | {:error, {:retry, reason :: term()}}
          | {:error, {:retry_exception, Exception.t(), Exception.stacktrace()}}

  @doc """
  Runs `attempt` until it settles or the delays this configuration describes run
  out, sleeping through `sleep` between attempts.

  Each element of the delay stream is how long to sleep *before* the attempt that
  follows it, so the first attempt is made immediately and the stream running out
  is what ends the retrying. An attempt that does not ask for another wins
  immediately; otherwise the last attempt's answer is the call's, which is how an
  exhausted call reports the reason it kept retrying.

  Sleeping goes through the service's `:sleep_function` so that a test can drive
  backoff without waiting for it.
  """
  @spec call(RetryOptions.t(), ExternalService.sleep_function(), (-> outcome())) :: outcome()
  def call(%RetryOptions{} = retry_options, sleep, attempt) when is_function(attempt, 0) do
    retry_options
    |> delay_stream()
    |> run_attempts(attempt, sleep)
  end

  defp run_attempts(delays, attempt, sleep) do
    case attempt.() do
      {:no_retry, _} = result -> result
      retry -> retry_attempts(delays, attempt, sleep, retry)
    end
  end

  defp retry_attempts(delays, attempt, sleep, first_retry) do
    Enum.reduce_while(delays, first_retry, fn delay, _previous ->
      sleep.(delay)
      continue_unless_settled(attempt.())
    end)
  end

  defp continue_unless_settled({:no_retry, _} = result), do: {:halt, result}
  defp continue_unless_settled(retry), do: {:cont, retry}

  @doc """
  Makes one attempt: runs `function` and decides whether its outcome asks for
  another.

  An explicit `:retry` / `{:retry, reason}` return is taken at face value.
  Anything else is put to the `:retry_on` predicate, and a raised exception to
  `:retry_exceptions`; an exception neither matches is re-raised with its original
  stacktrace, which is also what makes it *not* count as a failure against the
  circuit breaker.
  """
  @spec attempt(service(), RetryOptions.t(), (-> term())) :: outcome() | no_return()
  def attempt(service, %RetryOptions{} = retry_options, function) when is_function(function, 0) do
    case function.() do
      {:retry, reason} -> {:error, {:retry, reason}}
      :retry -> {:error, :retry}
      result -> maybe_retry_on_result(service, retry_options.retry_on, result)
    end
  rescue
    error ->
      if retriable_exception?(service, error, retry_options.retry_exceptions) do
        {:error, {:retry_exception, error, __STACKTRACE__}}
      else
        reraise error, __STACKTRACE__
      end
  end

  @doc """
  The reason an attempt gave for wanting another, as reported to telemetry and
  carried into `ExternalService.RetriesExhausted`.
  """
  @spec reason(outcome()) :: term()
  def reason({:error, :retry}), do: :reason_unknown
  def reason({:error, {:retry, reason}}), do: reason
  def reason({:error, {:retry_exception, exception, _stacktrace}}), do: exception

  # When a `:retry_on` predicate is configured, a result it matches is treated as a
  # retry — with the result itself as the retry reason — exactly like an explicit
  # `:retry` return (which is handled before we get here, so an explicit return
  # always takes precedence). With no predicate, or when it does not match, the
  # result is returned untouched.
  defp maybe_retry_on_result(_service, nil, result), do: {:no_retry, result}

  defp maybe_retry_on_result(service, predicate, result) when is_function(predicate, 1) do
    if apply_predicate(service, :retry_on, predicate, result) do
      {:error, {:retry, result}}
    else
      {:no_retry, result}
    end
  end

  # `:retry_exceptions` is either a list of exception modules — an exception is
  # retriable when its struct is one of them — or a predicate on the exception
  # itself, which can decide per instance rather than per type.
  defp retriable_exception?(service, error, predicate) when is_function(predicate, 1) do
    apply_predicate(service, :retry_exceptions, predicate, error)
  end

  defp retriable_exception?(_service, error, retry_exceptions) when is_list(retry_exceptions) do
    Enum.any?(retry_exceptions, fn module -> is_struct(error, module) end)
  end

  # A retry predicate is arbitrary user code, and `:retry_exceptions` runs it on a
  # path that is already failing — so a bug in the predicate would otherwise become
  # the failure the caller sees, in place of the exception it was called to
  # classify. Any way of not returning an answer (raise, throw, or exit) is treated
  # as "this predicate did not classify the value", which means no retry: retrying
  # is the consequential interpretation, and a predicate that just crashed has
  # demonstrated it cannot authorize it. The call's own result or exception is left
  # exactly as it was, and the warning is what makes the broken predicate findable.
  defp apply_predicate(service, option, predicate, value) do
    !!predicate.(value)
  rescue
    error -> predicate_failed(service, option, :error, error, __STACKTRACE__)
  catch
    kind, reason -> predicate_failed(service, option, kind, reason, __STACKTRACE__)
  end

  defp predicate_failed(service, option, kind, reason, stacktrace) do
    Logger.warning("""
    The #{inspect(option)} predicate for #{inspect(service)} did not return, so the \
    call was treated as not retriable and its own result or exception was left \
    untouched. Fix the predicate: it must answer for every value it can be given, \
    including ones it does not recognise.

    #{Exception.format(kind, reason, stacktrace)}\
    """)

    false
  end

  @doc """
  The stream of delays, in milliseconds, that these options describe — one element
  per retry, so an `n`-element stream means at most `n + 1` attempts.

  `call/3` sleeps for each element in turn and stops when the stream is exhausted.

  This stream is tied to the clock: with an `:expiry` set, what is left of the
  budget is measured against `System.monotonic_time/1`, and it is `call/3`
  *sleeping* each delay that keeps the clock advancing in step with the sequence.
  Enumerating it without sleeping decouples the two, so it answers a question
  nobody asked — see `plan/1`, which is the one to inspect.
  """
  @spec delay_stream(RetryOptions.t()) :: Enumerable.t()
  def delay_stream(%RetryOptions{} = retry_opts) do
    build(retry_opts, monotonic_budget())
  end

  @doc """
  The delays these options *plan* to use, without a clock and without waiting.

  Identical to `delay_stream/1` except that the `:expiry` budget is spent against
  the delays themselves rather than against elapsed time — which is exactly what
  the real clock does once `call/3` sleeps them. The trimming rule is shared, so
  the two cannot drift.

  This is what to enumerate to answer "what would this configuration do":

      iex> ExternalService.RetryOptions.new(base: 10, expiry: 1000, max_attempts: :infinity)
      ...> |> ExternalService.Retry.plan()
      ...> |> Enum.to_list()
      [10, 20, 40, 80, 160, 320, 370]

  The same options through `delay_stream/1` block for the whole budget and yield a
  sequence that depends on how fast the machine drew it.

  One configuration plans an unbounded number of attempts: a `:base` of `0` with
  no `:max_attempts` bound never spends its budget, so the plan is an infinite
  stream of zeros. That is honest rather than evasive — how many zero-delay
  attempts fit in a time budget is a property of the machine, not of the
  configuration. Bound it as you would any other infinite stream here.
  """
  @spec plan(RetryOptions.t()) :: Enumerable.t()
  def plan(%RetryOptions{} = retry_opts) do
    build(retry_opts, virtual_budget())
  end

  defp build(%RetryOptions{} = retry_opts, budget) do
    retry_opts
    |> backoff_stream()
    |> apply_jitter(retry_opts.jitter)
    |> apply_cap(retry_opts.cap)
    |> apply_expiry(retry_opts.expiry, budget)
    |> apply_max_attempts(retry_opts.max_attempts)
  end

  # The delay-stream builders below were originally provided by
  # `Retry.DelayStreams` from ElixirRetry (https://github.com/safwank/ElixirRetry,
  # Copyright 2014 Safwan Kamarrudin, Apache License 2.0), and are reimplemented
  # here so that the retry loop — and the sleeping it does — belongs to this
  # library. `delay_stream_test.exs` pins the sequences.
  #
  # They were ported behavior-for-behavior, and the backoff, jitter and cap
  # builders still are. `:expiry` has since diverged deliberately: it no longer
  # floors its final delay at 100ms, so a budget smaller than that is honored
  # rather than rounded up (issue #70).

  # Exponential backoff doubles the previous delay. `:factor` is not consulted:
  # it belongs to linear backoff, where it is the increment.
  defp backoff_stream(%RetryOptions{backoff: :exponential, base: base}) do
    Stream.unfold(base, fn previous -> {previous, previous * 2} end)
  end

  # Linear backoff adds `:factor` to the base delay once per retry taken.
  defp backoff_stream(%RetryOptions{backoff: :linear, base: base, factor: factor}) do
    Stream.unfold(0, fn retries -> {base + retries * factor, retries + 1} end)
  end

  # `jitter` accepts a boolean or an explicit proportion, with `true` meaning the
  # conventional +/- 10%.
  defp apply_jitter(stream, proportion) when is_number(proportion),
    do: randomize(stream, proportion)

  defp apply_jitter(stream, true), do: randomize(stream, 0.1)
  defp apply_jitter(stream, _falsy), do: stream

  # The shift spans `1 - max_delta` to `max_delta` rather than being symmetric
  # about zero, because `:rand.uniform/1` starts at 1. Delays are clamped at zero
  # so that jitter can never turn a short delay negative.
  defp randomize(stream, proportion) do
    Stream.map(stream, fn delay ->
      max_delta = round(delay * proportion)
      shift = random_uniform(2 * max_delta) - max_delta

      max(delay + shift, 0)
    end)
  end

  defp random_uniform(n) when n <= 0, do: 0
  defp random_uniform(n), do: :rand.uniform(n)

  # A cap clamps each delay without ending the stream — retrying continues, just
  # never further apart than this.
  defp apply_cap(stream, nil), do: stream
  defp apply_cap(stream, cap), do: Stream.map(stream, &min(&1, cap))

  # Both bounds distinguish `nil` (never set) from `:infinity` (explicitly
  # unbounded) so that `start/2` can warn about the former, but the two behave
  # identically here: neither limits the delay stream.
  defp apply_expiry(stream, unbounded, _budget) when unbounded in [nil, :infinity], do: stream

  defp apply_expiry(stream, expiry, budget) do
    Stream.resource(
      fn -> {stream, budget.open.(expiry)} end,
      fn
        :at_end -> {:halt, :at_end}
        {remaining, held} -> next_delay_within(remaining, held, budget)
      end,
      fn _ -> :ok end
    )
  end

  # The budget is measured from the first time a delay is asked for — that is,
  # after the initial attempt has already run — so it bounds the retrying rather
  # than the call as a whole.
  #
  # The budget is spent, never overshot, and never abandoned early. A preferred
  # delay that still fits is used as-is; one that would overshoot is trimmed to
  # whatever is left, which places the final attempt exactly at the deadline. Only
  # a budget with nothing left in it stops without a further attempt.
  #
  # Trimming rather than halting matters more than it looks: halting on the first
  # delay that would overshoot abandons most of the budget under exponential
  # backoff — 630ms of a 1000ms budget, 2550ms of 5000ms — because the delay that
  # does not fit is roughly as large as everything before it combined.
  #
  # This rule is the whole of `:expiry`, and it is deliberately written once. What
  # `delay_stream/1` and `plan/1` disagree about is only how much of the budget is
  # left, never what to do about it.
  defp next_delay_within(remaining, held, budget) do
    case Enum.take(remaining, 1) do
      [preferred] ->
        left = budget.left.(held)

        cond do
          left <= 0 -> {:halt, :at_end}
          preferred >= left -> {[left], :at_end}
          true -> {[preferred], {Stream.drop(remaining, 1), budget.spend.(held, preferred)}}
        end

      [] ->
        {:halt, :at_end}
    end
  end

  # The two ways of holding a time budget, and the only thing the live stream and
  # the plan disagree about.
  #
  # The live budget is a deadline that the world moves toward on its own, so
  # spending a delay is a no-op: what makes the clock advance is `call/3` sleeping.
  # Monotonic rather than system time, so that a clock adjustment mid-call cannot
  # stretch or collapse a retry budget.
  defp monotonic_budget do
    %{
      open: fn expiry -> now_ms() + expiry end,
      left: fn deadline -> deadline - now_ms() end,
      spend: fn deadline, _delay -> deadline end
    }
  end

  # The planning budget is the remaining milliseconds themselves, drawn down by
  # each delay yielded — which is what the deadline above measures once those
  # delays have actually been slept.
  defp virtual_budget do
    %{
      open: fn expiry -> expiry end,
      left: fn remaining -> remaining end,
      spend: fn remaining, delay -> remaining - delay end
    }
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  # `max_attempts` counts the initial attempt plus retries, so the delay stream
  # (one delay per retry) is limited to `max_attempts - 1` elements.
  defp apply_max_attempts(stream, unbounded) when unbounded in [nil, :infinity], do: stream

  defp apply_max_attempts(stream, max_attempts)
       when is_integer(max_attempts) and max_attempts > 0,
       do: Stream.take(stream, max_attempts - 1)
end
