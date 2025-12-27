# -------------------------------------------------------------------
# Sweeper GenServer
# -------------------------------------------------------------------
defmodule Queue.MessageTracker.Sweeper do
  use GenServer
  require Logger

  @sweep_interval :timer.minutes(5)
  @rotate_interval :timer.hours(12)

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    Queue.MessageTracker.init()
    schedule_sweep()
    schedule_rotation()
    {:ok, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    Logger.debug("Sweeper: removing expired messages...")
    Queue.MessageTracker.sweep()
    schedule_sweep()
    {:noreply, state}
  end

  @impl true
  def handle_info(:rotate, state) do
    Logger.info("Sweeper: rotating ETS generations...")
    Queue.MessageTracker.rotate()
    schedule_rotation()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval)
  defp schedule_rotation, do: Process.send_after(self(), :rotate, @rotate_interval)
end
