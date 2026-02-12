defmodule Queue.DeviceBookmark do
  @moduledoc """
  Manages per-device positions and physical anchors with Sparse Segment Indexing.

  Structure per user:
  %{
    "__anchor__" => {segment_name, logical_offset},
    "positions"  => %{ "base_ts" => {"base_ts", logical_offset} },
    "device_id"  => {logical_offset, timestamp}
  }
  """
  use GenServer
  @num_shards 64

  # -------------------------------------------------------------------
  # Startup
  # -------------------------------------------------------------------

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(state) do
    for shard <- 0..(@num_shards - 1) do
      cache = cache_name(shard)
      if :ets.info(cache) == :undefined do
        :ets.new(cache, [:named_table, :public, :set, {:read_concurrency, true}, {:write_concurrency, true}])
      end
    end
    {:ok, state}
  end

  # -------------------------------------------------------------------
  # Public API
  # -------------------------------------------------------------------

  @doc """
  Stores the physical anchor for the user and maintains a sparse index of
  segment entry points in the "positions" map.
  """
  def mark_anchor(user, file_id, off) do
    cache = cache_name(shard_for(user))

    user_map = case :ets.lookup(cache, user) do
      [{^user, m}] -> m
      [] -> %{}
    end

    # 1. Update the legacy anchor (current position)
    user_map = Map.put(user_map, "__anchor__", {file_id, off})

    # 2. Update the Sparse Positions Index
    # Format: "base_ts" => {"base_ts", first_offset_in_this_file}
    positions = Map.get(user_map, "positions", %{})

    updated_map = if Map.has_key?(positions, file_id) do
      # Already registered this file, just return the map with the updated anchor
      user_map
    else
      # First time writing to this file! Record the entry point.
      new_positions = Map.put(positions, file_id, {file_id, off})
      Map.put(user_map, "positions", new_positions)
    end

    :ets.insert(cache, {user, updated_map})
  end

  @doc """
  Retrieves the logical offset for a specific device.
  Returns 0 if not found.
  """
  def get(device_id, user) do
    cache = cache_name(shard_for(user))
    case :ets.lookup(cache, user) do
      [{^user, map}] ->
        case Map.get(map, device_id) do
          {off, _ts} when is_integer(off) -> off
          _ ->
            case Map.get(map, "__anchor__") do
              {_seg, off} -> off
              _ -> 0
            end
        end
      [] -> 0
    end
  end

  @doc """
  Sets or overwrites the device position.
  """
  def set(device_id, user, off) do
    cache = cache_name(shard_for(user))
    now = System.system_time(:second)

    map = case :ets.lookup(cache, user) do
      [{^user, m}] -> m
      [] -> %{}
    end

    :ets.insert(cache, {user, Map.put(map, device_id, {off, now})})
  end

  def advance(device_id, user, new_off) do
    old_off = get(device_id, user)
    if new_off > old_off do
      set(device_id, user, new_off)
    end
  end

  # -------------------------------------------------------------------
  # Internal Helpers
  # -------------------------------------------------------------------

  defp cache_name(shard), do: :"device_bookmarks_cache_#{shard}"
  defp shard_for(user), do: :erlang.phash2(user, @num_shards)
end
