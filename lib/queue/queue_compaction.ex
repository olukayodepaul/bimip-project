defmodule Queue.BimipCompactor do
  @moduledoc """
  The 'Janitor' of the system.
  Handles TTL filtering, 5-file buffering, and pointer relocation.
  """
  use GenServer
  require Logger

  @base_dir "data/bimip"
  @merge_buffer 5
  @check_interval 60_000
  @retention_seconds 0 # Instant test mode
  @num_shards 64

  def start_link(_), do: GenServer.start_link(__MODULE__, %{saved_bytes: 0}, name: __MODULE__)

  def init(state) do
    File.mkdir_p!(@base_dir)
    schedule_check()
    {:ok, state}
  end

  def handle_info(:check, state) do
    Logger.info("Bimip Maintenance Cycle Starting...")

    # 1. Flush active buffers in shards
    for s <- 0..(@num_shards - 1) do
      if pid = Process.whereis(:"bimip_shard_#{s}"), do: send(pid, :flush_buffer)
    end

    # 2. Perform Compaction
    # Inside compact_shard -> perform_merge -> update_bookmarks_after_merge,
    # we now call persist_shard(s), so the data is already safe.
    shard_results = for s <- 0..(@num_shards - 1), do: compact_shard(s)

    # 3. REMOVED: Queue.DeviceBookmark.persist_all()
    # This saves 64 disk writes every minute.

    schedule_check()
    {:noreply, %{state | saved_bytes: state.saved_bytes + Enum.sum(shard_results)}}
  end

  defp compact_shard(shard) do
    segments =
      Path.wildcard(Path.join(@base_dir, "shard_#{shard}_*.log"))
      |> Enum.sort_by(&extract_segment_id/1)

    if length(segments) > @merge_buffer + 1 do
      {to_consider, _protected} = Enum.split(segments, length(segments) - @merge_buffer)
      now = System.system_time(:second)

      files_to_merge = Enum.filter(to_consider, fn f ->
        (now - extract_segment_id(f)) > @retention_seconds
      end)

      if length(files_to_merge) >= 2 do
        perform_merge(shard, files_to_merge)
      else
        0
      end
    else
      0
    end
  end

  defp perform_merge(shard, files) do
    max_deleted_seg = files |> List.last() |> extract_segment_id()
    new_seg_id = System.system_time(:second)
    new_log_path = Path.join(@base_dir, "shard_#{shard}_#{new_seg_id}.log")

    try do
      {:ok, out_fd} = :file.open(new_log_path, [:write, :raw, :binary])

      # Build the position map during the file write
      final_pos_map = Enum.reduce(files, %{}, fn src_path, acc_map ->
        binary = File.read!(src_path)
        {:ok, current_offset} = :file.position(out_fd, :cur)
        seg_id = extract_segment_id(src_path)

        :ok = :file.write(out_fd, binary)
        Map.put(acc_map, seg_id, current_offset)
      end)

      :file.sync(out_fd)
      :file.close(out_fd)

      rebuild_index(new_log_path)

      # UPDATE BOOKMARKS (with Anchor Fix)
      update_bookmarks_after_merge(shard, max_deleted_seg, new_seg_id, final_pos_map)

      # Cleanup
      Enum.each(files, fn f ->
        Queue.FDPoolShard.close_fd(shard, f)
        File.rm(f)
        File.rm(String.replace(f, ".log", ".idx"))
      end)

      Logger.info("✅ Shard #{shard}: Merged #{length(files)} files into #{new_seg_id}")
      1
    rescue
      e ->
        Logger.error("❌ Merge failed for shard #{shard}: #{inspect(e)}")
        0
    end
  end

  ### FIXED FUNCTION ###
  defp update_bookmarks_after_merge(shard, max_deleted_seg, new_seg_id, pos_map) do
    cache = :"device_bookmarks_cache_#{shard}"

    :ets.foldl(fn {user, device_map}, _acc ->
      updated_map = Enum.into(device_map, %{}, fn {device_id, {seg, log_off, phys}} ->
        if seg <= max_deleted_seg do
          if device_id == "__anchor__" do
            # The anchor represents the start of history.
            # It moves to the very first byte of the new combined file.
            {"__anchor__", {new_seg_id, 1, 0}}
          else
            # Normal devices move to their relative physical position in the new file
            new_phys = Map.get(pos_map, seg, 0)
            {device_id, {new_seg_id, log_off, new_phys}}
          end
        else
          # Device is on a file newer than the merge, leave it alone
          {device_id, {seg, log_off, phys}}
        end
      end)
      :ets.insert(cache, {user, updated_map})
    end, :ok, cache)

    # Trigger a specific write for this shard to ensure .bin is updated immediately
    Queue.DeviceBookmark.persist_shard(shard)
  end

  defp schedule_check, do: Process.send_after(self(), :check, @check_interval)

  defp extract_segment_id(path) do
    path |> Path.basename() |> String.split("_") |> List.last() |> String.replace(".log", "") |> String.to_integer()
  end

  defp rebuild_index(log_path) do
    idx_path = String.replace(log_path, ".log", ".idx")
    File.touch!(idx_path)
  end
end
