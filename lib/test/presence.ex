defmodule QueueLogTest do
  @user_count 64
  @total_messages 5_000
  @num_shards 64

  def run_test do
    user_list = for i <- 1..@user_count, do: "user#{i}@domain.com"

    IO.puts("Starting HIGH-CONCURRENCY test...")
    IO.puts("Spawning #{@user_count} independent worker processes...")

    start_time = System.monotonic_time(:second)

    user_list
    |> Task.async_stream(
      fn user ->
        write_loop_for_user(user, user_list)
      end,
      max_concurrency: @user_count,
      timeout: :infinity
    )
    |> Stream.run()

    end_time = System.monotonic_time(:second)
    IO.puts("\nAll user processes finished in #{end_time - start_time} seconds.")
  end

  defp write_loop_for_user(user, all_users) do
    Enum.each(1..@total_messages, fn i ->
      # --- THE PROGRESS REPORTER ---
      # This only prints once every 10,000 messages per user
      if rem(i, 10_000) == 0 do
        IO.puts("[#{user}] Sent #{i} messages...")
      end

      unique_id = :crypto.strong_rand_bytes(16) |> Base.encode64()
      recipient = Enum.random(all_users -- [user])

      msg = %Chat.MessageStruct{
        peer_uid: unique_id,
        timestamp: System.system_time(:millisecond),
        payload: "Message ##{i} for #{user}",
        payload_context: 1,
        encryption_type: "E2E",
        encrypted: "DATA_#{i}",
        signature: "SIG_#{i}",
        device_id: "device_#{user}",
        uupid: "1",
        eid: user,
        from: %Chat.EntityStruct{eid: user, connection_resource_id: "device_#{user}"},
        to: %Chat.EntityStruct{eid: recipient, connection_resource_id: nil}
      }

      Queue.QueueLogImpl.write(1, user, recipient, "device_#{user}", 1, 1, msg, unique_id)
    end)
  end
end
# 09:09


# shard_to_check = 0
# table_name = :"bimip_buf_#{shard_to_check}"
# :ets.tab2list(table_name)

# ps aux | grep beam
# top -l 1 -s 0 | grep PhysMem

# QueueLogTest.run_test()

# defmodule Queue.QueueLogImpl do
#   @moduledoc """
#   BimipLog v10.8 — Fixed Stride logic by persisting user_counts in State.
#   """
#   use GenServer
#   require Logger

#   # ------------------------------------------------------------------
#   # CONFIG
#   # ------------------------------------------------------------------
#   @base_dir "data/bimip"
#   @num_shards 4
#   @header_size 21
#   @flush_interval 1_000
#   @max_messages_per_seg 1_000_000
#   @user_stride 100_000
#   @max_buffer_per_shard 50_000_000

#   @checkpoints :bimip_segment_checkpoints
#   @user_offsets :bimip_user_offsets
#   @idx_cache_prefix :"bimip_idx_"
#   @log_buffer_prefix :"bimip_buf_"

#   # ------------------------------------------------------------------
#   # PUBLIC API
#   # ------------------------------------------------------------------

#   def start_link(shard), do: GenServer.start_link(__MODULE__, shard, name: worker_name(shard))

#   def __startup__ do
#     if :ets.info(@user_offsets) == :undefined, do: :ets.new(@user_offsets, [:named_table, :public, :set, {:write_concurrency, true}])
#     if :ets.info(@checkpoints) == :undefined, do: :ets.new(@checkpoints, [:named_table, :public, :set, {:read_concurrency, true}])

#     for s <- 0..(@num_shards - 1) do
#       if :ets.info(log_buffer(s)) == :undefined, do: :ets.new(log_buffer(s), [:named_table, :public, :duplicate_bag, {:write_concurrency, true}])
#       if :ets.info(idx_cache(s)) == :undefined, do: :ets.new(idx_cache(s), [:named_table, :public, :set, {:read_concurrency, true}])
#     end
#     :ok
#   end

#   def write(partition_id, sender_uid, recipient_uid, device_id, type, payload_ctx, payload, message_id) do
#     shard = :erlang.phash2(recipient_uid, @num_shards)
#     buf = log_buffer(shard)

#     if :ets.info(buf, :size) > @max_buffer_per_shard do
#       {:error, :backpressure}
#     else
#       offset = :ets.update_counter(@user_offsets, {recipient_uid, partition_id}, {2, 1}, {{recipient_uid, partition_id}, 0})
#       data = Queue.Persist.build(%{payload: payload}, offset, recipient_uid, type, payload_ctx)

#       record = %{
#         u: recipient_uid, s: sender_uid, p: partition_id, off: offset, mid: message_id,
#         writer_device: to_string(device_id), bin: :erlang.term_to_binary(data),
#         ts: System.system_time(:second)
#       }

#       :ets.insert(buf, {shard, offset, record})
#       {:ok, offset}
#     end
#   end

#   def fetch_batch(user, partition_id, device_id, batch_size \\ 50) do
#     shard = :erlang.phash2(user, @num_shards)
#     GenServer.call(worker_name(shard), {:fetch, user, partition_id, to_string(device_id), batch_size}, 15_000)
#   end

