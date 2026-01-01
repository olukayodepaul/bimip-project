defmodule Queue.DeviceBookmark do
  @moduledoc """
  Tracks per-device offsets (bookmarks) for V6 queue.
  Sharded ETS + Mnesia for durability and high concurrency.

  Usage:
      Queue.DeviceBookmark.startup() # call once at app start
      Queue.DeviceBookmark.get(device_id, user, partition_id)
      Queue.DeviceBookmark.advance(device_id, user, partition_id, new_offset)
  """

  @num_shards 64

  # ------------------------------------------------------------------
  # Startup: initialize Mnesia + ETS shards
  # ------------------------------------------------------------------
  def startup do
    :mnesia.start()

    for shard <- 0..(@num_shards - 1) do
      table = table_name(shard)
      cache = cache_name(shard)

      # Create Mnesia shard table if it does not exist
      unless table_exists?(table) do
        :mnesia.create_table(table, [
          {:attributes, [:device_id, :user, :partition_id, :offset]},
          {:type, :set},
          {:disc_copies, [node()]},
          {:index, [:user, :partition_id]}
        ])
      end

      # Create ETS shard cache
      unless :ets.info(cache) do
        :ets.new(cache, [
          :named_table,
          :public,
          :set,
          {:read_concurrency, true},
          {:write_concurrency, true}
        ])
      end

      # Load existing Mnesia records into ETS cache
      load_cache_from_mnesia(table, cache)
    end

    :ok
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------
  defp table_name(shard), do: :"device_bookmarks_#{shard}"
  defp cache_name(shard), do: :"device_bookmarks_cache_#{shard}"

  # Check if a Mnesia table exists
  defp table_exists?(table) do
    try do
      case :mnesia.table_info(table, :attributes) do
        [_ | _] -> true
        _ -> false
      end
    catch
      _, _ -> false
    end
  end

  # Determine shard for a given device_id
  defp shard_for(device_id), do: :erlang.phash2(device_id, @num_shards)

  # Load all Mnesia records into ETS cache
  defp load_cache_from_mnesia(table, cache) do
    :mnesia.transaction(fn ->
      :mnesia.match_object({table, :_, :_, :_, :_})
    end)
    |> case do
      {:atomic, records} ->
        Enum.each(records, fn {^table, device_id, user, partition_id, offset} ->
          :ets.insert(cache, {{device_id, user, partition_id}, offset})
        end)
      _ -> :ok
    end
  end

  # ------------------------------------------------------------------
  # Public API
  # ------------------------------------------------------------------

  # Get the current offset for a device (default 0)
  def get(device_id, user, partition_id) do
    shard = shard_for(device_id)
    cache = cache_name(shard)

    case :ets.lookup(cache, {device_id, user, partition_id}) do
      [{{^device_id, ^user, ^partition_id}, offset}] -> offset
      [] -> 0
    end
  end

  # Set the offset (overwrites current)
  def set(device_id, user, partition_id, offset) do
    shard = shard_for(device_id)
    table = table_name(shard)
    cache = cache_name(shard)

    # Update ETS cache
    :ets.insert(cache, {{device_id, user, partition_id}, offset})

    # Persist to Mnesia
    :mnesia.transaction(fn ->
      :mnesia.write({table, device_id, user, partition_id, offset})
    end)
  end

  # Advance offset only if new_offset > current
  def advance(device_id, user, partition_id, new_offset) do
    current = get(device_id, user, partition_id)
    if new_offset > current, do: set(device_id, user, partition_id, new_offset), else: :ok
  end
end
