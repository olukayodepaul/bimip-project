defmodule Queue.MessageTracker do
  require Logger

  @shard_count 64
  @partitions_per_shard 1
  @default_ttl 43_200 # 12 hours
  @meta_table :message_tracker_metadata

  # Records younger than 30 mins move from Old -> New on access
  @offset_time 1800

  def init do
    if :ets.info(@meta_table) == :undefined do
      :ets.new(@meta_table, [:set, :public, :named_table])
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
          Logger.debug("[Tracker Shard #{shard}] Record Promoted Forward (Age: #{now - ts}s)")
        end
        {:error, :already_exists}

      _ ->
        # 2. Not in old, check/insert into current
        case :ets.insert_new(current_tab, {key, now, ttl}) do
          true -> {:ok, :inserted}
          false ->
            # Existing record check for expiry
            [{^key, ts, ttl_val}] = :ets.lookup(current_tab, key)
            if ts + ttl_val < now do
              :ets.insert(current_tab, {key, now, ttl})
              {:ok, :inserted}
            else
              {:error, :already_exists}
            end
        end
    end
  end

  def rotate(shard) do
    active_gen = get_active_gen(shard)
    new_gen = if active_gen == 0, do: 1, else: 0

    # Flip the active generation pointer
    :ets.insert(@meta_table, {shard, new_gen})

    # We clear the NEW active table to make room for the new hour's data
    # (The table that WAS 'old' and is now 'active' again)
    table_to_clear = table_name(shard, new_gen, 0)

    count = :ets.info(table_to_clear, :size) || 0
    :ets.delete_all_objects(table_to_clear)

    Logger.info("[MessageTracker] SHARD #{shard} Rotated. Gen #{new_gen} is now active. Wiped #{count} old records.")
  end

  def sweep(shard) do
    active_gen = get_active_gen(shard)
    now = :erlang.monotonic_time(:second)
    table = table_name(shard, active_gen, 0)

    :ets.select_delete(table, [
      {{:"$1", :"$2", :"$3"}, [{:<, {:+, :"$2", :"$3"}, now}], [true]}
    ])
  end

  defp get_active_gen(shard), do: :ets.lookup_element(@meta_table, shard, 2)
  defp table_name(shard, gen, p), do: :"msg_shard_#{shard}_g#{gen}_p#{p}"
end

# # 1. Setup variables
shard = 14
u = "test_user"
d = "test_device"
m = "msg_123"
key = {u, d, m}

# # 2. INSERT: Initial check and insert
# # This will go into whichever generation is currently active (likely Gen 0)
# IO.puts "--- STEP 1: Initial Insert ---"
# Queue.MessageTracker.check_and_insert(shard, u, d, m)

# # 3. VERIFY: See where it landed
# active_gen = :ets.lookup_element(:message_tracker_metadata, shard, 2)
# IO.puts "Active Gen is: #{active_gen}"
# IO.inspect(:ets.lookup(:"msg_shard_#{shard}_g#{active_gen}_p0", key), label: "Record in Active Table")

# # 4. ROTATE: Manually flip the generations
# # This makes the table containing your data the "OLD" table
# IO.puts "\n--- STEP 2: Manually Rotating Shard ---"
# Queue.MessageTracker.rotate(shard)

# new_active_gen = :ets.lookup_element(:message_tracker_metadata, shard, 2)
# old_gen = if new_active_gen == 0, do: 1, else: 0
# IO.puts "New Active Gen is: #{new_active_gen} (Old Gen is #{old_gen})"

# # 5. CHECK & PROMOTE: Run the check again
# # This triggers the 'Move Forward' logic
# IO.puts "\n--- STEP 3: Second Check (Triggers Promotion) ---"
# Queue.MessageTracker.check_and_insert(shard, u, d, m)

# # 6. FINAL STATE: Show that it moved
# IO.puts "\n--- FINAL RESULTS ---"
# g0_final = :ets.lookup(:"msg_shard_#{shard}_g0_p0", key)
# g1_final = :ets.lookup(:"msg_shard_#{shard}_g1_p0", key)

# IO.inspect(g0_final, label: "Table Gen 0")
# IO.inspect(g1_final, label: "Table Gen 1")

# if active_gen == 0 do
#   IO.puts "\nResult: Data moved from Gen 0 -> Gen 1 ✅"
# else
#   IO.puts "\nResult: Data moved from Gen 1 -> Gen 0 ✅"
# end
