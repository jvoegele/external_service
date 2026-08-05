defmodule ExternalService.Concurrency do
  @moduledoc """
  A per-service concurrency limit — the bulkhead pattern.

  The circuit breaker bounds how many failures you tolerate and the rate limiter
  bounds how *often* calls start. Neither bounds how many are **in flight at
  once**, and that is the gap that opens when a service degrades rather than
  fails. Calls still succeed, just slowly, so the breaker sees nothing; and a
  limit of 100 calls per second against a service that slows to 10 seconds per
  call leaves roughly a thousand processes parked in the same call, each holding
  a connection out of the pool.

  A concurrency limit caps that. Over the limit, calls fail immediately with
  `ExternalService.ServiceSaturated` rather than queueing — queueing is what the
  rate limiter's `:wait` budget is for, and a queue is the pile-up this exists to
  prevent.

      use ExternalService,
        concurrency: [limit: 25, reclaim_after: :timer.seconds(30)]

  Saturation is **your** backpressure rather than the service's failure, so it
  does not melt the circuit breaker and is not retried, exactly like
  `ExternalService.RateLimited`.

  ## How slots are tracked

  State is an `:atomics` array with one slot per permit, so this needs no
  process, supervisor, or registry — the same shape as
  `ExternalService.RateLimiter.Local`.

  Each slot holds the monotonic millisecond deadline until which it counts as
  occupied. There is deliberately no "free" sentinel: `System.monotonic_time/1`
  may be negative, so a slot is free precisely when its deadline has passed.

  ## Why slots expire

  A slot is released in an `after` block, which covers everything that happens
  inside the calling process — returning, raising, throwing, exiting. It does
  **not** cover the process being terminated from outside: an exit signal, even
  the ordinary `:shutdown` a supervisor sends, kills the process without running
  `after`. That is not exotic — it is what happens to in-flight callers on every
  deploy that drains requests.

  A plain counter would leak on each of those and ratchet toward permanently
  wedged. Instead `:reclaim_after` bounds how long a slot may be held before it
  is considered abandoned and reused. The trade is that reclaiming a slot from a
  call that was merely slow briefly admits more than `:limit`. Over-admitting for
  one window is a far better failure than wedging forever, which is why
  `:reclaim_after` is required rather than defaulted: it must be longer than any
  legitimate call, and only you know your client's timeout.

  Releasing uses a compare-and-exchange rather than a write, so a slow caller
  whose slot was already reclaimed cannot evict whoever holds it now.
  """

  alias ExternalService.ServiceSaturated

  require Errata

  @type service :: ExternalService.service()

  @typedoc """
  A configured concurrency limit.

  `nil` means the service has none, in which case calls pass straight through.
  """
  @type t :: %__MODULE__{} | nil

  @typedoc """
  Returned by `call/2` when no slot was available.
  """
  @type saturated :: {__MODULE__, :saturated}

  defstruct [:service, :slots, :limit, :reclaim_after]

  @doc """
  Reports how many of `service`'s slots are currently held.

  A service with no concurrency limit — including one that was never started —
  answers `0`.
  """
  @spec in_flight(service()) :: non_neg_integer()
  def in_flight(service) do
    case fetch(service) do
      {:ok, %__MODULE__{} = concurrency} -> occupied(concurrency, now())
      _ -> 0
    end
  end

  @doc """
  Reports the configured limit for `service`, or `nil` if it has none.
  """
  @spec limit(service()) :: pos_integer() | nil
  def limit(service) do
    case fetch(service) do
      {:ok, %__MODULE__{limit: limit}} -> limit
      _ -> nil
    end
  end

  @doc """
  Discards `service`'s in-flight accounting, freeing every slot.

  Symmetric with `ExternalService.CircuitBreaker.reset/1` and
  `ExternalService.RateLimiter.reset/1`, and included in
  `ExternalService.reset_all/1`.

  This does not stop any call that is actually running — it only forgets that
  the slots were taken — so outside of tests it is a way to clear slots leaked by
  callers that were killed, rather than something to reach for routinely.
  """
  @spec reset(service()) :: :ok | {:error, :not_found}
  def reset(service) do
    case fetch(service) do
      {:ok, %__MODULE__{} = concurrency} -> free_all(concurrency)
      # Configured without a concurrency limit: no slots to free.
      {:ok, nil} -> :ok
      :not_started -> {:error, :not_found}
    end
  end

  defp fetch(service) do
    case ExternalService.State.fetch(service) do
      {:ok, %{concurrency: concurrency}} -> {:ok, concurrency}
      :error -> :not_started
    end
  end

  # The functions below drive the limit on `ExternalService`'s behalf, and take a
  # built struct rather than resolving it from the service state. They are not
  # part of the public API.

  @doc false
  @spec new(service(), keyword() | nil) :: t()
  def new(_service, nil), do: nil

  def new(service, options) when is_list(options) do
    limit = Keyword.fetch!(options, :limit)
    slots = :atomics.new(limit, signed: true)

    concurrency = %__MODULE__{
      service: service,
      slots: slots,
      limit: limit,
      reclaim_after: Keyword.fetch!(options, :reclaim_after)
    }

    free_all(concurrency)
    concurrency
  end

  @doc false
  @spec call(t(), (-> any())) :: any() | saturated()
  def call(nil, function) when is_function(function, 0), do: function.()

  def call(%__MODULE__{} = concurrency, function) when is_function(function, 0) do
    case acquire(concurrency) do
      {:ok, slot, deadline} ->
        try do
          function.()
        after
          release(concurrency, slot, deadline)
        end

      :saturated ->
        emit_rejected(concurrency)
        {__MODULE__, :saturated}
    end
  end

  @doc false
  @spec error(service()) :: ServiceSaturated.t()
  def error(service) do
    Errata.create(ServiceSaturated,
      context: %{service: service, limit: limit(service), in_flight: in_flight(service)}
    )
  end

  defp acquire(%__MODULE__{slots: slots, limit: limit, reclaim_after: reclaim_after}) do
    # Start where this process hashes rather than always at slot 1, so that
    # concurrent callers spread their compare-and-exchange attempts across the
    # array instead of contending on its head.
    scan(slots, limit, reclaim_after, now(), rem(:erlang.phash2(self()), limit) + 1, 0)
  end

  defp scan(_slots, limit, _reclaim_after, _now, _slot, examined) when examined >= limit,
    do: :saturated

  defp scan(slots, limit, reclaim_after, now, slot, examined) do
    held_until = :atomics.get(slots, slot)

    if held_until <= now do
      case :atomics.compare_exchange(slots, slot, held_until, now + reclaim_after) do
        :ok -> {:ok, slot, now + reclaim_after}
        # Another caller took this slot between the read and the exchange.
        _lost -> scan(slots, limit, reclaim_after, now, wrap(slot, limit), examined + 1)
      end
    else
      scan(slots, limit, reclaim_after, now, wrap(slot, limit), examined + 1)
    end
  end

  # Compare-and-exchange rather than a write: if this slot was reclaimed while
  # the call was still running, someone else holds it now and must not be evicted.
  defp release(%__MODULE__{slots: slots}, slot, deadline),
    do: :atomics.compare_exchange(slots, slot, deadline, now())

  defp free_all(%__MODULE__{slots: slots, limit: limit}) do
    now = now()
    Enum.each(1..limit, &:atomics.put(slots, &1, now))
    :ok
  end

  defp occupied(%__MODULE__{slots: slots, limit: limit}, now),
    do: Enum.count(1..limit, &(:atomics.get(slots, &1) > now))

  defp wrap(slot, limit), do: rem(slot, limit) + 1

  defp now, do: System.monotonic_time(:millisecond)

  defp emit_rejected(%__MODULE__{service: service, limit: limit}) do
    :telemetry.execute(
      [:external_service, :concurrency, :rejected],
      %{limit: limit},
      %{service: service}
    )
  end
end
