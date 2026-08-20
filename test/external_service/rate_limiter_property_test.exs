defmodule ExternalService.RateLimiterPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ExternalService.RateLimited
  alias ExternalService.RateLimiter

  # A sequence property: the limiter is walked through a generated ordering of
  # requests, peeks and resets, with a model of what its budget should be after
  # each one.
  #
  # This is the shape a grid cannot reach. The interesting failures of a limiter
  # are not "which configuration" but "in which order" — a peek that quietly spends
  # a token, a reset that restores the wrong amount, a refusal that does not stick.
  # None of those is visible in a configuration; all of them are visible in a
  # sequence, and StreamData shrinks a failing one to the shortest ordering that
  # still breaks.
  #
  # `per: 60_000` puts the refill rate far below the time these run in, so the
  # budget only moves when an operation moves it. A limiter that refilled during a
  # property would be a property about the clock.
  @per :timer.minutes(1)
  @limits 1..6

  setup_all do
    # Started once rather than per run: `start/2` writes to `:persistent_term`,
    # whose cost is a global scan, and a property run is a hot loop.
    services =
      Map.new(@limits, fn limit ->
        service = :"rate_limiter_property_#{limit}"

        :ok =
          ExternalService.start(service,
            rate_limit: [limit: limit, per: @per, wait: false],
            retry: [max_attempts: 1]
          )

        {limit, service}
      end)

    on_exit(fn ->
      Enum.each(services, fn {_limit, service} -> ExternalService.stop(service) end)
    end)

    {:ok, services: services}
  end

  property "the budget is exactly what the sequence of operations leaves", %{services: services} do
    check all(
            limit <- member_of(Enum.to_list(@limits)),
            operations <-
              list_of(member_of([:request, :request, :peek, :reset]),
                min_length: 1,
                max_length: 40
              )
          ) do
      service = Map.fetch!(services, limit)
      :ok = RateLimiter.reset(service)

      Enum.reduce(operations, limit, fn operation, budget ->
        apply_operation(service, operation, budget, limit)
      end)
    end
  end

  # `:request` spends a token when there is one, and is refused when there is not.
  defp apply_operation(service, :request, budget, _limit) when budget > 0 do
    assert RateLimiter.request(service) == :ok
    budget - 1
  end

  defp apply_operation(service, :request, 0, _limit) do
    assert {:error, %RateLimited{}} = RateLimiter.request(service)
    # Refusal sticks: a refused request must not have spent anything either, or a
    # caller retrying against a closed budget would slowly drain it further.
    0
  end

  # `:peek` agrees with what the next request would do, and consumes nothing —
  # which is the whole reason it exists, and the easiest thing to get wrong.
  defp apply_operation(service, :peek, budget, _limit) do
    case RateLimiter.peek(service) do
      :ok -> assert budget > 0, "peek said a call would be admitted with no budget left"
      {:wait, _after} -> assert budget == 0, "peek said a call would wait with #{budget} left"
    end

    budget
  end

  defp apply_operation(service, :reset, _budget, limit) do
    assert RateLimiter.reset(service) == :ok
    limit
  end
end
