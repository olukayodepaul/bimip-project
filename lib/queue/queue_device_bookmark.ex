defmodule Queue.DeviceBookmark do
  @moduledoc """
  Tracks per-device positions using a 3-variable pointer:
  {segment_id, logical_offset, physical_position}.

  Uses a GenServer to background-persist bookmarks to disk every 5 minutes
  to prevent write amplification during high-frequency log flushes.
  """
  use GenServer
  require Logger

  @num_shards 64
  @persist_dir "data/device_bookmarks"
  @sync_interval :timer.minutes(5)

  # ------------------------------------------------------------------
  # GenServer Lifecycle
  # ------------------------------------------------------------------

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    # 1. Initialize ETS tables and load data from disk
    startup()

    # 2. Schedule the recurring background save
    schedule_sync()

    {:ok, state}
  end

  @impl true
  def handle_info(:sync_tick, state) do
    persist_all()
    schedule_sync()
    {:noreply, state}
  end

  defp schedule_sync do
    Process.send_after(self(), :sync_tick, @sync_interval)
  end

  # ------------------------------------------------------------------
  # Startup & Persistence
  # ------------------------------------------------------------------

  def startup do
    File.mkdir_p!(@persist_dir)
    for shard <- 0..(@num_shards - 1) do
      cache = cache_name(shard)
      if :ets.info(cache) == :undefined do
        :ets.new(cache, [
          :named_table,
          :public,
          :set,
          {:read_concurrency, true},
          {:write_concurrency, true}
        ])
      end
    end
    for shard <- 0..(@num_shards - 1), do: load_from_disk(shard)
    :ok
  end

  def persist_all do
    for shard <- 0..(@num_shards - 1), do: persist_shard(shard)
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

  @doc """
  Saves a single shard to disk.
  Used by the GenServer timer AND the Compactor (for immediate repair).
  """
# No changes to get/set/mark_anchor.
# We just ensure persist_shard is accessible for the Log flush.

  def persist_shard(shard) do
    cache = cache_name(shard)
    entries = :ets.tab2list(cache)

    if entries != [] do
      File.mkdir_p!(@persist_dir)
      path = shard_file(shard)
      tmp_path = "#{path}.tmp"
      try do
        # Use raw write for speed within the flush cycle
        File.write!(tmp_path, :erlang.term_to_binary(entries))
        File.rename!(tmp_path, path)
        :ok
      rescue
        e ->
          Logger.error("Failed to persist bookmark shard #{shard}: #{inspect(e)}")
          if File.exists?(tmp_path), do: File.rm(tmp_path)
          {:error, e}
      end
    else
      :ok
    end
  end

  # ------------------------------------------------------------------
  # Public API
  # ------------------------------------------------------------------

  def get(device_id, user, _partition_id) do
    shard = shard_for(user)
    cache = cache_name(shard)

    case :ets.lookup(cache, user) do
      [{^user, map}] ->
        Map.get(map, device_id) || Map.get(map, "__anchor__") || {0, 0, 0}
      [] ->
        {0, 0, 0}
    end
  end

  def set(device_id, user, _partition_id, segment_id, logical_offset, physical_pos) do
    shard = shard_for(user)
    cache = cache_name(shard)

    map = case :ets.lookup(cache, user) do
      [{^user, existing_map}] -> existing_map
      [] -> %{}
    end

    updated_map = Map.put(map, device_id, {segment_id, logical_offset, physical_pos})
    :ets.insert(cache, {user, updated_map})
  end

  def mark_anchor(user, partition_id, segment_id, logical_offset, physical_pos) do
    set("__anchor__", user, partition_id, segment_id, logical_offset, physical_pos)
  end

  def advance(device_id, user, partition_id, new_seg, new_log_off, new_phys_pos) do
    {_old_seg, old_log_off, _old_phys} = get(device_id, user, partition_id)

    if new_log_off > old_log_off do
      set(device_id, user, partition_id, new_seg, new_log_off, new_phys_pos)
    else
      :ok
    end
  end

  def adjust_after_compaction(device_id, user, partition_id, new_seg, target_log_off, new_phys_pos) do
    set(device_id, user, partition_id, new_seg, target_log_off, new_phys_pos)
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  defp cache_name(shard), do: :"device_bookmarks_cache_#{shard}"
  defp shard_for(user), do: :erlang.phash2(user, @num_shards)
  defp shard_file(shard), do: Path.join(@persist_dir, "shard_#{shard}.bin")
end
