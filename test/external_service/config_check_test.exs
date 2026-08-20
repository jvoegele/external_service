defmodule ExternalService.ConfigCheckTest do
  # Not async: several of these set application environment, which is global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias ExternalService.ConfigCheck

  setup do
    original = Application.fetch_env(:external_service, :on_suspicious_config)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:external_service, :on_suspicious_config, value)
        :error -> Application.delete_env(:external_service, :on_suspicious_config)
      end
    end)

    :ok
  end

  defp checks(options),
    do: options |> then(&ConfigCheck.run(:a_service, &1)) |> Enum.map(& &1.check)

  defp message(options, check) do
    :a_service
    |> ConfigCheck.run(options)
    |> Enum.find(&(&1.check == check))
    |> then(& &1.message)
  end

  describe "a window narrower than the failures it counts" do
    test "flags a hand-set window that a sequential caller could not fill" do
      # Three failing calls at a 1.5s retry window each need 4.5s; the window is 1s.
      options = [
        circuit_breaker: [tolerate: 3, within: 1_000],
        retry: [base: 100, max_attempts: 5]
      ]

      assert :narrow_window in checks(options)

      message = message(options, :narrow_window)
      assert message =~ "narrower than the failures it has to count"
      assert message =~ "1.5s per call"
      # Three calls need 4.5s, but the suggestion is what `:auto` would install
      # rather than the bare minimum — and `:auto` never goes below ten seconds.
      assert message =~ ":timer.seconds(10)"
    end

    test "says plainly that under :per_call this depends on traffic" do
      # Opening a per-call breaker always takes several calls, and how fast those
      # arrive is not in the configuration. The check must not claim more than it
      # can know.
      options = [
        circuit_breaker: [tolerate: 3, within: 1_000, melt: :per_call],
        retry: [base: 100, max_attempts: 5]
      ]

      message = message(options, :narrow_window)
      assert message =~ "one after another never opens it"
      assert message =~ "Concurrent callers still can"
    end

    test "under :per_attempt it is a single call's own melts, and says so" do
      options = [
        circuit_breaker: [tolerate: 10, within: 1_000, melt: :per_attempt],
        retry: [base: 100, max_attempts: 5]
      ]

      message = message(options, :narrow_window)
      assert message =~ "that call's melts land"
      assert message =~ "never accumulate to the 10 it tolerates"
    end

    test "says nothing about a window that is wide enough" do
      options = [
        circuit_breaker: [tolerate: 3, within: :timer.seconds(10)],
        retry: [base: 100, max_attempts: 5]
      ]

      refute :narrow_window in checks(options)
    end

    test "says nothing when :within sizes itself" do
      # `:auto` is the default and is computed from these very options.
      options = [circuit_breaker: [tolerate: 20], retry: [base: 500, max_attempts: 8]]

      refute :narrow_window in checks(options)
    end
  end

  describe "a call that trips its own breaker" do
    test "flags per-attempt melting whose attempt count exceeds the whole budget" do
      options = [circuit_breaker: [melt: :per_attempt, tolerate: 5], retry: [max_attempts: 8]]

      assert :self_tripping_call in checks(options)

      message = message(options, :self_tripping_call)
      assert message =~ "melts the breaker more times than it tolerates"
      assert message =~ "give up sooner, not later"
      assert message =~ "melt: :per_call"
    end

    test "cannot happen under the default melt semantics" do
      options = [circuit_breaker: [melt: :per_call, tolerate: 5], retry: [max_attempts: 8]]

      refute :self_tripping_call in checks(options)
    end

    test "says nothing when the budget is larger than the attempt count" do
      options = [circuit_breaker: [melt: :per_attempt, tolerate: 20], retry: [max_attempts: 8]]

      refute :self_tripping_call in checks(options)
    end
  end

  describe "unbounded retrying" do
    test "flags it under :per_attempt, where the breaker is the only backstop" do
      options = [
        circuit_breaker: [melt: :per_attempt, tolerate: 20, within: 60_000],
        retry: [max_attempts: :infinity]
      ]

      assert :unbounded_retrying in checks(options)
      assert message(options, :unbounded_retrying) =~ "not a reliable backstop"
    end

    test "an :expiry bounds it" do
      options = [
        circuit_breaker: [melt: :per_attempt, tolerate: 20, within: 60_000],
        retry: [max_attempts: :infinity, expiry: 30_000]
      ]

      refute :unbounded_retrying in checks(options)
    end

    test "is left to start/2 to reject outright under :per_call" do
      # `validate_melt_bound!/3` raises on this, because there it hangs rather
      # than merely misbehaving. A warning would be redundant and softer than the
      # truth.
      options = [circuit_breaker: [melt: :per_call], retry: [max_attempts: :infinity]]

      refute :unbounded_retrying in checks(options)

      assert_raise ArgumentError, ~r/never give up/, fn ->
        ExternalService.start(:"per-call-unbounded-check", options)
      end
    end
  end

  describe "uncapped exponential backoff" do
    test "flags a high attempt count with no cap" do
      options = [retry: [base: 100, max_attempts: 10]]

      assert :uncapped_backoff in checks(options)

      message = message(options, :uncapped_backoff)
      assert message =~ "51.1s"
      assert message =~ "each delay is worth all the previous ones combined"
    end

    test "a cap is the fix, so a capped configuration is silent" do
      refute :uncapped_backoff in checks(retry: [base: 100, max_attempts: 10, cap: 2_000])
    end

    test "the default attempt count needs no cap" do
      refute :uncapped_backoff in checks(retry: [base: 100, max_attempts: 5])
    end

    test "linear backoff does not run away, so it is not flagged" do
      refute :uncapped_backoff in checks(retry: [backoff: :linear, base: 100, max_attempts: 20])
    end

    test "suppresses the window finding, whose advice would follow from this one" do
      # An uncapped 51s retry window makes any breaker window look too narrow, and
      # the honest fix is the cap rather than a 154-second breaker window sized to
      # accommodate it. Root cause only, until it is fixed.
      options = [
        circuit_breaker: [tolerate: 3, within: 1_000],
        retry: [base: 100, max_attempts: 10]
      ]

      assert checks(options) == [:uncapped_backoff]

      # Capped, the window finding surfaces with advice worth taking.
      capped = put_in(options, [:retry, :cap], 2_000)

      assert checks(capped) == [:narrow_window]
      # The suggestion is what `:auto` would install, headroom included, rather
      # than the bare minimum that triggered the finding.
      assert message(capped, :narrow_window) =~ ":timer.seconds(67)"
    end
  end

  describe "reporting" do
    test "logs findings from start/2" do
      log =
        capture_log(fn ->
          ExternalService.start(:"reported-service",
            circuit_breaker: [tolerate: 3, within: 1_000],
            retry: [base: 100, max_attempts: 5]
          )
        end)

      on_exit(fn -> ExternalService.stop(:"reported-service") end)

      assert log =~ "narrower than the failures it has to count"
    end

    test ":raise turns a finding into a start/2 failure" do
      Application.put_env(:external_service, :on_suspicious_config, :raise)

      assert_raise ArgumentError, ~r/narrower than the failures/, fn ->
        ExternalService.start(:"raising-service",
          circuit_breaker: [tolerate: 3, within: 1_000],
          retry: [base: 100, max_attempts: 5]
        )
      end
    end

    test ":ignore silences them" do
      Application.put_env(:external_service, :on_suspicious_config, :ignore)

      log =
        capture_log(fn ->
          ExternalService.start(:"ignoring-service",
            circuit_breaker: [tolerate: 3, within: 1_000],
            retry: [base: 100, max_attempts: 5]
          )
        end)

      on_exit(fn -> ExternalService.stop(:"ignoring-service") end)

      refute log =~ "narrower than the failures"
    end

    test "a sound configuration is silent" do
      log =
        capture_log(fn ->
          ExternalService.start(:"quiet-service",
            circuit_breaker: [tolerate: 3, within: :timer.seconds(10)],
            retry: [base: 100, max_attempts: 5, jitter: true]
          )
        end)

      on_exit(fn -> ExternalService.stop(:"quiet-service") end)

      refute log =~ "circuit breaker"
    end
  end

  describe "at compile time" do
    test "warns where the configuration is written, with a file and line" do
      warning =
        capture_io(:stderr, fn ->
          compile("""
          defmodule CompileCheckNarrow do
            use ExternalService,
              name: :compile_check_narrow,
              circuit_breaker: [tolerate: 3, within: :timer.seconds(1)],
              retry: [base: 100, max_attempts: 5]
          end
          """)
        end)

      assert warning =~ "narrower than the failures it has to count"
      # `:timer.seconds(1)` reached the check as 1000, which is the whole reason
      # this runs from a @before_compile hook rather than from __using__.
      assert warning =~ "`within: 1000`"
      assert warning =~ "lib/compile_check_example.ex"
    end

    test "a sound configuration compiles silently" do
      warning =
        capture_io(:stderr, fn ->
          compile("""
          defmodule CompileCheckQuiet do
            use ExternalService,
              name: :compile_check_quiet,
              circuit_breaker: [tolerate: 3, within: :timer.seconds(10)],
              retry: [base: 100, max_attempts: 5]
          end
          """)
        end)

      assert warning == ""
    end

    test ":raise fails the compilation" do
      Application.put_env(:external_service, :on_suspicious_config, :raise)

      assert_raise ArgumentError, ~r/narrower than the failures/, fn ->
        compile("""
        defmodule CompileCheckRaising do
          use ExternalService,
            name: :compile_check_raising,
            circuit_breaker: [tolerate: 3, within: :timer.seconds(1)],
            retry: [base: 100, max_attempts: 5]
        end
        """)
      end
    end
  end

  describe "tolerance of configurations it cannot read" do
    # This runs at compile time against options a child spec may still complete,
    # so a diagnostic that breaks the build it was meant to inform is worse than
    # one that stays quiet.

    test "says nothing about options it cannot make sense of" do
      assert checks(circuit_breaker: [tolerate: 3], retry: [base: "not a number"]) == []
      assert checks(circuit_breaker: "nonsense") == []
      assert checks(retry: [max_attempts: 0]) == []
      assert ConfigCheck.run(:a_service, :not_even_a_list) == []
      assert ConfigCheck.run(:a_service, []) == []
    end

    test "reads a RetryOptions struct as well as a keyword list" do
      options = [
        circuit_breaker: [tolerate: 3, within: 1_000],
        retry: %ExternalService.RetryOptions{base: 100, max_attempts: 5}
      ]

      assert :narrow_window in checks(options)
    end
  end

  defp compile(source) do
    modules = Code.compile_string(source, "lib/compile_check_example.ex")

    on_exit(fn ->
      Enum.each(modules, fn {module, _binary} ->
        :code.purge(module)
        :code.delete(module)
      end)
    end)

    modules
  end
end
