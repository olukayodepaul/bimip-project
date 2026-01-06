defmodule Queue.DeviceBookmark do
  @moduledoc """
  Tracks per-device offsets (bookmarks) for V6 queue.
  Sharded ETS for high concurrency, with periodic disk persistence.
  Fully compatible with sparse-index logs and compaction.
  """

  @num_shards 64
  @device_stride 100
  @persist_dir "data/device_bookmarks"
  @persist_interval 60_000

  # ------------------------------------------------------------------
  # Startup: initialize ETS shards & load from disk
  # ------------------------------------------------------------------
  def startup do
    File.mkdir_p!(@persist_dir)

    for shard <- 0..(@num_shards - 1) do
      cache = cache_name(shard)
      unless :ets.info(cache) do
        :ets.new(cache, [
          :named_table,
          :public,
          :set,
          {:read_concurrency, true},
          {:write_concurrency, true}
        ])
      end
      load_from_disk(shard)
    end

    schedule_persist()
    :ok
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------
  defp cache_name(shard), do: :"device_bookmarks_cache_#{shard}"
  defp shard_for(device_id), do: :erlang.phash2(device_id, @num_shards)
  defp shard_file(shard), do: Path.join(@persist_dir, "shard_#{shard}.bin")
  defp schedule_persist, do: Process.send_after(self(), :persist_all, @persist_interval)

  # ------------------------------------------------------------------
  # Disk persistence
  # ------------------------------------------------------------------
  def handle_info(:persist_all, state \\ nil) do
    persist_all()
    schedule_persist()
    {:noreply, state}
  end

  defp persist_all do
    for shard <- 0..(@num_shards - 1) do
      cache = cache_name(shard)
      entries = :ets.tab2list(cache)
      File.write!(shard_file(shard), :erlang.term_to_binary(entries))
    end
  end

  defp load_from_disk(shard) do
    file = shard_file(shard)
    if File.exists?(file) do
      case File.read(file) do
        {:ok, bin} ->
          case :erlang.binary_to_term(bin) do
            entries when is_list(entries) ->
              cache = cache_name(shard)
              Enum.each(entries, fn {key, offset} -> :ets.insert(cache, {key, offset}) end)
            _ -> :ok
          end
        _ -> :ok
      end
    end
  end

  # ------------------------------------------------------------------
  # Public API
  # ------------------------------------------------------------------
  def get(device_id, user, partition_id) do
    shard = shard_for(device_id)
    cache = cache_name(shard)

    case :ets.lookup(cache, {device_id, user, partition_id}) do
      [{{^device_id, ^user, ^partition_id}, offset}] -> offset
      [] -> 0
    end
  end

  def set(device_id, user, partition_id, offset) do
    shard = shard_for(device_id)
    cache = cache_name(shard)
    :ets.insert(cache, {{device_id, user, partition_id}, offset})
  end

  def advance(device_id, user, partition_id, new_offset) do
    current = get(device_id, user, partition_id)
    if new_offset > current and rem(new_offset - current, @device_stride) == 0 do
      set(device_id, user, partition_id, new_offset)
    else
      :ok
    end
  end

  def adjust_after_compaction(device_id, user, partition_id, min_valid_offset) do
    current = get(device_id, user, partition_id)
    if current < min_valid_offset do
      set(device_id, user, partition_id, min_valid_offset)
    else
      :ok
    end
  end
end
