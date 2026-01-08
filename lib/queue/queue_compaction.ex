defmodule Queue.BimipCompactor do
  @moduledoc """
  The 'Janitor' of the system.
  Stream-Safe version: Handles TTL filtering, strict 5-file buffering,
  and real index rebuilding without OOM risks.
  """
  use GenServer
  require Logger

  @base_dir "data/bimip"
  @merge_buffer 5
  @check_interval 60_000
  @retention_seconds 0 # Set to 604_800 for 7 days in production
  @num_shards 64

  def start_link(_), do: GenServer.start_link(__MODULE__, %{saved_bytes: 0}, name: __MODULE__)

  def init(state) do
    File.mkdir_p!(@base_dir)
    schedule_check()
    {:ok, state}
  end

  def handle_info(:check, state) do
    Logger.info("🧹 Bimip Maintenance Cycle Starting...")

    for s <- 0..(@num_shards - 1) do
      if pid = Process.whereis(:"bimip_shard_#{s}"), do: send(pid, :flush_buffer)
    end

    shard_results = for s <- 0..(@num_shards - 1), do: compact_shard(s)

    schedule_check()
    {:noreply, %{state | saved_bytes: state.saved_bytes + Enum.sum(shard_results)}}
  end

  defp compact_shard(shard) do
    segments =
      Path.wildcard(Path.join(@base_dir, "shard_#{shard}_*.log"))
      |> Enum.sort_by(&extract_segment_id/1)

    if length(segments) > @merge_buffer + 1 do
      candidates = Enum.drop(segments, -@merge_buffer)
      now = System.system_time(:second)

      eligible_files = Enum.filter(candidates, fn f ->
        (now - extract_segment_id(f)) > @retention_seconds
      end)

      files_to_merge = Enum.take(eligible_files, 5)

      if length(files_to_merge) >= 2 do
        perform_merge(shard, files_to_merge)
      else
        0
      end
    else
      0
    end
  end

  # ------------------------------------------------------------------
  # PERFORM MERGE (Stream-Safe)
  # ------------------------------------------------------------------
  defp perform_merge(shard, files) do
    max_deleted_seg = files |> List.last() |> extract_segment_id()
    new_seg_id = System.system_time(:second)
    new_log_path = Path.join(@base_dir, "shard_#{shard}_#{new_seg_id}.log")

    try do
      {:ok, out_fd} = :file.open(new_log_path, [:write, :raw, :binary])

      # Copy files one-by-one using 64KB chunks to prevent Memory (OOM) issues
      final_pos_map = Enum.reduce(files, %{}, fn src_path, acc_map ->
        {:ok, current_offset} = :file.position(out_fd, :cur)
        seg_id = extract_segment_id(src_path)

        {:ok, src_fd} = :file.open(src_path, [:read, :raw, :binary])
        :ok = stream_io(src_fd, out_fd)
        :file.close(src_fd)

        Map.put(acc_map, seg_id, current_offset)
      end)

      :file.sync(out_fd)
      :file.close(out_fd)

      rebuild_index(new_log_path)
      update_bookmarks_after_merge(shard, max_deleted_seg, new_seg_id, final_pos_map)

      Enum.each(files, fn f ->
        Queue.FDPoolShard.close_fd(shard, f)
        File.rm(f)
        idx_to_remove = String.replace(f, ".log", ".idx")
        if File.exists?(idx_to_remove), do: File.rm(idx_to_remove)
      end)

      Logger.info("✅ Shard #{shard}: Merged #{length(files)} files into #{new_seg_id}")
      1
    rescue
      e ->
        Logger.error("❌ Merge failed for shard #{shard}: #{inspect(e)}")
        0
    end
  end

  defp stream_io(src_fd, dest_fd) do
    case :file.read(src_fd, 64 * 1024) do
      {:ok, data} ->
        :ok = :file.write(dest_fd, data)
        stream_io(src_fd, dest_fd)
      :eof -> :ok
    end
  end

  # ------------------------------------------------------------------
  # UPDATE BOOKMARKS
  # ------------------------------------------------------------------
  defp update_bookmarks_after_merge(shard, max_deleted_seg, new_seg_id, pos_map) do
    cache = :"device_bookmarks_cache_#{shard}"

    :ets.foldl(fn {user, device_map}, _acc ->
      updated_map = Enum.into(device_map, %{}, fn {device_id, {seg, log_off, phys}} ->
        if seg <= max_deleted_seg do
          if device_id == "__anchor__" do
            {"__anchor__", {new_seg_id, 1, 0}}
          else
            new_phys_base = Map.get(pos_map, seg, 0)
            {device_id, {new_seg_id, log_off, new_phys_base + phys}}
          end
        else
          {device_id, {seg, log_off, phys}}
        end
      end)
      :ets.insert(cache, {user, updated_map})
    end, :ok, cache)

    Queue.DeviceBookmark.persist_shard(shard)
  end

  # ------------------------------------------------------------------
  # INDEX REBUILD (HEADER AWARE)
  # ------------------------------------------------------------------
  defp rebuild_index(log_path) do
    idx_path = String.replace(log_path, ".log", ".idx")
    {:ok, log_fd} = :file.open(log_path, [:read, :raw, :binary])
    {:ok, idx_fd} = :file.open(idx_path, [:write, :raw, :binary])

    rebuild_loop(log_fd, idx_fd, 0)

    :file.close(log_fd)
    :file.close(idx_fd)
  end

  defp rebuild_loop(log_fd, idx_fd, pos) do
    # BIMIP Header is 19 bytes: <<0xEE, body_size::32, crc::32, ulen::16, ts::64>>
    case :file.pread(log_fd, pos, 19) do
      {:ok, <<0xEE, body_size::32, _crc::32, ulen::16, _ts::64>>} ->
        meta_size = ulen + 12
        {:ok, meta} = :file.pread(log_fd, pos + 19, meta_size)
        <<user_bin::binary-size(ulen), p::32, off::64>> = meta

        # Write formatted index entry
        idx_entry = <<ulen::16, user_bin::binary, p::32, off::64, pos::64>>
        :ok = :file.write(idx_fd, idx_entry)

        rebuild_loop(log_fd, idx_fd, pos + 19 + meta_size + body_size)
      _ -> :ok
    end
  end

  defp extract_segment_id(path) do
    path |> Path.basename() |> String.split("_") |> List.last() |> String.replace(".log", "") |> String.to_integer()
  end

  defp schedule_check, do: Process.send_after(self(), :check, @check_interval)
end
