defmodule ExternalService.Application do
  @moduledoc false

  use Application

  def start(_type, _args) do
    children = [
      # Starts a worker by calling: ExternalService.Worker.start_link(arg)
      # {ExternalService.Worker, arg},
      {ExternalService.Metrics, :ok}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ExternalService.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
