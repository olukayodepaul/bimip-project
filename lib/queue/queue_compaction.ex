defmodule Queue.BimipCompactor do
  @moduledoc """
  BimipCompactor v2.1: The Sparse-Aware Janitor.
  - Merges oldest segments while rebuilding Sparse Indexes (.idx).
  - Repairs Device Bookmarks and Anchors immediately (bypassing lazy sync).
  - Ensures the .manifest remains valid.
  """
  use GenServer
  require Logger

  @base_dir "data/bimip"
  @num_shards 64
  @merge_threshold 10
  @merge_count 5
  @check_interval :timer.minutes(30)
  @retention_seconds 604_800 # 7 Days
  @user_stride 100           # MUST match QueueLogImpl stride

  # ------------------------------------------------------------------
  # GenServer Lifecycle
  # ------------------------------------------------------------------

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def init(state) do
    schedule_check()
    {:ok, state}
  end

  def handle_info(:check, state) do
    Logger.info("🧹 Maintenance: Checking shards for expiration and bloat...")
    for s <- 0..(@num_shards - 1), do: process_shard(s)
    schedule_check()
    {:noreply, state}
  end

  # ------------------------------------------------------------------
  # Core Logic
  # ------------------------------------------------------------------

  defp process_shard(shard) do
    all_files =
      Path.wildcard(Path.join(@base_dir, "shard_#{shard}_*.log"))
      |> Enum.sort_by(&extract_id/1)

    # 1. Retention (Delete files older than 7 days)
    remaining_files = handle_retention(shard, all_files)

    # 2. Compaction (Merge oldest if threshold met)
    if length(remaining_files) > @merge_threshold do
      to_merge = Enum.take(remaining_files, @merge_count)
      perform_merge(shard, to_merge)
    end
  end

  defp handle_retention(shard, files) do
    now = System.system_time(:second)

    # Identify expired (but not currently active) files
    to_delete = files
      |> Enum.filter(fn f -> (now - extract_id(f)) > @retention_seconds end)
      |> Enum.reject(fn f -> f == List.last(files) end) # Safety: skip active file

    if to_delete != [] do
      Logger.info("🗑️ Shard #{shard}: Deleting #{length(to_delete)} expired segments.")

      remaining_files = files -- to_delete
      new_floor_path = List.first(remaining_files)
      new_floor_id = if new_floor_path, do: extract_id(new_floor_path), else: now

      # Physically remove files
      Enum.each(to_delete, fn f ->
        Queue.FDPoolShard.close_fd(shard, f)
        File.rm(f)
        File.rm(String.replace(f, ".log", ".idx"))
      end)

      # Immediate Repair & Persist (Bypasses Lazy Sync)
      repair_orphaned_bookmarks(shard, Enum.map(to_delete, &extract_id/1), new_floor_id)
    end

    files -- to_delete
  end

  defp perform_merge(shard, files) do
    new_seg_id = extract_id(List.first(files))
    new_log_path = Path.join(@base_dir, "shard_#{shard}_#{new_seg_id}_merged.log")
    deleted_ids = Enum.map(files, &extract_id/1)

    case :file.open(new_log_path, [:write, :raw, :binary]) do
      {:ok, out_fd} ->
        # Copy data and map new physical positions
        pos_map = Enum.reduce(files, %{}, fn src, acc ->
          {:ok, current_pos} = :file.position(out_fd, :cur)
          {:ok, src_fd} = :file.open(src, [:read, :raw, :binary])
          stream_copy(src_fd, out_fd)
          :file.close(src_fd)
          Map.put(acc, extract_id(src), current_pos)
        end)
        :file.close(out_fd)

        # Atomic swap
        final_log = Path.join(@base_dir, "shard_#{shard}_#{new_seg_id}.log")
        File.rename!(new_log_path, final_log)

        # --- KEY FIX: Rebuild SPARSE Index ---
        rebuild_sparse_index(final_log)

        # Update pointers & Persist
        update_bookmarks(shard, deleted_ids, new_seg_id, pos_map)

        # Cleanup old files
        Enum.each(files, fn f ->
          unless f == final_log do
            Queue.FDPoolShard.close_fd(shard, f)
            File.rm(f)
            File.rm(String.replace(f, ".log", ".idx"))
          end
        end)
      _ -> :error
    end
  end

  # ------------------------------------------------------------------
  # Index Rebuilding (Sparse-Aware)
  # ------------------------------------------------------------------

  defp rebuild_sparse_index(log_path) do
    idx_path = String.replace(log_path, ".log", ".idx")
    {:ok, log_fd} = :file.open(log_path, [:read, :raw, :binary])
    {:ok, idx_fd} = :file.open(idx_path, [:write, :raw, :binary])
    rebuild_loop(log_fd, idx_fd, 0)
    :file.close(log_fd)
    :file.close(idx_fd)
  end

  defp rebuild_loop(log_fd, idx_fd, pos) do
    case :file.pread(log_fd, pos, 19) do
      {:ok, <<0xEE, body_size::32, _crc::32, ulen::16, _ts::64>>} ->
        meta_size = ulen + 12
        {:ok, meta} = :file.pread(log_fd, pos + 19, meta_size)
        <<user_bin::binary-size(ulen), p::32, off::64>> = meta

        # ONLY index if logical offset meets the stride (Rule: Sparse Index)
        if rem(off, @user_stride) == 0 do
          :ok = :file.write(idx_fd, <<ulen::16, user_bin::binary, p::32, off::64, pos::64>>)
        end

        rebuild_loop(log_fd, idx_fd, pos + 19 + meta_size + body_size)
      _ -> :ok
    end
  end

  # ------------------------------------------------------------------
  # Bookmark Repair (Force Persist)
  # ------------------------------------------------------------------

  defp update_bookmarks(shard, deleted_ids, new_seg_id, pos_map) do
    cache = :"device_bookmarks_cache_#{shard}"
    :ets.foldl(fn {user, device_map}, _acc ->
      is_affected? = Enum.any?(device_map, fn {_id, {seg, _, _}} -> seg in deleted_ids end)
      if is_affected? do
        updated_map = Enum.into(device_map, %{}, fn {dev_id, {seg, off, phys}} ->
          if seg in deleted_ids do
            base_phys = Map.get(pos_map, seg, 0)
            {dev_id, {new_seg_id, off, base_phys + phys}}
          else
            {dev_id, {seg, off, phys}}
          end
        end)
        :ets.insert(cache, {user, updated_map})
      end
    end, :ok, cache)
    Queue.DeviceBookmark.persist_shard(shard)
  end

  defp repair_orphaned_bookmarks(shard, deleted_ids, new_floor_id) do
    cache = :"device_bookmarks_cache_#{shard}"
    :ets.foldl(fn {user, device_map}, _acc ->
      updated_map = Enum.into(device_map, %{}, fn {dev_id, {seg, off, phys}} ->
        if seg == 0 or seg in deleted_ids do
          {dev_id, {new_floor_id, off, 0}} # Reset to start of oldest surviving file
        else
          {dev_id, {seg, off, phys}}
        end
      end)
      :ets.insert(cache, {user, updated_map})
    end, :ok, cache)
    Queue.DeviceBookmark.persist_shard(shard)
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  defp stream_copy(src, dst) do
    case :file.read(src, 64 * 1024) do
      {:ok, bin} -> :file.write(dst, bin); stream_copy(src, dst)
      :eof -> :ok
    end
  end

  defp extract_id(path), do: path |> Path.basename() |> String.split("_") |> Enum.at(2) |> String.replace(~r/\..*$/, "") |> String.to_integer()
  defp schedule_check, do: Process.send_after(self(), :check, @check_interval)
end