#   # ------------------------------------------------------------------
#   # GENSERVER HANDLERS
#   # ------------------------------------------------------------------
#   @impl true
#   def init(shard) do
#     shard_dir = Path.join(@base_dir, "#{shard}")
#     File.mkdir_p!(shard_dir)
#     File.mkdir_p!("data/device_bookmarks")

#     bin_path = Path.join("data/device_bookmarks", "#{shard}.bin")

#     manifest = load_manifest(shard)
#     base = manifest.active_base
#     ts = manifest.active_ts

#     recovered_user_counts = recover_user_stride_counts(shard, base)
#     recovered_msg_count = calculate_current_count(shard, base)

#     log_path = Path.join(shard_dir, "#{shard}_#{base}_#{ts}.log")
#     idx_path = Path.join(shard_dir, "#{shard}_#{base}_#{ts}.idx")

#     {:ok, log_fd} = :file.open(log_path, [:append, :raw, :binary, :read, :write])
#     {:ok, idx_fd} = :file.open(idx_path, [:append, :raw, :binary, :read, :write])

#     if not manifest.exists, do: write_manifest(shard, manifest)

#     {:ok, actual_pos} = :file.position(log_fd, :cur)
#     schedule_flush()


#     # Assign state to a variable so we can use it
#     state = %{
#       shard: shard, shard_dir: shard_dir, log_fd: log_fd, idx_fd: idx_fd,
#       current_size: actual_pos, msg_count: recovered_msg_count,
#       active_base: base, active_ts: ts,
#       user_counts: recovered_user_counts
#     }

#     if !File.exists?(bin_path) do
#       snapshot_bin(state)
#     end

#     {:ok, state}
#   end

#   defp recover_user_stride_counts(shard, active_base) do
#     :ets.tab2list(@user_offsets)
#     |> Enum.filter(fn {{user, _p}, _off} ->
#       :erlang.phash2(user, @num_shards) == shard
#     end)
#     |> Enum.reduce(%{}, fn {{user, _partition}, off}, acc ->
#       count_in_seg = off - (active_base - 1)
#       final_count = if count_in_seg < 0, do: 0, else: count_in_seg
#       Map.put(acc, user, final_count)
#     end)
#   end

#   @impl true
#   def handle_call(:force_flush, _from, state) do
#     new_state = perform_flush(state)
#     {:reply, :ok, new_state}
#   end

#   @impl true
#   def handle_call({:fetch, user, p, device_id, batch_size}, _from, state) do
#     log_off = Queue.DeviceBookmark.get(device_id, user)
#     cache = :"device_bookmarks_cache_#{state.shard}"

#     seg_id = case :ets.lookup(cache, user) do
#       [{^user, %{"__anchor__" => {seg, _}}}] ->
#          [base_str | _] = String.split(seg, "_")
#          String.to_integer(base_str)
#       _ -> state.active_base
#     end

#     gate_off = if log_off > 0, do: log_off - rem(log_off - 1, @user_stride), else: 0

#     {actual_seg, actual_phys} = case :ets.lookup(idx_cache(state.shard), {user, p, gate_off}) do
#       [{_, {s, pos}}] -> {s, pos}
#       _ -> {seg_id, 0}
#     end

#     {:ok, disk_results} = stream_messages(state, user, p, actual_seg, actual_phys, batch_size, [], device_id)
#     filtered = Enum.filter(disk_results, fn msg -> msg.off > log_off end)
#     {:reply, {:ok, filtered}, state}
#   end

#   @impl true
#   def handle_info(:flush, state) do
#     new_state = perform_flush(state)
#     schedule_flush()
#     {:noreply, new_state}
#   end

#   # -------------------- RECURSIVE FLUSH --------------------
#   defp perform_flush(state) do
#     buf = log_buffer(state.shard)
#     items = :ets.take(buf, state.shard)

#     if items == [] do
#       state
#     else
#       sorted_items = Enum.sort_by(items, fn {_s, off, _rec} -> off end)
#       process_batch(state, sorted_items)
#     end
#   end

#   defp process_batch(state, items, depth \\ 0)
#   defp process_batch(state, [], _depth), do: state

#   defp process_batch(state, items, depth) when depth > 500 do
#     Logger.error("Max recursion depth reached. Re-inserting #{length(items)} leftovers.")
#     buf = log_buffer(state.shard)
#     :ets.insert(buf, items)
#     state
#   end

#   defp process_batch(state, items, depth) do
#     space_left = @max_messages_per_seg - state.msg_count
#     {to_write, leftovers} = Enum.split(items, space_left)

#     {bin_io, idx_io, final_count, final_bytes, updates, latest_map, next_user_counts} =
#       Enum.reduce(to_write, {[], [], state.msg_count, state.current_size, [], %{}, state.user_counts},
#         fn {_s, off, rec}, {b_acc, i_acc, curr_idx, curr_phys, upd, l_map, u_counts} ->
#           {bin_packet, p_size} = encode_packet(rec, off, state)
#           u_count = Map.get(u_counts, rec.u, 0)

