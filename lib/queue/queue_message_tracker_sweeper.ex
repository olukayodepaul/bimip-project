defmodule Queue.MessageTracker.Sweeper do
  use GenServer
  require Logger

  # Intervals
  @sweep_interval :timer.minutes(30) # Sweep frequency
  @rotate_interval :timer.hours(12)  # Rotation frequency

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
    # Initialize MessageTracker tables
    Queue.MessageTracker.init()

    schedule_sweep()
    schedule_rotation()

    Logger.info("MessageTracker.Sweeper started. Rotation: 12h, Sweep: 30m")
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    Logger.debug("Sweeper: Starting background expiration scan...")

    # Run sweep asynchronously so GenServer isn't blocked
    Task.start(fn -> Queue.MessageTracker.sweep() end)

    schedule_sweep()
    {:noreply, state}
  end

  @impl true
  def handle_info(:rotate, state) do
    Logger.info("Sweeper: Performing generational rotation...")

    # Perform rotation and get minimum valid offset post-rotation
    min_valid_offset = Queue.MessageTracker.rotate()

    # Adjust bookmarks only if current < min_valid_offset
    Enum.each(Queue.MessageTracker.affected_devices(), fn {device_id, user, partition_id} ->
      current = Queue.DeviceBookmark.get(device_id, user, partition_id)
      if current < min_valid_offset do
        Queue.DeviceBookmark.set(device_id, user, partition_id, min_valid_offset)
      end
    end)

    schedule_rotation()
    {:noreply, state}
  end

  # -------------------------------------------------------------------
  # Internal Helpers
  # -------------------------------------------------------------------
  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval)
  defp schedule_rotation, do: Process.send_after(self(), :rotate, @rotate_interval)
end
