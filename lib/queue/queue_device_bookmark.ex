defmodule Queue.DeviceBookmark do
  @moduledoc """
  Tracks per-device positions using a 3-variable pointer:
  {segment_id, logical_offset, physical_position}.

  This ensures continuity across segment rotations while allowing fast
  physical seeks on disk.
  """
  require Logger

  @num_shards 64
  @persist_dir "data/device_bookmarks"

  # ------------------------------------------------------------------
  # Startup & Persistence Lifecycle (Unchanged logic, just data shape)
  # ------------------------------------------------------------------

  def startup do
    File.mkdir_p!(@persist_dir)
    for shard <- 0..(@num_shards - 1) do
      cache = cache_name(shard)
      if :ets.info(cache) == :undefined do
        :ets.new(cache, [:named_table, :public, :set, {:read_concurrency, true}, {:write_concurrency, true}])
      end
    end
    for shard <- 0..(@num_shards - 1), do: load_from_disk(shard)
    :ok
  end

  def persist_all do
    for shard <- 0..(@num_shards - 1) do
      cache = cache_name(shard)
      entries = :ets.tab2list(cache)

      if entries != [] do
        path = shard_file(shard)
        tmp_path = "#{path}.tmp"
        try do
          File.write!(tmp_path, :erlang.term_to_binary(entries))
          File.rename!(tmp_path, path)
        rescue
          e ->
            Logger.error("Failed to persist bookmark shard #{shard}: #{inspect(e)}")
            if File.exists?(tmp_path), do: File.rm(tmp_path)
        end
      end
    end
    :ok
  end

  defp load_from_disk(shard) do
    file = shard_file(shard)
    if File.exists?(file) and File.stat!(file).size > 0 do
      try do
        with {:ok, bin} <- File.read(file),
             entries when is_list(entries) <- :erlang.binary_to_term(bin) do
          cache = cache_name(shard)
          Enum.each(entries, fn {user, map} -> :ets.insert(cache, {user, map}) end)
        end
      rescue
        e ->
          Logger.error("Bookmark Shard #{shard} is corrupt. Error: #{inspect(e)}")
          :ok
      end
    else
      :ok
    end
  end

  # ------------------------------------------------------------------
  # Public API (Refactored for 3 variables)
  # ------------------------------------------------------------------

  @doc """
  Returns `{segment_id, logical_offset, physical_pos}` for a device.
  Returns `{0, 0, 0}` if not found.
  """
  def get(device_id, user, _partition_id) do
    shard = shard_for(user)
    cache = cache_name(shard)

    case :ets.lookup(cache, user) do
      [{^user, map}] ->
        # Returns {seg, log_off, phys_pos}
        Map.get(map, device_id) || Map.get(map, "__anchor__") || {0, 0, 0}
      [] ->
        {0, 0, 0}
    end
  end

  @doc """
  Sets the bookmark using Segment ID, Logical Offset, and Physical Byte Position.
  """
  def set(device_id, user, _partition_id, segment_id, logical_offset, physical_pos) do
    shard = shard_for(user)
    cache = cache_name(shard)

    map = case :ets.lookup(cache, user) do
      [{^user, existing_map}] -> existing_map
      [] -> %{}
    end

    # Store as a 3-tuple
    updated_map = Map.put(map, device_id, {segment_id, logical_offset, physical_pos})
    :ets.insert(cache, {user, updated_map})
  end

  @doc """
  Records the user's starting point.
  """
  def mark_anchor(user, partition_id, segment_id, logical_offset, physical_pos) do
    set("__anchor__", user, partition_id, segment_id, logical_offset, physical_pos)
  end

  @doc """
  Advances the bookmark based on the Logical Offset.
  Since Logical Offset never recycles, it is our primary comparison tool.
  """
  def advance(device_id, user, partition_id, new_seg, new_log_off, new_phys_pos) do
    # We retrieve the 3-tuple but only really need the old_log_off for comparison
    {_old_seg, old_log_off, _old_phys} = get(device_id, user, partition_id)

    # Comparison is now much simpler: is the new message logically further?
    if new_log_off > old_log_off do
      set(device_id, user, partition_id, new_seg, new_log_off, new_phys_pos)
    else
      :ok
    end
  end

  @doc """
  Used by Compactor after a merge.
  Note: In a merge, logical_offset stays same, but seg and phys change.
  """
  def adjust_after_compaction(device_id, user, partition_id, new_seg, target_log_off, new_phys_pos) do
    set(device_id, user, partition_id, new_seg, target_log_off, new_phys_pos)
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  defp cache_name(shard), do: :"device_bookmarks_cache_#{shard}"
  defp shard_for(user), do: :erlang.phash2(user, @num_shards)
  defp shard_file(shard), do: Path.join(@persist_dir, "shard_#{shard}.bin")

  @doc """
  Saves a single shard to disk. Used by the Compactor to ensure
  pointer updates are persisted immediately after a merge.
  """
  def persist_shard(shard) do
    cache = cache_name(shard)
    entries = :ets.tab2list(cache)

    # FIX: Ensure the directory exists right before we try to write to it
    File.mkdir_p!(@persist_dir)

    path = shard_file(shard)
    tmp_path = "#{path}.tmp"

    try do
      File.write!(tmp_path, :erlang.term_to_binary(entries))
      File.rename!(tmp_path, path)
      :ok
    rescue
      e ->
        Logger.error("Failed to persist bookmark shard #{shard}: #{inspect(e)}")
        if File.exists?(tmp_path), do: File.rm(tmp_path)
        {:error, e}
    end
  end

  # This is a helper for your persist_all function to avoid code duplication
  defp do_persist_shard(shard) do
    persist_shard(shard)
  end
end
