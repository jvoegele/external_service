defmodule ExternalService.Metrics do
  @moduledoc """
  Metrics collection and reporting for events such as fuse melted or blown, or rate limit
  exceeded, etc.
  """

  use GenServer
  require Logger

  @server __MODULE__

  def start_link(:ok) do
    GenServer.start_link(__MODULE__, :ok, name: @server)
  end

  def init(state) do
    {:ok, state}
  end

  def fuse_ok(fuse_name) do
    GenServer.cast(@server, {:fuse_ok, fuse_name, self()})
  end

  def fuse_melt(fuse_name) do
    GenServer.cast(@server, {:fuse_melt, fuse_name, self()})
  end

  def fuse_blown(fuse_name) do
    GenServer.cast(@server, {:fuse_blown, fuse_name, self()})
  end

  def handle_cast({:fuse_ok, fuse_name, caller}, state) do
    {:noreply, state}
  end

  def handle_cast({:fuse_melt, fuse_name, caller}, state) do
    Logger.info("Fuse melt for service #{inspect(fuse_name)}")
    {:noreply, state}
  end

  def handle_cast({:fuse_blown, fuse_name, caller}, state) do
    Logger.info("Fuse blown for service #{inspect(fuse_name)}")
    {:noreply, state}
  end
end
