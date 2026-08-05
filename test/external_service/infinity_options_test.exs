defmodule ExternalService.InfinityOptionsTest do
  @moduledoc """
  Covers `tolerate: :infinity` and `limit: :infinity` — the two options that turn
  a stateful mechanism off rather than merely setting it very large.

  Both exist because a child spec override can replace a key but cannot remove
  one, so a front door module's breaker and limiter could otherwise only be
  approximated away with big numbers. Big numbers are finite: a long enough test
  suite still trips them.
  """

  use ExUnit.Case, async: true

  alias ExternalService.CircuitBreaker
  alias ExternalService.CircuitBreaker.Cluster
  alias ExternalService.RateLimiter
  alias ExternalService.RetriesExhausted

  @moduletag capture_log: true

  setup context do
    service = :"#{context.module}.#{context.test}"
    on_exit(fn -> ExternalService.stop(service) end)
    {:ok, service: service}
  end

  describe "tolerate: :infinity" do
    test "never opens, however many melts it takes", %{service: service} do
      ExternalService.start(service,
        circuit_breaker: [tolerate: :infinity],
        retry: [max_attempts: 1]
      )

      Enum.each(1..1_000, fn _ -> CircuitBreaker.melt(service) end)

      assert ExternalService.available?(service)
      refute ExternalService.blown?(service)
      assert ExternalService.call(service, fn -> :ok end) == :ok
    end

    test "failing calls exhaust retries rather than opening the breaker", %{service: service} do
      ExternalService.start(service,
        circuit_breaker: [tolerate: :infinity],
        retry: [max_attempts: 3, backoff: :linear, base: 0]
      )

      # With a finite `:tolerate` this would open partway through, and later
      # calls would return CircuitBreakerOpen instead.
      for _ <- 1..50 do
        assert {:error, %RetriesExhausted{}} = ExternalService.call(service, fn -> :retry end)
      end

      refute ExternalService.blown?(service)
    end

    test "installs no fuse at all", %{service: service} do
      ExternalService.start(service, circuit_breaker: [tolerate: :infinity])

      assert :fuse.ask(service, :sync) == {:error, :not_found}
    end

    test "replaces a previously installed breaker, including a blown one", %{service: service} do
      ExternalService.start(service,
        circuit_breaker: [tolerate: 1, within: :timer.seconds(10)],
        retry: [max_attempts: 1]
      )

      Enum.each(1..2, fn _ -> CircuitBreaker.melt(service) end)
      assert ExternalService.blown?(service)

      # Restarting with :infinity must actually remove the old fuse, otherwise it
      # would keep answering :blown for the service name.
      ExternalService.start(service,
        circuit_breaker: [tolerate: :infinity],
        retry: [max_attempts: 1]
      )

      assert ExternalService.available?(service)
    end

    test "melt/1 and reset/1 stay well behaved", %{service: service} do
      ExternalService.start(service, circuit_breaker: [tolerate: :infinity])

      assert CircuitBreaker.melt(service) == :ok
      assert CircuitBreaker.reset(service) == :ok
      assert CircuitBreaker.ask(service) == :ok
    end

    test "cannot be combined with :fault_injection", %{service: service} do
      message =
        assert_raise ArgumentError, fn ->
          ExternalService.start(service,
            circuit_breaker: [tolerate: :infinity, fault_injection: 0.5]
          )
        end

      assert Exception.message(message) =~ "contradict each other"
    end
  end

  describe "tolerate: :infinity with the cluster backend" do
    test "a peer's trip does not melt a breaker that never opens" do
      service = :"#{__MODULE__}.cluster_infinity"
      on_exit(fn -> ExternalService.stop(service) end)

      ExternalService.start(service,
        circuit_breaker: [
          backend:
            {Cluster, [tolerate: :infinity, within: 10_000, reset: 60_000, nodes: fn -> [] end]}
        ],
        retry: [max_attempts: 1]
      )

      # remote_trip/1 melts `tolerate + 1` times to force this node's breaker
      # open. With :infinity there is nothing to melt, and the range would be
      # unbounded — so it must bail out instead.
      assert Cluster.remote_trip(service) == :ok
      assert ExternalService.available?(service)
    end
  end

  describe "limit: :infinity" do
    test "calls pass straight through, however many", %{service: service} do
      ExternalService.start(service,
        retry: [max_attempts: 1],
        rate_limit: [limit: :infinity, per: :timer.minutes(1), wait: false]
      )

      # A finite limit of any size would start shedding with `wait: false`.
      for n <- 1..500 do
        assert ExternalService.call(service, fn -> n end) == n
      end
    end

    test "the service reports as unlimited", %{service: service} do
      ExternalService.start(service,
        retry: [max_attempts: 1],
        rate_limit: [limit: :infinity, per: 1_000]
      )

      refute ExternalService.rate_limited?(service)
      assert RateLimiter.peek(service) == :ok
      assert RateLimiter.request(service) == :ok
    end

    test "does not warn about an unset :wait, since there is nothing to wait for" do
      service = :"#{__MODULE__}.no_wait_warning"
      on_exit(fn -> ExternalService.stop(service) end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          ExternalService.start(service,
            retry: [max_attempts: 1],
            rate_limit: [limit: :infinity, per: 1_000]
          )
        end)

      refute log =~ "sets no rate limit wait budget"
    end
  end
end
