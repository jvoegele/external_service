defmodule ExternalService.TuningGuideTest do
  use ExUnit.Case, async: true

  alias ExternalService.RetryOptions

  # `guides/tuning.md` opens with two tables of retry windows and says of them:
  #
  #   > Every number here was measured against the library rather than derived.
  #
  # That was true when it was written and had nothing keeping it true. This reads
  # the tables out of the guide itself and asserts every cell against
  # `RetryOptions.window/1`, so a change to the delay streams cannot leave the
  # guide quietly wrong — and neither can an edit to the guide.
  #
  # The guide is the fixture rather than a copy of it, so a change to how those
  # tables are laid out would otherwise match nothing and pass. Every parse step
  # asserts the shape it found for that reason: this suite must fail loudly rather
  # than silently stop checking anything.

  @guide Path.join([__DIR__, "..", "..", "guides", "tuning.md"])
  @external_resource @guide

  setup_all do
    {:ok, guide: File.read!(@guide)}
  end

  describe "the retry window table" do
    @header "| `:max_attempts` | `base: 10` | `base: 50` | `base: 100` | `base: 500` |"

    test "every cell matches RetryOptions.window/1", %{guide: guide} do
      bases = [10, 50, 100, 500]
      rows = rows_of_table(guide, @header)

      assert length(rows) == 6, "expected 6 attempt-count rows, found #{length(rows)}"

      for [attempts | cells] <- rows do
        max_attempts = to_integer(attempts)

        assert length(cells) == length(bases),
               "expected #{length(bases)} windows for max_attempts: #{max_attempts}, " <>
                 "found #{inspect(cells)}"

        for {base, documented} <- Enum.zip(bases, cells) do
          opts = [base: base, max_attempts: max_attempts]

          assert format(RetryOptions.window(opts)) == documented,
                 "guides/tuning.md says #{inspect(opts)} waits #{documented}, " <>
                   "but window/1 says #{RetryOptions.window(opts)}ms"
        end
      end
    end
  end

  describe "the :cap table" do
    @cap_header "| `:max_attempts` (`base: 100`) | uncapped | `cap: 1s` | `cap: 2s` |"

    test "every cell matches RetryOptions.window/1", %{guide: guide} do
      caps = [nil, 1_000, 2_000]
      rows = rows_of_table(guide, @cap_header)

      assert length(rows) == 3, "expected 3 rows in the :cap table, found #{length(rows)}"

      for [attempts | cells] <- rows do
        max_attempts = to_integer(attempts)

        assert length(cells) == length(caps),
               "expected #{length(caps)} windows for max_attempts: #{max_attempts}, " <>
                 "found #{inspect(cells)}"

        for {cap, documented} <- Enum.zip(caps, cells) do
          opts = [base: 100, max_attempts: max_attempts] ++ if(cap, do: [cap: cap], else: [])

          assert format(RetryOptions.window(opts)) == documented,
                 "guides/tuning.md says #{inspect(opts)} waits #{documented}, " <>
                   "but window/1 says #{RetryOptions.window(opts)}ms"
        end
      end
    end
  end

  describe "the worked examples" do
    test "the request-path example's window is inside the breaker window it is paired with" do
      window =
        RetryOptions.window(backoff: :exponential, base: 100, max_attempts: 4, expiry: 1_000)

      assert window == 700
      assert window < :timer.seconds(5)
    end

    test "the sizing example's window is the 1.5s the guide sizes its breaker from" do
      assert RetryOptions.window(
               backoff: :exponential,
               base: 100,
               cap: 2_000,
               max_attempts: 5,
               expiry: 10_000,
               jitter: true
             ) == 1_500
    end

    test "the background-job example spends its :expiry rather than its attempt count" do
      assert RetryOptions.window(
               backoff: :exponential,
               base: 500,
               cap: :timer.seconds(5),
               max_attempts: :infinity,
               expiry: :timer.seconds(30),
               jitter: true
             ) == 30_000
    end
  end

  # The body rows of the markdown table whose header line is `header`: everything
  # after the header and its `| --- |` separator, up to the first line that is no
  # longer part of the table.
  defp rows_of_table(guide, header) do
    lines = String.split(guide, "\n")

    assert header in lines,
           "guides/tuning.md no longer contains the table header this test reads:\n#{header}"

    lines
    |> Enum.drop_while(&(&1 != header))
    |> Enum.drop(2)
    |> Enum.take_while(&String.starts_with?(&1, "|"))
    |> Enum.map(&cells_of_row/1)
  end

  defp cells_of_row(row) do
    row
    |> String.split("|", trim: true)
    |> Enum.map(&(&1 |> String.trim() |> String.replace("*", "")))
  end

  # The first cell of a row is the attempt count, sometimes annotated: `**5** (default)`.
  defp to_integer(cell) do
    cell |> String.replace(" (default)", "") |> String.to_integer()
  end

  # The guide writes a window under a second as `30ms` and anything longer as
  # seconds to one decimal place — `1.5s`, `255.5s`. Comparing formatted strings
  # rather than raw milliseconds keeps the assertion honest about what the guide
  # actually claims: `base: 50, max_attempts: 6` is 1550ms, and the guide is right
  # to render that as `1.6s`.
  defp format(milliseconds) when milliseconds < 1_000, do: "#{milliseconds}ms"

  defp format(milliseconds) do
    seconds = Float.round(milliseconds / 1_000, 1)
    "#{:erlang.float_to_binary(seconds, decimals: 1)}s"
  end
end