#           {new_i_acc, new_upd} =
#             if rem(u_count, @user_stride) == 0 do
#               u_bin = to_string(rec.u)
#               idx_entry = <<byte_size(u_bin)::16, u_bin::binary, rec.p::32, off::64, state.active_base::64, curr_phys::64>>
#               :ets.insert(idx_cache(state.shard), {{rec.u, rec.p, off}, {state.active_base, curr_phys}})
#               {[i_acc | idx_entry], [{rec.u, off} | upd]}
#             else
#               {i_acc, upd}
#             end

#           updated_l_map = Map.put(l_map, rec.u, off)
#           updated_u_counts = Map.put(u_counts, rec.u, u_count + 1)
#           {[b_acc | bin_packet], new_i_acc, curr_idx + 1, curr_phys + p_size, new_upd, updated_l_map, updated_u_counts}
#         end)

#     :file.write(state.log_fd, bin_io)
#     :file.write(state.idx_fd, idx_io)
#     :file.datasync(state.log_fd)
#     :file.datasync(state.idx_fd)

#     global_max_offset = latest_map |> Map.values() |> Enum.max()
#     Enum.each(Map.keys(latest_map), fn user ->
#       Queue.DeviceBookmark.mark_anchor(user, "#{state.active_base}_#{state.active_ts}", global_max_offset)
#     end)

#     Enum.each(updates, fn {user, pos} ->
#       Queue.DeviceBookmark.mark_position(user, "#{state.active_base}_#{state.active_ts}", pos)
#     end)

#     new_state = %{state | msg_count: final_count, current_size: final_bytes, user_counts: next_user_counts}

#     if new_state.msg_count >= @max_messages_per_seg do
#       # --- CALLING ATOMIC SNAPSHOT VIA FD POOL SHARD ---
#       snapshot_bin(new_state)

#       rotated_state = rotate_segment(new_state)
#       process_batch(rotated_state, leftovers, depth + 1)
#     else
#       process_batch(new_state, leftovers, depth + 1)
#     end
#   end

# defp snapshot_bin(state) do
#     cache = :"device_bookmarks_cache_#{state.shard}"
#     bin_path = Path.join("data/device_bookmarks", "#{state.shard}.bin")

#     # 1. READ existing (Always ensure we treat it as a Map)
#     existing_map = if File.exists?(bin_path) do
#       case File.read(bin_path) do
#         {:ok, b} when b != <<>> ->
#           try do
#             term = :erlang.binary_to_term(b)
#             if is_list(term), do: Map.new(term), else: term
#           rescue _ -> %{} end
#         _ -> %{}
#       end
#     else
#       %{}
#     end

#     # 2. GET current active users
#     hot_map = if :ets.info(cache) != :undefined do
#       :ets.tab2list(cache) |> Map.new()
#     else
#       %{}
#     end

#     # 3. MERGE (STAY AS A MAP)
#     # We removed the |> Map.to_list() here
#     merged_data = Map.merge(existing_map, hot_map)

#     # 4. Save the Map directly
#     bin = :erlang.term_to_binary(merged_data, [:compressed])
#     Queue.FDPoolShard.atomic_snapshot(state.shard, bin_path, bin)

#     :ok
#   end

#   # -------------------- PACKET ENCODING --------------------
#   defp encode_packet(rec, offset, state) do
#     u_bin = to_string(rec.u)
#     d_bin = to_string(rec.writer_device)
#     packet = [
#       <<0xEE, byte_size(rec.bin)::32, :erlang.crc32(rec.bin)::32, byte_size(u_bin)::16, byte_size(d_bin)::16, rec.ts::64>>,
#       u_bin,
#       d_bin,
#       <<rec.p::32, offset::64>>,
#       rec.bin
#     ]
#     {packet, IO.iodata_length(packet)}
#   end

#   # -------------------- SEGMENT ROTATION --------------------
#   defp rotate_segment(state) do
#     new_base = state.active_base + state.msg_count
#     new_ts = System.system_time(:second)

#     :file.close(state.log_fd)
#     :file.close(state.idx_fd)

#     manifest = load_manifest(state.shard)
#     expired_key = "#{state.active_base}_#{state.active_ts}"

#     updated_manifest = %{
#       active_base: new_base,
#       active_ts: new_ts,
#       expired: Map.put(manifest.expired, expired_key, new_ts)
#     }

#     write_manifest(state.shard, updated_manifest)

#     l_path = Path.join(state.shard_dir, "#{state.shard}_#{new_base}_#{new_ts}.log")
#     i_path = Path.join(state.shard_dir, "#{state.shard}_#{new_base}_#{new_ts}.idx")

#     {:ok, l} = :file.open(l_path, [:append, :raw, :binary, :read, :write])
#     {:ok, i} = :file.open(i_path, [:append, :raw, :binary, :read, :write])

#     # RESET user_counts for the new file
#     %{state | log_fd: l, idx_fd: i, active_base: new_base, active_ts: new_ts,
#       current_size: 0, msg_count: 0, user_counts: %{}}
#   end

