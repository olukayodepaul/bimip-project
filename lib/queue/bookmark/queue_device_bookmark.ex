defmodule Queue.DeviceBookmark do
  @moduledoc """
  Manages per-device positions and message identity in memory (ETS).
  Structure per device: {message_id, logical_offset, device_id, user_id}

  This module serves as the source of truth for message delivery progress
  and provides the data needed to re-prime the MessageTracker on restart.
  """
  use GenServer
  @num_shards 64

  # -------------------------------------------------------------------
  # Startup
  # -------------------------------------------------------------------

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(state) do
    # Initialize 64 separate ETS tables to reduce lock contention across shards
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
  Returns the numeric offset (0 if not found).
  """
  def get(device_id, user, _p \\ nil) do
    cache = cache_name(shard_for(user))
    case :ets.lookup(cache, user) do
      [{^user, map}] ->
        case Map.get(map, device_id) do
          # Matches the 4-element identity tuple
          {_mid, off, _dev, _u} -> off
          # Matches system __anchor__ {seg, off}
          {_seg, off} -> off
          # Matches __initializer__ {sender, seg, off}
          {_s, _seg, off} -> off
          # Default if key exists but format is unknown
          _ -> 0
        end
      [] -> 0
    end
  end

  @doc """
  Sets or Overwrites the 4-element identity tuple for a device.
  Format: {message_id, logical_offset, device_id, user_id}
  """
  def set(device_id, user, message_id, off) do
    cache = cache_name(shard_for(user))

    map = case :ets.lookup(cache, user) do
      [{^user, m}] -> m
      [] -> %{}
    end

    # The self-describing tuple used for MessageTracker recovery
    entry = {message_id, off, device_id, user}

    :ets.insert(cache, {user, Map.put(map, device_id, entry)})
  end

  @doc """
  Increments a device's position only if the new offset is greater than the current.
  Used by consumers to acknowledge message processing.
  """
  def advance(device_id, user, message_id, new_off) do
    old_off = get(device_id, user)
    if new_off > old_off do
      set(device_id, user, message_id, new_off)
    end
  end

  @doc """
  Stores the shard's physical log position (Segment and Offset).
  Keyed as "__anchor__" within the user's bookmark map.
  """
  def mark_anchor(user, _p, seg, off) do
    cache = cache_name(shard_for(user))
    map = case :ets.lookup(cache, user) do
      [{^user, m}] -> m
      [] -> %{}
    end
    :ets.insert(cache, {user, Map.put(map, "__anchor__", {seg, off})})
  end

  @doc """
  Sets the initial synchronization point if not already present.
  """
  def mark_initializer(user, _p, {sender, seg, off}) do
    cache = cache_name(shard_for(user))
    map = case :ets.lookup(cache, user) do
      [{^user, m}] -> m
      [] -> %{}
    end
    unless Map.has_key?(map, "__initializer__") do
      :ets.insert(cache, {user, Map.put(map, "__initializer__", {sender, seg, off})})
    end
  end

  # -------------------------------------------------------------------
  # Internal Helpers
  # -------------------------------------------------------------------

  defp cache_name(shard), do: :"device_bookmarks_cache_#{shard}"

  defp shard_for(user), do: :erlang.phash2(user, @num_shards)
end
