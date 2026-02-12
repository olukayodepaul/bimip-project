defmodule Queue.MessageTracker do
  @moduledoc """
  Sharded, generational message tracker with automatic promotion of active keys.
  """
  require Logger

  @shard_count 64
  @partitions_per_shard 2
  @default_ttl 43_200 # 12 hours
  @meta_table :message_tracker_metadata

  # Records younger than 30 mins move from Old -> New on access
  @offset_time 1800

  def init do
    if :ets.info(@meta_table) == :undefined do
      :ets.new(@meta_table, [:set, :public, :named_table, read_concurrency: true])
    end

    for shard <- 0..(@shard_count - 1) do
      # Initialize each shard to start on Generation 0
      :ets.insert(@meta_table, {shard, 0})
      init_shard_tables(shard)
    end
    Logger.info("[MessageTracker] Initialized #{@shard_count} Shards with 2 Generations each.")
    :ok
  end

  defp init_shard_tables(shard) do
    for gen <- [0, 1], p <- 0..(@partitions_per_shard - 1) do
      table = table_name(shard, gen, p)
      if :ets.info(table) == :undefined do
        :ets.new(table, [:set, :public, :named_table, read_concurrency: true, write_concurrency: :auto])
      end
    end
  end

  def check_and_insert(shard, user, device_id, message_id, ttl \\ @default_ttl) do
    key = {user, device_id, message_id}
    active_gen = get_active_gen(shard)
    old_gen = if active_gen == 0, do: 1, else: 0

    current_tab = table_name(shard, active_gen, 0)
    old_tab = table_name(shard, old_gen, 0)
    now = :erlang.monotonic_time(:second)

    # 1. Check Old Generation (The "Move Forward" Logic)
    case :ets.lookup(old_tab, key) do
      [{^key, ts, ttl_val}] when ts + ttl_val > now ->
        if (now - ts) < @offset_time do
          # PROMOTE: Insert into current, then delete from old
          :ets.insert(current_tab, {key, now, ttl_val})
          :ets.delete(old_tab, key)
          Logger.debug(fn -> "[Tracker Shard #{shard}] Record Promoted Forward (Age: #{now - ts}s)" end)
        end
        {:error, :already_exists}

      _ ->
        # 2. Not in old, check/insert into current
        case :ets.insert_new(current_tab, {key, now, ttl}) do
          true -> {:ok, :inserted}
          false ->
            # Safe lookup to avoid MatchError if record was swept between insert and lookup
            case :ets.lookup(current_tab, key) do
              [{^key, ts, ttl_val}] ->
                if ts + ttl_val < now do
                  :ets.insert(current_tab, {key, now, ttl})
                  {:ok, :inserted}
                else
                  {:error, :already_exists}
                end
              [] ->
                # Record was deleted by sweep exactly now; retry the whole logic
                check_and_insert(shard, user, device_id, message_id, ttl)
            end
        end
    end
  end

  def rotate(shard) do
    active_gen = get_active_gen(shard)
    new_gen = if active_gen == 0, do: 1, else: 0

    # Flip the active generation pointer
    :ets.insert(@meta_table, {shard, new_gen})

    # Clear the NEW active table (which was the old one)
    table_to_clear = table_name(shard, new_gen, 0)

    count = case :ets.info(table_to_clear, :size) do
      :undefined -> 0
      val -> val
    end

    :ets.delete_all_objects(table_to_clear)

    Logger.info("[MessageTracker] SHARD #{shard} Rotated. Gen #{new_gen} is now active. Wiped #{count} old records.")
  end

  def sweep(shard) do
    active_gen = get_active_gen(shard)
    now = :erlang.monotonic_time(:second)
    table = table_name(shard, active_gen, 0)

    # Use a non-blocking select_delete
    :ets.select_delete(table, [
      {{:"$1", :"$2", :"$3"}, [{:<, {:+, :"$2", :"$3"}, now}], [true]}
    ])
  end

  defp get_active_gen(shard), do: :ets.lookup_element(@meta_table, shard, 2)
  defp table_name(shard, gen, p), do: :"msg_shard_#{shard}_g#{gen}_p#{p}"
end