#   defp read_from_disk(state, base, pos) do
#     case Path.wildcard(Path.join(state.shard_dir, "#{state.shard}_#{base}_*.log")) do
#       [path | _] ->
#         case Queue.FDPoolShard.pread(state.shard, path, pos, @header_size) do
#           {:ok, <<0xEE, size::32, _crc::32, ulen::16, dlen::16, _ts::64>>} ->
#             case Queue.FDPoolShard.pread(state.shard, path, pos + @header_size, ulen + dlen + 12 + size) do
#               {:ok, <<u::binary-size(ulen), d::binary-size(dlen), p::32, off::64, body::binary>>} ->
#                 {:ok, %{u: u, writer_device: d, p: p, off: off, data: :erlang.binary_to_term(body, [:safe])}, pos + @header_size + ulen + dlen + 12 + size}
#               _ -> {:error, :body_failed}
#             end
#           :eof -> {:error, :eof}
#           _ -> {:error, :read_failed}
#         end
#       [] -> {:error, :file_not_found}
#     end
#   end

#   defp stream_messages(state, user, p, seg_id, phys_pos, count, acc, device_id) do
#     if count <= 0 do
#       {:ok, Enum.reverse(acc)}
#     else
#       case read_from_disk(state, seg_id, phys_pos) do
#         {:ok, rec, next_pos} ->
#           if rec.u == to_string(user) and rec.p == p and rec.writer_device != device_id do
#             stream_messages(state, user, p, seg_id, next_pos, count - 1, [rec.data | acc], device_id)
#           else
#             stream_messages(state, user, p, seg_id, next_pos, count, acc, device_id)
#           end
#         {:error, :eof} ->
#           case find_next_segment(state, seg_id) do
#             {:ok, next} -> stream_messages(state, user, p, next, 0, count, acc, device_id)
#             _ -> {:ok, Enum.reverse(acc)}
#           end
#         _ -> {:ok, Enum.reverse(acc)}
#       end
#     end
#   end

#   defp find_next_segment(state, current_base) do
#     files = Path.wildcard(Path.join(state.shard_dir, "#{state.shard}_*.log"))
#     bases = Enum.reduce(files, [], fn f, acc ->
#       filename = Path.basename(f, ".log")
#       parts = String.split(filename, "_")
#       case Enum.at(parts, 1) do
#         nil -> acc
#         val ->
#           case Integer.parse(val) do
#             {int, _} -> [int | acc]
#             :error -> acc
#           end
#       end
#     end) |> Enum.sort()

#     case Enum.find(bases, &(&1 > current_base)) do
#       nil -> :no_more_segments
#       next_base -> {:ok, next_base}
#     end
#   end

#   defp load_manifest(shard) do
#     shard_dir = Path.join(@base_dir, "#{shard}")
#     path = Path.join(shard_dir, "#{shard}.manifest")
#     if File.exists?(path) do
#       data = :erlang.binary_to_term(File.read!(path))
#       %{
#         active_base: data.active_base,
#         active_ts: Map.get(data, :active_ts, System.system_time(:second)),
#         expired: Map.get(data, :expired, %{}),
#         exists: true
#       }
#     else
#       %{active_base: 1, active_ts: System.system_time(:second), expired: %{}, exists: false}
#     end
#   end

#   defp write_manifest(shard, manifest_data) do
#     shard_dir = Path.join(@base_dir, "#{shard}")
#     path = Path.join(shard_dir, "#{shard}.manifest")
#     storage_map = Map.drop(manifest_data, [:exists])
#     File.write!(path <> ".tmp", :erlang.term_to_binary(storage_map))
#     File.rename!(path <> ".tmp", path)
#   end

#   defp calculate_current_count(_shard, base) do
#     case :ets.match(@user_offsets, {{:"$1", :"$2"}, :"$3"}) do
#       [] -> 0
#       matches ->
#         max_off = Enum.reduce(matches, 0, fn [_, _, off], acc -> max(off, acc) end)
#         if max_off >= base, do: max_off - (base - 1), else: 0
#     end
#   end

#   def system_recovery(user) do
#     shard = :erlang.phash2(user, @num_shards)
#     cache = :"device_bookmarks_cache_#{shard}"

#     if :ets.lookup(cache, user) == [] do
#       bin_path = Path.join("data/device_bookmarks", "#{shard}.bin")
#       bak_path = Path.join("data/device_bookmarks", "#{shard}.bin.bak")

#       # Try primary, then try backup if primary fails
#       case try_load_user(shard, bin_path, user) do
#         {:ok, data} -> perform_recovery(user, cache, data)
#         _error ->
#           case try_load_user(shard, bak_path, user) do
#             {:ok, data} -> perform_recovery(user, cache, data)
#             error -> error
#           end
#       end
#     else
#       :already_loaded
#     end
#   end

