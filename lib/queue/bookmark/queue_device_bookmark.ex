
defmodule Queue.DeviceBookmark do
  @moduledoc """
  Manages per-device positions and physical anchors in memory (ETS).

  Structure per user:
  %{
    "__anchor__" => {segment_name, logical_offset},
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
  Retrieves the logical offset for a specific device.
  Returns 0 if not found.
  """
  def get(device_id, user) do
    cache = cache_name(shard_for(user))
    case :ets.lookup(cache, user) do
      [{^user, map}] ->
        case Map.get(map, device_id) do
          # Matches device: {logical_offset, timestamp}
          {off, _ts} when is_integer(off) -> off
          # Matches __anchor__: {segment, logical_offset}
          {_seg, off} when is_integer(off) -> off
          _ -> 0
        end
      [] -> 0
    end
  end

  @doc """
  Sets or overwrites the device position.
  Format: {logical_offset, timestamp}
  """
  def set(device_id, user, off) do
    cache = cache_name(shard_for(user))
    now = System.system_time(:second)

    map = case :ets.lookup(cache, user) do
      [{^user, m}] -> m
      [] -> %{}
    end

    # Strictly: {logical_offset, timestamp}
    :ets.insert(cache, {user, Map.put(map, device_id, {off, now})})
  end

  @doc """
  Advances device position only if new_off is greater than current.
  """
  def advance(device_id, user, new_off) do
    old_off = get(device_id, user)
    if new_off > old_off do
      set(device_id, user, new_off)
    end
  end

  @doc """
  Stores the physical anchor for the user.
  Format: {segment_name, logical_offset}
  """
  def mark_anchor(user, seg, off) do
    cache = cache_name(shard_for(user))
    map = case :ets.lookup(cache, user) do
      [{^user, m}] -> m
      [] -> %{}
    end
    :ets.insert(cache, {user, Map.put(map, "__anchor__", {seg, off})})
  end

  # -------------------------------------------------------------------
  # Internal Helpers
  # -------------------------------------------------------------------

  defp cache_name(shard), do: :"device_bookmarks_cache_#{shard}"

  defp shard_for(user), do: :erlang.phash2(user, @num_shards)
end
