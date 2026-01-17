defmodule Queue.BimipCompactor do
  @moduledoc """
  BimipCompactor v3.3: Lean Bookmark Janitor.
  Handles Case A (Time-based deletion) and Case B (Segment-based deletion).
  """
  use GenServer
  require Logger

  @base_dir "data/bimip"
  @archive_dir "data/archive"
  @num_shards 64

  @check_interval :timer.hours(4)      # Run every 5 minutes
  @retention_seconds 20060 * 2              # 2 Minutes retention for testing

  # ------------------------------------------------------------------
  # GENSERVER
  # ------------------------------------------------------------------

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def init(state) do
    File.mkdir_p!(@archive_dir)
    schedule_check()
    {:ok, state}
  end

  def handle_info(:check, state) do
    start_time = System.monotonic_time(:millisecond)
    Logger.info("🧹 [Compactor] STARTING maintenance cycle...")

    for s <- 0..(@num_shards - 1), do: process_shard(s)

    elapsed = System.monotonic_time(:millisecond) - start_time
    Logger.info("✅ [Compactor] FINISHED maintenance cycle in #{elapsed}ms.")

    schedule_check()
    {:noreply, state}
  end

  # ------------------------------------------------------------------
  # SHARD PROCESSING
  # ------------------------------------------------------------------

  defp process_shard(shard) do
    shard_dir = Path.join(@base_dir, "shard_#{shard}")
    manifest_path = Path.join(shard_dir, "shard_#{shard}.manifest")

    active_seg_id = case File.read(manifest_path) do
      {:ok, bin} ->
        data = :erlang.binary_to_term(bin)
        data.active_base
      _ -> nil
    end

    if active_seg_id do
      # Find all log files in this shard's directory
      all_log_files =
        Path.wildcard(Path.join(shard_dir, "shard_#{shard}_*.log"))
        |> Enum.sort_by(&extract_id/1)

      handle_retention_and_archival(shard, all_log_files, active_seg_id)
    end
  end

  defp handle_retention_and_archival(shard, files, active_seg_id) do
    now = System.system_time(:second)

    to_archive = files
      |> Enum.filter(fn f ->
        {_base, ts} = extract_full_meta(f)
        (now - ts) > @retention_seconds
      end)
      |> Enum.reject(fn f ->
        {base, _ts} = extract_full_meta(f)
        base == active_seg_id
      end)

    if to_archive != [] do
      archived_ids = Enum.map(to_archive, fn f ->
        {base, _} = extract_full_meta(f)
        base
      end)

      Logger.info("📦 [Shard #{shard}] Archiving segments: #{inspect(archived_ids)}")

      # Fix: Repair bookmarks using the new Lean strategy logic
      repair_lean_bookmarks(shard, archived_ids, active_seg_id)

      Enum.each(to_archive, fn log_path ->
        idx_path = String.replace(log_path, ".log", ".idx")
        Queue.FDPoolShard.close_fd(shard, log_path)
        Queue.FDPoolShard.close_fd(shard, idx_path)
        do_move(log_path)
        do_move(idx_path)
      end)
    end
  end

  # ------------------------------------------------------------------
  # REPAIR LOGIC (Lean Bookmark Strategy)
  # ------------------------------------------------------------------

  defp repair_lean_bookmarks(shard, archived_ids, active_seg_id) do
    cache = :"device_bookmarks_cache_#{shard}"
    now = System.system_time(:second)

    :ets.foldl(fn {user, device_map}, _acc ->
      # Filter and update the map based on the two deletion rules
      updated_map = Enum.reduce(device_map, %{}, fn
        # Case 1: The Anchor
        {"__anchor__", {seg, off}}, acc ->
          if seg in archived_ids do
            # Forward the anchor to the current active segment
            Map.put(acc, "__anchor__", {active_seg_id, off})
          else
            Map.put(acc, "__anchor__", {seg, off})
          end

        # Case 2: Device Bookmarks {offset, timestamp}
        {dev_id, {off, ts}}, acc ->
          cond do
            # Rule A: Delete if timestamp is older than retention
            (now - ts) > @retention_seconds ->
              acc

            # Rule B: Delete if the offset is inside an archived segment range
            # (Requires checking against archived_ids min/max if segments are contiguous)
            offset_in_archived_range?(off, archived_ids) ->
              acc

            true ->
              Map.put(acc, dev_id, {off, ts})
          end
      end)

      :ets.insert(cache, {user, updated_map})
    end, :ok, cache)

    # Persist the cleaned map back to shard_X.bin
    Queue.DeviceBookmark.persist_shard(shard)
  end

  defp offset_in_archived_range?(off, archived_ids) do
    # Simple check: if offset is less than the max ID being archived,
    # it belongs to an old segment.
    max_archived = Enum.max(archived_ids)
    off < (max_archived + 100) # Assuming 100 msgs per segment
  end

  # ------------------------------------------------------------------
  # HELPERS
  # ------------------------------------------------------------------

  defp do_move(old_path) do
    if File.exists?(old_path) do
      new_path = Path.join(@archive_dir, Path.basename(old_path))
      File.rename!(old_path, new_path)
    end
  rescue
    e -> Logger.error("Archival Rename Failed: #{inspect(e)}")
  end

  defp extract_id(path) do
    {base, _ts} = extract_full_meta(path)
    base
  end

  defp extract_full_meta(path) do
    # Expected format: shard_X_BaseOffset_Timestamp.log
    parts = path |> Path.basename() |> String.replace(".log", "") |> String.split("_")
    base = String.to_integer(Enum.at(parts, 2))
    ts = String.to_integer(Enum.at(parts, 3))
    {base, ts}
  end

  defp schedule_check, do: Process.send_after(self(), :check, @check_interval)
end