#   # --- Helper to isolate the file reading logic ---
# defp try_load_user(shard, path, user) do
#     case Queue.FDPoolShard.read_bin(shard, path) do
#       {:ok, binary} when binary != <<>> ->
#         try do
#           all_data = :erlang.binary_to_term(binary)
#           # Now all_data is a Map, we can look up the user directly
#           case Map.get(all_data, user) do
#             nil -> {:error, :not_found}
#             data -> {:ok, data}
#           end
#         rescue
#           _ -> {:error, :corrupted}
#         end
#       _ -> {:error, :no_file}
#     end
#   end

#   # --- Helper to apply the data to ETS ---
#   defp perform_recovery(user, cache, data) do
#     # Restore Bookmark ETS (Anchor + Positions)
#     :ets.insert(cache, {user, data})

#     # Restore Global Offset Counter for this user
#     if anchor = data["__anchor__"] do
#       {_seg_key, off} = anchor
#       :ets.insert(@user_offsets, {{user, 1}, off})
#     end
#     :ok
#   end

#   defp log_buffer(s), do: :"#{@log_buffer_prefix}#{s}"
#   defp idx_cache(s), do: :"#{@idx_cache_prefix}#{s}"
#   defp worker_name(s), do: :"bimip_shard_#{s}"
#   defp schedule_flush, do: Process.send_after(self(), :flush, @flush_interval)

#   @impl true
#   def terminate(_reason, state) do
#     # 1. Flush pending messages to disk
#     perform_flush(state)

#     # 2. Synchronous Snapshot (We don't want to exit before this finishes)
#     # Note: If your system is under heavy load, you might want to
#     # make atomic_snapshot a 'call' instead of 'cast' just for termination.
#     snapshot_bin(state)

#     :file.close(state.log_fd)
#     :file.close(state.idx_fd)
#     :ok
#   end


# end

















# defmodule Queue.QueueLogImpl do
#   @moduledoc """
#   BimipLog v10.8 — Fixed Stride logic by persisting user_counts in State.
#   """
#   use GenServer
#   require Logger

#   # ------------------------------------------------------------------
#   # CONFIG
#   # ------------------------------------------------------------------
#   @base_dir "data/bimip"
#   @num_shards 64
#   @header_size 21
#   @flush_interval 10_000
#   @max_messages_per_seg 1_000_000
#   @user_stride 100_000
#   @max_buffer_per_shard 50_000_000

#   @flush_min_batch 10_000      # NEW: minimum messages before flushing
#   @fsync_interval 2_000       # NEW: fsync at most once every 2s

#   @user_offsets :bimip_user_offsets
#   @idx_cache_prefix :"bimip_idx_"
#   @log_buffer_prefix :"bimip_buf_"

#   # ------------------------------------------------------------------
#   # PUBLIC API
#   # ------------------------------------------------------------------

#   def start_link(shard), do: GenServer.start_link(__MODULE__, shard, name: worker_name(shard))

#   def __startup__ do
#     if :ets.info(@user_offsets) == :undefined do
#       :ets.new(@user_offsets, [:named_table, :public, :set, {:write_concurrency, true}])
#     end

#     if :ets.info(:user_segment_counts) == :undefined do
#       :ets.new(:user_segment_counts, [:named_table, :public, :set, {:write_concurrency, true}])
#     end

#     for s <- 0..(@num_shards - 1) do
#       if :ets.info(log_buffer(s)) == :undefined do
#         :ets.new(log_buffer(s), [:named_table, :public, :duplicate_bag, {:write_concurrency, true}])
#       end
#       if :ets.info(idx_cache(s)) == :undefined do
#         :ets.new(idx_cache(s), [:named_table, :public, :set, {:read_concurrency, true}])
#       end
#     end
#     :ok
#   end

#   def writes(partition_id, sender_uid, recipient_uid, device_id, type, payload_ctx, payload, message_id) do
#     IO.inspect(partition_id)
#     {:ok, 1}
#   end

#   def write(partition_id, sender_uid, recipient_uid, device_id, type, payload_ctx, payload, message_id) do
#     shard = :erlang.phash2(recipient_uid, @num_shards)
#     buf = log_buffer(shard)

#     if :ets.info(buf, :size) > @max_buffer_per_shard do
#       {:error, :backpressure}
#     else
#       # 1. Update global offset
#       offset = :ets.update_counter(@user_offsets, {recipient_uid, partition_id}, {2, 1}, {{recipient_uid, partition_id}, 0})

#       # 2. Update segment-specific count for stride logic
#       # This replaces the need for the GenServer state map!
#       u_count = :ets.update_counter(:user_segment_counts, recipient_uid, 1, {recipient_uid, 0})

#       data = Queue.Persist.build(%{payload: payload}, offset, recipient_uid, type, payload_ctx)

#       # REMOVE IO.inspect here - it is a massive bottleneck

#       record = %{
#         u: recipient_uid, s: sender_uid, p: partition_id, off: offset, mid: message_id,
#         writer_device: to_string(device_id), bin: :erlang.term_to_binary(data),
#         ts: System.system_time(:second),
#         u_count: u_count # Pass the pre-calculated count to the flusher
#       }

#       IO.inspect({shard, offset})

#       :ets.insert(buf, {shard, offset, record})
#       {:ok, offset}
#     end
#   end

