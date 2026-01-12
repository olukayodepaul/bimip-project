defmodule Queue.BimipCompactor do
  @moduledoc """
  BimipCompactor v3.2: The Manifest-Synchronized Janitor.
  """
  use GenServer
  require Logger

  @base_dir "data/bimip"
  @archive_dir "data/archive"
  @num_shards 64

  # @check_interval :timer.hours(12)
  # @retention_seconds 604_800 # 7 Days
  @check_interval :timer.minutes(5)      # Runs every 10 minutes
  @retention_seconds 60 * 2                  # Files older than 60 seconds are "expired"


  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def init(state) do
    File.mkdir_p!(@archive_dir)
    schedule_check()
    {:ok, state}
  end

  # 1. Main Maintenance Loop Log
  def handle_info(:check, state) do
    start_time = System.monotonic_time(:millisecond)
    Logger.info("🧹 [Compactor] STARTING maintenance cycle...")

    for s <- 0..(@num_shards - 1), do: process_shard(s)

    elapsed = System.monotonic_time(:millisecond) - start_time
    Logger.info("✅ [Compactor] FINISHED maintenance cycle in #{elapsed}ms. Next run in 2 mins.")

    schedule_check()
    {:noreply, state}
  end

  defp process_shard(shard) do
    manifest_path = Path.join(@base_dir, "shard_#{shard}.manifest")

    # ✅ Fix: Manifest now stores a Map, not just a raw integer
    active_seg_id = case File.read(manifest_path) do
      {:ok, bin} ->
        data = :erlang.binary_to_term(bin)
        data.active_base
      _ -> nil
    end

    if active_seg_id do
      all_log_files =
        Path.wildcard(Path.join(@base_dir, "shard_#{shard}_*.log"))
        |> Enum.sort_by(&extract_id/1)

      handle_retention_and_archival(shard, all_log_files, active_seg_id)
    end
  end

 defp handle_retention_and_archival(shard, files, active_seg_id) do
    now = System.system_time(:second)

    to_archive = files
      |> Enum.filter(fn f ->
        # ✅ Optimization: Use the timestamp from the filename
        # This avoids calling File.stat on every file every 5 minutes
        {_base, ts} = extract_full_meta(f)
        (now - ts) > @retention_seconds
      end)
      |> Enum.reject(fn f ->
        {base, _ts} = extract_full_meta(f)
        base == active_seg_id
      end)

    if to_archive != [] do
      # Extract just the Base Offset IDs for the pointer repair logic
      expired_ids = Enum.map(to_archive, fn f ->
        {base, _ts} = extract_full_meta(f)
        base
      end)

      Logger.info("📦 [Shard #{shard}] Archiving #{length(to_archive)} segments: #{inspect(expired_ids)}")

      repair_and_forward_pointers(shard, expired_ids, active_seg_id)

      Enum.each(to_archive, fn log_path ->
        idx_path = String.replace(log_path, ".log", ".idx")
        Queue.FDPoolShard.close_fd(shard, log_path)
        Queue.FDPoolShard.close_fd(shard, idx_path)
        do_move(log_path)
        do_move(idx_path)
      end)
    end
  end


  defp repair_and_forward_pointers(shard, archived_ids, current_active_seg) do
    cache = :"device_bookmarks_cache_#{shard}"

    :ets.foldl(fn {user, device_map}, _acc ->
      updated_map = Enum.reduce(device_map, %{}, fn {dev_id, {seg, off, phys}}, acc ->
        cond do
          dev_id == "__anchor__" and (seg in archived_ids or seg == 0) ->
            # Log individual user teleports during testing if needed
            # Logger.debug("🚀 Teleporting #{user} to -1")
            Map.put(acc, dev_id, {current_active_seg, off, -1})

          seg in archived_ids -> acc
          true -> Map.put(acc, dev_id, {seg, off, phys})
        end
      end)
      :ets.insert(cache, {user, updated_map})
    end, :ok, cache)

    Queue.DeviceBookmark.persist_shard(shard)
  end

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
    # shard_0_1000_1736700000.log
    parts = path |> Path.basename() |> String.replace(".log", "") |> String.split("_")
    # [shard, 0, 1000, 1736700000]
    base = String.to_integer(Enum.at(parts, 2))
    ts = String.to_integer(Enum.at(parts, 3))
    {base, ts}
  end

  defp schedule_check, do: Process.send_after(self(), :check, @check_interval)
end
