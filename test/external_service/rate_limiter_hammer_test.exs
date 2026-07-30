defmodule ExternalService.RateLimiter.HammerTest do
  @moduledoc """
  Verifies the Hammer adapter against a real Hammer rate limiter, so that the
  translation of Hammer's `{:allow, _}` / `{:deny, ms}` into the backend
  behaviour's `:ok` / `{:wait, ms}` is checked against the library rather than
  against an assumption about it.
  """

  use ExUnit.Case

  alias ExternalService.RateLimited
  alias ExternalService.RateLimiter.Hammer, as: HammerBackend
  alias ExternalService.Test.HammerLimiter

  @moduletag capture_log: true

  setup do
    start_supervised!({HammerLimiter, clean_period: :timer.minutes(1)})
    :ok
  end

  describe "init/2" do
    test "derives a key from the service name" do
      assert {:ok, config} =
               HammerBackend.init(:payments, limit: 5, per: 1_000, module: HammerLimiter)

      assert config.key == HammerBackend.default_key(:payments)
      assert config.limit == 5
      assert config.window == 1_000
    end

    test "accepts an explicit key so services can share a budget" do
      assert {:ok, config} =
               HammerBackend.init(:payments,
                 limit: 5,
                 per: 1_000,
                 module: HammerLimiter,
                 key: "shared"
               )

      assert config.key == "shared"
    end

    test "raises a helpful error when :module is missing" do
      assert_raise ArgumentError, ~r/requires a :module option/, fn ->
        HammerBackend.init(:payments, limit: 5, per: 1_000)
      end
    end

    test "raises when :module is not a module" do
      assert_raise ArgumentError, ~r/expects :module to be/, fn ->
        HammerBackend.init(:payments, limit: 5, per: 1_000, module: "nope")
      end
    end
  end

  describe "check/2" do
    test "admits calls within the limit and throttles beyond it" do
      {:ok, config} =
        HammerBackend.init(unique_service(),
          limit: 3,
          per: :timer.minutes(1),
          module: HammerLimiter
        )

      assert Enum.map(1..3, fn _ -> HammerBackend.check(:ignored, config) end) ==
               List.duplicate(:ok, 3)

      assert {:wait, retry_after} = HammerBackend.check(:ignored, config)
      assert is_integer(retry_after) and retry_after > 0
    end
  end

  describe "through ExternalService" do
    test "a service can be rate limited by a Hammer module" do
      service = unique_service()

      :ok =
        ExternalService.start(service,
          rate_limit: [
            limit: 2,
            per: :timer.minutes(1),
            wait: false,
            backend: {HammerBackend, module: HammerLimiter}
          ]
        )

      on_exit(fn -> ExternalService.stop(service) end)

      assert ExternalService.call(service, fn -> :one end) == :one
      assert ExternalService.call(service, fn -> :two end) == :two

      assert {:error, %RateLimited{context: %{service: ^service}}} =
               ExternalService.call(service, fn -> :three end)
    end
  end

  defp unique_service, do: :"hammer_test_#{System.unique_integer([:positive])}"
end