#   def fetch_batch(user, partition_id, device_id, batch_size \\ 50) do
#     shard = :erlang.phash2(user, @num_shards)
#     GenServer.call(worker_name(shard), {:fetch, user, partition_id, to_string(device_id), batch_size}, 15_000)
#   end

#   # ------------------------------------------------------------------
#   # GENSERVER HANDLERS
#   # ------------------------------------------------------------------
#   @impl true
#   def init(shard) do
#     shard_dir = Path.join(@base_dir, "#{shard}")
#     File.mkdir_p!(shard_dir)
#     File.mkdir_p!("data/device_bookmarks")

#     bin_path = Path.join("data/device_bookmarks", "#{shard}.bin")

#     manifest = load_manifest(shard)
#     base = manifest.active_base
#     ts = manifest.active_ts

#     recovered_user_counts = recover_user_stride_counts(shard, base)
#     recovered_msg_count = calculate_current_count(shard, base)

#     log_path = Path.join(shard_dir, "#{shard}_#{base}_#{ts}.log")
#     idx_path = Path.join(shard_dir, "#{shard}_#{base}_#{ts}.idx")

#     {:ok, log_fd} = :file.open(log_path, [:append, :raw, :binary, :read, :write])
#     {:ok, idx_fd} = :file.open(idx_path, [:append, :raw, :binary, :read, :write])

#     if not manifest.exists, do: write_manifest(shard, manifest)

#     {:ok, actual_pos} = :file.position(log_fd, :cur)
#     schedule_flush()

#     state = %{
#       shard: shard, shard_dir: shard_dir, log_fd: log_fd, idx_fd: idx_fd,
#       current_size: actual_pos, msg_count: recovered_msg_count,
#       active_base: base, active_ts: ts,
#       user_counts: recovered_user_counts,
#       last_fsync: System.monotonic_time(:millisecond)
#     }

#     if !File.exists?(bin_path), do: snapshot_bin(state)

#     {:ok, state}
#   end

#   defp recover_user_stride_counts(shard, active_base) do
#     :ets.tab2list(@user_offsets)
#     |> Enum.filter(fn {{user, _p}, _off} -> :erlang.phash2(user, @num_shards) == shard end)
#     |> Enum.reduce(%{}, fn {{user, _partition}, off}, acc ->
#       count_in_seg = off - (active_base - 1)
#       final_count = if count_in_seg < 0, do: 0, else: count_in_seg
#       Map.put(acc, user, final_count)
#     end)
#   end

#   @impl true
#   def handle_call(:force_flush, _from, state) do
#     new_state = perform_flush(state, true)
#     {:reply, :ok, new_state}
#   end

#   @impl true
#   def handle_call({:fetch, user, p, device_id, batch_size}, _from, state) do
#     log_off = Queue.DeviceBookmark.get(device_id, user)
#     cache = :"device_bookmarks_cache_#{state.shard}"

#     seg_id = case :ets.lookup(cache, user) do
#       [{^user, %{"__anchor__" => {seg, _}}}] ->
#          [base_str | _] = String.split(seg, "_")
#          String.to_integer(base_str)
#       _ -> state.active_base
#     end

#     gate_off = if log_off > 0, do: log_off - rem(log_off - 1, @user_stride), else: 0

#     {actual_seg, actual_phys} = case :ets.lookup(idx_cache(state.shard), {user, p, gate_off}) do
#       [{_, {s, pos}}] -> {s, pos}
#       _ -> {seg_id, 0}
#     end

#     {:ok, disk_results} = stream_messages(state, user, p, actual_seg, actual_phys, batch_size, [], device_id)
#     filtered = Enum.filter(disk_results, fn msg -> msg.off > log_off end)
#     {:reply, {:ok, filtered}, state}
#   end

#   @impl true
#   def handle_info(:flush, state) do
#     new_state = perform_flush(state, false)
#     schedule_flush()
#     {:noreply, new_state}
#   end

#   # -------------------- RECURSIVE FLUSH --------------------
#   defp perform_flush(state, forced?) do
#     buf = log_buffer(state.shard)

#     # NEW logic: skip if batch too small unless forced
#     if not forced? and :ets.info(buf, :size) < @flush_min_batch do
#       state
#     else
#       items = :ets.take(buf, state.shard)
#       if items == [], do: state, else: process_batch(state, Enum.sort_by(items, fn {_s, off, _rec} -> off end))
#     end
#   end

#   defp process_batch(state, items, depth \\ 0)
#   defp process_batch(state, [], _depth), do: state
#   defp process_batch(state, items, depth) when depth > 500 do
#     Logger.error("Max recursion depth reached. Re-inserting #{length(items)} leftovers.")
#     :ets.insert(log_buffer(state.shard), items)
#     state
#   end

#  defp process_batch(state, items, depth) do
#   space_left = @max_messages_per_seg - state.msg_count
#   {to_write, leftovers} = Enum.split(items, space_left)

#   # Notice we no longer carry 'u_counts' through the reduce
#   {bin_io, idx_io, final_count, final_bytes, updates, latest_map} =
#     Enum.reduce(to_write, {[], [], state.msg_count, state.current_size, [], %{}},
#       fn {_s, off, rec}, {b_acc, i_acc, curr_idx, curr_phys, upd, l_map} ->
#         {bin_packet, p_size} = encode_packet(rec, off, state)

