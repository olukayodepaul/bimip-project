defmodule Queue.MessageTracker do
  @moduledoc """
  Sharded, generational message tracker with automatic promotion of active keys.
  """
  require Logger

  # Set this to 64 to match your test environment
  @shard_count 64
  @partitions_per_shard 2
  @default_ttl 43_200 # 12 hours
  @meta_table :message_tracker_metadata

  @offset_time 1800

  def init do
    if :ets.info(@meta_table) == :undefined do
      :ets.new(@meta_table, [:set, :public, :named_table, read_concurrency: true])
    end

    for shard <- 0..(@shard_count - 1) do
      # 🚀 Ensure metadata exists for ALL shards before sweepers start
      :ets.insert(@meta_table, {shard, 0})
      init_shard_tables(shard)
    end
    Logger.info("[MessageTracker] Initialized #{@shard_count} Shards.")
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
    # 🚀 Map the user to a specific partition within the shard
    p = :erlang.phash2(user, @partitions_per_shard)
    key = {user, device_id, message_id}

    case get_active_gen(shard) do
      nil -> {:error, :shard_not_initialized}
      active_gen ->
        old_gen = if active_gen == 0, do: 1, else: 0

        current_tab = table_name(shard, active_gen, p)
        old_tab = table_name(shard, old_gen, p)
        now = :erlang.monotonic_time(:second)

        # 1. Check Old Generation
        case :ets.lookup(old_tab, key) do
          [{^key, ts, ttl_val}] when ts + ttl_val > now ->
            if (now - ts) < @offset_time do
              :ets.insert(current_tab, {key, now, ttl_val})
              :ets.delete(old_tab, key)
            end
            {:error, :already_exists}

          _ ->
            # 2. Check Current Generation
            perform_insert(current_tab, key, now, ttl, shard, user, device_id, message_id)
        end
    end
  end

  defp perform_insert(table, key, now, ttl, shard, user, device_id, message_id) do
    case :ets.insert_new(table, {key, now, ttl}) do
      true -> {:ok, :inserted}
      false ->
        case :ets.lookup(table, key) do
          [{^key, ts, ttl_val}] ->
            if ts + ttl_val < now do
              :ets.insert(table, {key, now, ttl})
              {:ok, :inserted}
            else
              {:error, :already_exists}
            end
          [] -> check_and_insert(shard, user, device_id, message_id, ttl)
        end
    end
  end

  def rotate(shard) do
    case get_active_gen(shard) do
      nil -> :ok
      active_gen ->
        new_gen = if active_gen == 0, do: 1, else: 0
        :ets.insert(@meta_table, {shard, new_gen})

        # Wipe all partitions for the newly inactivated generation
        for p <- 0..(@partitions_per_shard - 1) do
          table_to_clear = table_name(shard, new_gen, p)
          :ets.delete_all_objects(table_to_clear)
        end
        Logger.info("[MessageTracker] SHARD #{shard} Rotated.")
    end
  end

  def sweep(shard) do
    case get_active_gen(shard) do
      nil -> :ok
      active_gen ->
        now = :erlang.monotonic_time(:second)
        for p <- 0..(@partitions_per_shard - 1) do
          table = table_name(shard, active_gen, p)
          :ets.select_delete(table, [
            {{:"$1", :"$2", :"$3"}, [{:<, {:+, :"$2", :"$3"}, now}], [true]}
          ])
        end
    end
  end

  # 🚀 SAFE LOOKUP: Prevents the crash you saw
  defp get_active_gen(shard) do
    case :ets.lookup(@meta_table, shard) do
      [{^shard, gen}] -> gen
      [] -> nil
    end
  end

  defp table_name(shard, gen, p), do: :"msg_shard_#{shard}_g#{gen}_p#{p}"
end
