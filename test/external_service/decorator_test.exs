defmodule ExternalService.DecoratorTest do
  use ExUnit.Case

  alias ExternalService.RetriesExhausted

  @moduletag capture_log: true

  @service :decorator_test_service

  # A module that exercises the decorators across the shapes of `def` that the
  # underlying `decorator` library is historically fussy about: single clause,
  # multiple clauses, default arguments, and guards (the last three using the
  # documented empty-function-head pattern).
  defmodule Client do
    use ExternalService.Decorator

    @service :decorator_test_service

    # Single clause, plain value result.
    @decorate external_call(@service)
    def ok(x), do: {:ok, x}

    # Body drives a retry via the `:retry` protocol.
    @decorate external_call(@service)
    def flaky do
      count = Process.get(:flaky, 0) + 1
      Process.put(:flaky, count)
      if count < 3, do: :retry, else: {:ok, count}
    end

    # Soft failure: returns the structured error.
    @decorate external_call(@service)
    def always_retry, do: :retry

    # Multiple clauses (decorate the function head).
    @decorate external_call(@service)
    def classify(value)
    def classify(:a), do: {:ok, :a}
    def classify(:b), do: {:ok, :b}

    # Default argument (decorate the function head).
    @decorate external_call(@service)
    def greet(name, greeting \\ "hi")
    def greet(name, greeting), do: {:ok, "#{greeting} #{name}"}

    # Guard.
    @decorate external_call(@service)
    def positive(n) when n > 0, do: {:ok, n}

    # Per-call retry options: a `:retry_on` predicate retries an unmodified body
    # that returns the underlying client's own result shape.
    @decorate external_call(@service, retry_on: &match?({:error, _}, &1))
    def adapted do
      count = Process.get(:adapted, 0) + 1
      Process.put(:adapted, count)
      if count < 3, do: {:error, :nope}, else: {:ok, count}
    end

    # Raising variant: returns on success...
    @decorate external_call!(@service)
    def bang(x), do: {:ok, x}

    # ...and raises the structured error on failure.
    @decorate external_call!(@service)
    def bang_retry, do: :retry
  end

  setup do
    Process.delete(:flaky)
    Process.delete(:adapted)

    ExternalService.start(@service,
      circuit_breaker: [tolerate: 100, within: 10_000],
      retry: [backoff: :linear, base: 0, max_attempts: 3]
    )

    on_exit(fn -> ExternalService.stop(@service) end)
    :ok
  end

  describe "external_call/1" do
    test "wraps a single-clause body and returns its value" do
      assert Client.ok(:payload) == {:ok, :payload}
    end

    test "a :retry return from the body drives a retry" do
      assert Client.flaky() == {:ok, 3}
      assert Process.get(:flaky) == 3
    end

    test "returns a structured error when retries are exhausted" do
      assert {:error, %RetriesExhausted{context: %{service: @service}}} = Client.always_retry()
    end

    test "works across multiple clauses via the function head" do
      assert Client.classify(:a) == {:ok, :a}
      assert Client.classify(:b) == {:ok, :b}
    end

    test "works with a default argument via the function head" do
      assert Client.greet("Bob") == {:ok, "hi Bob"}
      assert Client.greet("Bob", "yo") == {:ok, "yo Bob"}
    end

    test "works with a guard" do
      assert Client.positive(5) == {:ok, 5}
    end
  end

  describe "external_call/2 with per-call retry options" do
    test "a :retry_on predicate retries an unmodified body" do
      assert Client.adapted() == {:ok, 3}
      assert Process.get(:adapted) == 3
    end
  end

  describe "external_call!" do
    test "returns the body's value on success" do
      assert Client.bang(:payload) == {:ok, :payload}
    end

    test "raises the structured error on failure" do
      assert_raise RetriesExhausted, fn -> Client.bang_retry() end
    end
  end
end