#         # Stride logic: use the u_count we calculated during the 'write' call
#         {new_i_acc, new_upd} =
#           if rem(rec.u_count, @user_stride) == 0 do
#             u_bin = to_string(rec.u)
#             idx_entry = <<byte_size(u_bin)::16, u_bin::binary, rec.p::32, off::64, state.active_base::64, curr_phys::64>>
#             :ets.insert(idx_cache(state.shard), {{rec.u, rec.p, off}, {state.active_base, curr_phys}})
#             {[i_acc | idx_entry], [{rec.u, off} | upd]}
#           else
#             {i_acc, upd}
#           end

#         {[b_acc | bin_packet], new_i_acc, curr_idx + 1, curr_phys + p_size, new_upd, Map.put(l_map, rec.u, off)}
#       end)

#   :file.write(state.log_fd, bin_io)
#   :file.write(state.idx_fd, idx_io)

#   # Only Sync if needed
#   now = System.monotonic_time(:millisecond)
#   new_sync_ts = if now - state.last_fsync >= @fsync_interval do
#     :file.datasync(state.log_fd)
#     :file.datasync(state.idx_fd)
#     now
#   else
#     state.last_fsync
#   end

#   # Update state without the heavy map
#   new_state = %{state | msg_count: final_count, current_size: final_bytes, last_fsync: new_sync_ts}

#   # If rotating, clear the segment counts for this shard's users
#   if new_state.msg_count >= @max_messages_per_seg do
#     snapshot_bin(new_state)
#     # Clear counts for next segment
#     :ets.delete_all_objects(:user_segment_counts)
#     process_batch(rotate_segment(new_state), leftovers, depth + 1)
#   else
#     process_batch(new_state, leftovers, depth + 1)
#   end
# end

#   defp snapshot_bin(state) do
#     cache = :"device_bookmarks_cache_#{state.shard}"
#     bin_path = Path.join("data/device_bookmarks", "#{state.shard}.bin")

#     existing_map = if File.exists?(bin_path) do
#       case File.read(bin_path) do
#         {:ok, b} when b != <<>> ->
#           try do
#             term = :erlang.binary_to_term(b)
#             if is_list(term), do: Map.new(term), else: term
#           rescue _ -> %{} end
#         _ -> %{}
#       end
#     else
#       %{}
#     end

#     hot_map = if :ets.info(cache) != :undefined, do: :ets.tab2list(cache) |> Map.new(), else: %{}
#     bin = :erlang.term_to_binary(Map.merge(existing_map, hot_map), [:compressed])
#     Queue.FDPoolShard.atomic_snapshot(state.shard, bin_path, bin)
#     :ok
#   end

#   defp encode_packet(rec, offset, state) do
#     u_bin = to_string(rec.u)
#     d_bin = to_string(rec.writer_device)
#     packet = [
#       <<0xEE, byte_size(rec.bin)::32, :erlang.crc32(rec.bin)::32, byte_size(u_bin)::16, byte_size(d_bin)::16, rec.ts::64>>,
#       u_bin, d_bin, <<rec.p::32, offset::64>>, rec.bin
#     ]
#     {packet, IO.iodata_length(packet)}
#   end

#   defp rotate_segment(state) do
#     new_base = state.active_base + state.msg_count
#     new_ts = System.system_time(:second)
#     :file.close(state.log_fd)
#     :file.close(state.idx_fd)

#     manifest = load_manifest(state.shard)
#     updated_manifest = %{manifest | active_base: new_base, active_ts: new_ts, expired: Map.put(manifest.expired, "#{state.active_base}_#{state.active_ts}", new_ts)}
#     write_manifest(state.shard, updated_manifest)

#     l_path = Path.join(state.shard_dir, "#{state.shard}_#{new_base}_#{new_ts}.log")
#     i_path = Path.join(state.shard_dir, "#{state.shard}_#{new_base}_#{new_ts}.idx")
#     {:ok, l} = :file.open(l_path, [:append, :raw, :binary, :read, :write])
#     {:ok, i} = :file.open(i_path, [:append, :raw, :binary, :read, :write])

#     %{state | log_fd: l, idx_fd: i, active_base: new_base, active_ts: new_ts, current_size: 0, msg_count: 0, user_counts: %{}}
#   end

#   defp read_from_disk(state, base, pos) do
#     case Path.wildcard(Path.join(state.shard_dir, "#{state.shard}_#{base}_*.log")) do
#       [path | _] ->
#         case Queue.FDPoolShard.pread(state.shard, path, pos, @header_size) do
#           {:ok, <<0xEE, size::32, _crc::32, ulen::16, dlen::16, _ts::64>>} ->
#             case Queue.FDPoolShard.pread(state.shard, path, pos + @header_size, ulen + dlen + 12 + size) do
#               {:ok, <<u::binary-size(ulen), d::binary-size(dlen), p::32, off::64, body::binary>>} ->
#                 {:ok, %{u: u, writer_device: d, p: p, off: off, data: :erlang.binary_to_term(body, [:safe])}, pos + @header_size + ulen + dlen + 12 + size}
#               _ -> {:error, :body_failed}
#             end
#           :eof -> {:error, :eof}
#           _ -> {:error, :read_failed}
#         end
#       [] -> {:error, :file_not_found}
#     end
#   end

