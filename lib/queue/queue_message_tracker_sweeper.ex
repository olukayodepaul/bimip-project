defmodule Queue.MessageTracker.Sweeper do
  use GenServer
  require Logger

  # Intervals
  @sweep_interval :timer.minutes(30) # Increased to reduce CPU scanning frequency
  @rotate_interval :timer.hours(12)

  # -------------------------------------------------------------------
  # Client API
  # -------------------------------------------------------------------
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end


  # -------------------------------------------------------------------
  # Callbacks
  # -------------------------------------------------------------------
  @impl true
  def init(_opts) do
    # Ensure tables are initialized when the sweeper starts
    Queue.MessageTracker.init()

    schedule_sweep()
    schedule_rotation()

    Logger.info("MessageTracker.Sweeper started. Rotation: 12h, Sweep: 30m")
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    # Only run sweep if you REALLY need to clear expired items before the 12h rotation
    Logger.debug("Sweeper: Starting background expiration scan...")

    # We use a Task to prevent the GenServer from blocking incoming messages
    # if the sweep takes too long.
    Task.start(fn -> Queue.MessageTracker.sweep() end)

    schedule_sweep()
    {:noreply, state}
  end

  @impl true
  def handle_info(:rotate, state) do
    Logger.info("Sweeper: Performing generational rotation...")

    # Rotation is already throttled inside your MessageTracker.rotate function
    Queue.MessageTracker.rotate()

    schedule_rotation()
    {:noreply, state}
  end

  # -------------------------------------------------------------------
  # Internal Helpers
  # -------------------------------------------------------------------
  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval)
  defp schedule_rotation, do: Process.send_after(self(), :rotate, @rotate_interval)
end
