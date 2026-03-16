defmodule Queue.MessageTracker do
  @moduledoc """
  Sharded, generational message tracker with log writing and offset persistence.
  """
  require Logger

  @default_ttl 120 * 60
  @offset_time 60 * 60

  @partitions_per_shard 2
  @meta_table :message_tracker_metadata
  @shard_count 64

  def init do
    if :ets.info(@meta_table) == :undefined do
      :ets.new(@meta_table, [:set, :public, :named_table, read_concurrency: true])
    end

    for shard <- 0..(@shard_count - 1) do
      :ets.insert_new(@meta_table, {shard, 0})
      init_shard_tables(shard)
    end
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

  def check_and_insert(shard, user, device_id, message_id, message_builder, ttl \\ @default_ttl) do
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
          # 🚀 Added 'offset' to pattern match here
          [{^key, ts, ttl_val, offset}] when ts + ttl_val > now ->
            if (now - ts) < @offset_time do
              # Keep the offset when promoting to current generation
              :ets.insert(current_tab, {key, now, ttl_val, offset})
              :ets.delete(old_tab, key)
            end
            {:error, :already_exists, offset}

          _ ->
            # 2. Check Current Generation
            perform_insert(current_tab, key, now, ttl, message_builder)
        end
    end
  end

  defp perform_insert(table, key, now, ttl, message_builder) do
    case :ets.lookup(table, key) do
      [{^key, ts, ttl_val, offset}] ->
        if ts + ttl_val < now do
          execute_write_and_store(table, key, now, ttl, message_builder)
        else
          {:error, :already_exists, offset}
        end

      [] ->
        execute_write_and_store(table, key, now, ttl, message_builder)
    end
  end

  defp execute_write_and_store(table, key, now, ttl, message_builder) do
    # 🚀 Call write with the builder
    case Queue.QueueLogImpl.write(message_builder) do
      {:ok, offset} ->
        :ets.insert(table, {key, now, ttl, offset})
        {:ok, :inserted, offset}
      error ->
        error
    end
  end

  def rotate(shard) do
    case get_active_gen(shard) do
      nil -> :ok
      active_gen ->
        new_gen = if active_gen == 0, do: 1, else: 0
        :ets.insert(@meta_table, {shard, new_gen})

        for p <- 0..(@partitions_per_shard - 1) do
          table_to_clear = table_name(shard, new_gen, p)
          :ets.delete_all_objects(table_to_clear)
        end
    end
  end

  def sweep(shard) do
    case get_active_gen(shard) do
      nil -> :ok
      active_gen ->
        now = :erlang.monotonic_time(:second)
        for p <- 0..(@partitions_per_shard - 1) do
          table = table_name(shard, active_gen, p)
          # 🚀 Match 4 elements {{key, ts, ttl, offset}}
          :ets.select_delete(table, [
            {{:"$1", :"$2", :"$3", :_}, [{:<, {:+, :"$2", :"$3"}, now}], [true]}
          ])
        end
    end
  end

  defp get_active_gen(shard) do
    case :ets.lookup(@meta_table, shard) do
      [{^shard, gen}] -> gen
      [] -> nil
    end
  end

  defp table_name(shard, gen, p), do: :"msg_shard_#{shard}_g#{gen}_p#{p}"
end