#   defp stream_messages(state, user, p, seg_id, phys_pos, count, acc, device_id) do
#     if count <= 0, do: {:ok, Enum.reverse(acc)}, else: (
#       case read_from_disk(state, seg_id, phys_pos) do
#         {:ok, rec, next_pos} ->
#           if rec.u == to_string(user) and rec.p == p and rec.writer_device != device_id do
#             stream_messages(state, user, p, seg_id, next_pos, count - 1, [rec.data | acc], device_id)
#           else
#             stream_messages(state, user, p, seg_id, next_pos, count, acc, device_id)
#           end
#         {:error, :eof} ->
#           case find_next_segment(state, seg_id) do
#             {:ok, next} -> stream_messages(state, user, p, next, 0, count, acc, device_id)
#             _ -> {:ok, Enum.reverse(acc)}
#           end
#         _ -> {:ok, Enum.reverse(acc)}
#       end
#     )
#   end

#   defp find_next_segment(state, current_base) do
#     bases = Path.wildcard(Path.join(state.shard_dir, "#{state.shard}_*.log"))
#     |> Enum.map(fn f ->
#       [_, b | _] = String.split(Path.basename(f, ".log"), "_")
#       String.to_integer(b)
#     end) |> Enum.sort()
#     case Enum.find(bases, &(&1 > current_base)) do
#       nil -> :no_more_segments
#       next -> {:ok, next}
#     end
#   end

#   defp load_manifest(shard) do
#     path = Path.join(Path.join(@base_dir, "#{shard}"), "#{shard}.manifest")
#     if File.exists?(path) do
#       data = :erlang.binary_to_term(File.read!(path))
#       %{active_base: data.active_base, active_ts: Map.get(data, :active_ts, System.system_time(:second)), expired: Map.get(data, :expired, %{}), exists: true}
#     else
#       %{active_base: 1, active_ts: System.system_time(:second), expired: %{}, exists: false}
#     end
#   end

#   defp write_manifest(shard, manifest_data) do
#     path = Path.join(Path.join(@base_dir, "#{shard}"), "#{shard}.manifest")
#     File.write!(path <> ".tmp", :erlang.term_to_binary(Map.drop(manifest_data, [:exists])))
#     File.rename!(path <> ".tmp", path)
#   end

#   defp calculate_current_count(_shard, base) do
#     case :ets.match(@user_offsets, {{:"$1", :"$2"}, :"$3"}) do
#       [] -> 0
#       matches ->
#         max_off = Enum.reduce(matches, 0, fn [_, _, off], acc -> max(off, acc) end)
#         if max_off >= base, do: max_off - (base - 1), else: 0
#     end
#   end

#   def system_recovery(user) do
#     shard = :erlang.phash2(user, @num_shards)
#     cache = :"device_bookmarks_cache_#{shard}"
#     if :ets.lookup(cache, user) == [] do
#       dir = "data/device_bookmarks"
#       case try_load_user(shard, Path.join(dir, "#{shard}.bin"), user) do
#         {:ok, data} -> perform_recovery(user, cache, data)
#         _ ->
#           case try_load_user(shard, Path.join(dir, "#{shard}.bin.bak"), user) do
#             {:ok, data} -> perform_recovery(user, cache, data)
#             err -> err
#           end
#       end
#     else
#       :already_loaded
#     end
#   end

#   defp try_load_user(shard, path, user) do
#     case Queue.FDPoolShard.read_bin(shard, path) do
#       {:ok, bin} when bin != <<>> ->
#         try do
#           all = :erlang.binary_to_term(bin)
#           case Map.get(if(is_list(all), do: Map.new(all), else: all), user) do
#             nil -> {:error, :not_found}
#             data -> {:ok, data}
#           end
#         rescue _ -> {:error, :corrupted} end
#       _ -> {:error, :no_file}
#     end
#   end

#   defp perform_recovery(user, cache, data) do
#     :ets.insert(cache, {user, data})
#     if anchor = data["__anchor__"] do
#       {_, off} = anchor
#       :ets.insert(@user_offsets, {{user, 1}, off})
#     end
#     :ok
#   end

#   defp log_buffer(s), do: :"#{@log_buffer_prefix}#{s}"
#   defp idx_cache(s), do: :"#{@idx_cache_prefix}#{s}"
#   defp worker_name(s), do: :"bimip_shard_#{s}"
#   defp schedule_flush, do: Process.send_after(self(), :flush, @flush_interval)

#   @impl true
#   def terminate(_reason, state) do
#     perform_flush(state, true)
#     snapshot_bin(state)
#     :file.close(state.log_fd)
#     :file.close(state.idx_fd)
#     :ok
#   end
# end
