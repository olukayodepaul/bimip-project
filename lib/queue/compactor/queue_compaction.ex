defmodule Queue.BimipCompactor do
  @moduledoc """
  BimipCompactor v4.0: The Maintenance Scheduler.

  This module acts as the central heartbeat for the system.
  It replaces the old v3.3 logic that manually scanned files and looped through users.

  CORE DESIGN:
  1. Trigger: Wakes up every 4 hours.
  2. Dispatch: Sends a :trigger_maintenance signal to each Shard GenServer.
  3. Safety: Uses `GenServer.cast` so it doesn't block if a Shard is busy flushing.
  4. Offloading: Physical file moves, FD closing, and Manifest updates happen
     inside the Shard process to respect the :busy/:idle lifecycle.
  """
  use GenServer
  require Logger

  @num_shards 64
  # Frequency of maintenance cycles
  @check_interval :timer.seconds(10)
  # @check_interval :timer.hours(4)
  # Root directory for archived data
  @archive_root "data/archive"

  # ------------------------------------------------------------------
  # CLIENT API
  # ------------------------------------------------------------------

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc "Force an immediate maintenance cycle across all shards (useful for testing)."
  def force_maintenance do
    send(__MODULE__, :check)
  end

  # ------------------------------------------------------------------
  # GENSERVER CALLBACKS
  # ------------------------------------------------------------------

  def init(state) do
    # Ensure the central archive folder exists at startup
    File.mkdir_p!(@archive_root)

    # Schedule the recurring check
    schedule_check()

    Logger.info("🚀 [Compactor] Scheduler v4.0 initialized. Interval: 4 hours.")
    {:ok, state}
  end

  def handle_info(:check, state) do
    start_time = System.monotonic_time(:millisecond)
    Logger.info("🧹 [Compactor] Dispatching maintenance signals to #{@num_shards} shards...")

    # Iterate through shard IDs and signal their respective GenServers
    for s <- 0..(@num_shards - 1) do
      shard_name = :"bimip_shard_#{s}" # Added "bimip_"

      case Process.whereis(shard_name) do
        nil ->
          # Shard might not be started yet or crashed; skip and move on
          :skip

        pid ->
          # Signal the shard to perform its own internal cleanup.
          # This ensures the shard is in an :idle state before touching files.
          GenServer.cast(pid, :trigger_maintenance)
      end
    end

    elapsed = System.monotonic_time(:millisecond) - start_time
    Logger.info("✅ [Compactor] Maintenance signals dispatched in #{elapsed}ms.")

    # Re-schedule for the next 4-hour window
    schedule_check()
    {:noreply, state}
  end

  # ------------------------------------------------------------------
  # PRIVATE HELPERS
  # ------------------------------------------------------------------

  defp schedule_check do
    Process.send_after(self(), :check, @check_interval)
  end
end
