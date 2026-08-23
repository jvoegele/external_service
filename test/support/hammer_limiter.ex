defmodule ExternalService.TestSupport.HammerLimiter do
  @moduledoc false

  # A real Hammer rate limiter, used to verify that
  # `ExternalService.RateLimiter.Hammer` speaks Hammer's actual API rather than
  # an assumed one. Hammer is a test-only dependency of this library.

  use Hammer, backend: :ets
end
