defmodule Queue.QueueLogImpl do
  @moduledoc """
  BimipLog v10 — Sharded Append-Only Log.
  Enhanced with Per-User Sparse Indexing and "Floor" Anchor logic.
  """
  use GenServer
  require Logger

  # ------------------------------------------------------------------
  # CONFIG
  # ------------------------------------------------------------------
  @base_dir "data/bimip"
  @num_shards 64
  @header_size 19
  @flush_interval 100
  @max_segment_size 10_000_000 # 10MB segments
  @max_buffer_per_shard 100_000
  @max_disk_write_retries 3

  # Sparse Index Config
  @user_stride 100        # Create an index entry every 100 messages PER USER
  @max_scan_records 5_000 # Max linear scan if index is missed

  @checkpoints :bimip_segment_checkpoints
  @user_offsets :bimip_user_offsets
  @idx_cache_prefix :"bimip_idx_"
  @log_buffer_prefix :"bimip_buf_"

  # ------------------------------------------------------------------
  # PUBLIC API
  # ------------------------------------------------------------------

  def start_link(shard) do
    GenServer.start_link(__MODULE__, shard, name: worker_name(shard))
  end


  def __startup__ do
    if :ets.info(@user_offsets) == :undefined do
      :ets.new(@user_offsets, [:named_table, :public, :set, {:write_concurrency, true}])
    end

    if :ets.info(@checkpoints) == :undefined do
      :ets.new(@checkpoints, [:named_table, :public, :set, {:read_concurrency, true}])
    end

    for s <- 0..(@num_shards - 1) do
      buf = log_buffer(s)
      idx = idx_cache(s)
      if :ets.info(buf) == :undefined, do: :ets.new(buf, [:named_table, :public, :duplicate_bag, {:write_concurrency, true}])
      if :ets.info(idx) == :undefined, do: :ets.new(idx, [:named_table, :public, :set, {:read_concurrency, true}])
    end
    :ok
  end

  def write(partition_id, user, reply_to, device_id, type, payload_ctx, payload, message_id) do
    shard = :erlang.phash2(user, @num_shards)
    buf = log_buffer(shard)

    if :ets.info(buf, :size) > @max_buffer_per_shard do
      {:error, :backpressure}
    else
      # Atomic increment of user-specific logical offset
      offset = :ets.update_counter(@user_offsets, {user, partition_id}, {2, 1}, {{user, partition_id}, 0})

      data = Queue.Persist.build(%{payload: payload}, offset, reply_to, type, payload_ctx)

      record = %{
        u: user, p: partition_id, off: offset, mid: message_id,
        writer_device: device_id, data: data, ts: System.system_time(:second)
      }

      :ets.insert(buf, {shard, offset, record})
      {:ok, offset}
    end
  end

  def fetch_batch(user, partition_id, device_id, batch_size \\ 50) do
    shard = :erlang.phash2(user, @num_shards)
    GenServer.call(worker_name(shard), {:fetch, user, partition_id, device_id, batch_size}, 15_000)
  end


  @impl true
  def handle_call({:fetch, user, p, device_id, batch_size}, _from, state) do
    # 1. Get the current bookmark
    {seg_id, log_start, phys_start} = Queue.DeviceBookmark.get(device_id, user, p)

    # 2. Check Memory Buffer
    mem_results = fetch_from_buffer(state.shard, user, p, log_start, batch_size)

    results = if length(mem_results) >= batch_size do
      mem_results
    else
      remaining = batch_size - length(mem_results)

      disk_results = if seg_id == 0 do
        []
      else
        # This call now happens INSIDE the owner process!
        {:ok, res} = stream_messages(state.shard, user, p, seg_id, log_start, phys_start, remaining, [])
        res
      end
      disk_results ++ mem_results
    end

    {:reply, {:ok, results}, state}
  end

  defp perform_flush(state) do
    buf = log_buffer(state.shard)
    case :ets.take(buf, state.shard) do
      [] -> state
      items ->
        sorted = Enum.sort_by(items, fn {_shard, off, _rec} -> off end)

        # We track if any of these messages belong to a brand new user
        need_immediate_persist? = Enum.reduce(sorted, false, fn {_shard, off, rec}, force_acc ->
          {:ok, pos_before} = :file.position(state.log_fd, :cur)
          updated_acc = do_write(state, rec, off)

          # Logic: Check if anchor exists. If not, this is the FIRST message (Offset 1)
          is_new_user? = Queue.DeviceBookmark.get("__anchor__", rec.u, rec.p) == {0, 0, 0}

          if is_new_user? do
            Queue.DeviceBookmark.mark_anchor(rec.u, rec.p, state.active_base, off, pos_before)
          end

          # Always advance the device pointer in memory
          Queue.DeviceBookmark.advance(rec.writer_device, rec.u, rec.p, state.active_base, off, pos_before)

          # If we found a new user, we flag the whole batch for immediate disk sync
          force_acc or is_new_user?
        end)

        # NEW: Ensure immediate write to .bin file if offset is 1 for any user in this batch
        if need_immediate_persist? do
          Logger.info("💾 Shard #{state.shard}: New user detected. Forcing immediate bookmark persist.")
          Queue.DeviceBookmark.persist_shard(state.shard)
        end

        state
    end
  end

  defp do_write(state, rec, offset) do
    # Rotate file if it exceeds max size
    state = if state.current_size >= @max_segment_size, do: rotate_segment(state), else: state

    {:ok, pos} = :file.position(state.log_fd, :cur)
    bin = :erlang.term_to_binary(rec.data, [:compressed])
    user_bin = to_string(rec.u)

    # BINARY PACKET: [Header][User][Meta][Body]
    packet = [
      <<0xEE, byte_size(bin)::32, :erlang.crc32(bin)::32, byte_size(user_bin)::16, rec.ts::64>>,
      user_bin,
      <<rec.p::32, offset::64>>,
      bin
    ]

    :ok = :file.write(state.log_fd, packet)

    # --- USER-SPECIFIC SPARSE INDEX ---
    # We write a jump point every @user_stride messages for THIS specific user.
    if rem(offset, @user_stride) == 0 do
      index_entry = <<byte_size(user_bin)::16, user_bin::binary, rec.p::32, offset::64, pos::64>>
      :ok = :file.write(state.idx_fd, index_entry)

      # Cache in memory for fast jumping during current session
      :ets.insert(idx_cache(state.shard), {{rec.u, rec.p, offset}, {state.active_base, pos}})
    end

    # Global checkpoint for the shard
    :ets.insert(@checkpoints, {{state.shard, state.active_base}, {offset, pos}})

    %{state | current_size: state.current_size + IO.iodata_length(packet)}
  end

  # ------------------------------------------------------------------
  # READ & STREAMING
  # ------------------------------------------------------------------

  defp stream_messages(_shard, _user, _p, _seg, _off, _phys, 0, acc), do: {:ok, Enum.reverse(acc)}

  defp stream_messages(shard, user, p, seg_id, last_off, phys_pos, count, acc) do
    # Use the physical position to avoid a scan!
    case read_from_disk(shard, seg_id, phys_pos) do
      {:ok, rec, next_phys_pos} ->
        # If the record belongs to our user, add to batch
        new_acc = if rec.u == to_string(user) and rec.p == p, do: [rec.data | acc], else: acc
        new_count = if rec.u == to_string(user) and rec.p == p, do: count - 1, else: count

        stream_messages(shard, user, p, seg_id, rec.off, next_phys_pos, new_count, new_acc)

      {:error, :eof} ->
        # Hop to next 12-hour segment
        case find_next_segment(shard, seg_id) do
          {:ok, next_seg_id} -> stream_messages(shard, user, p, next_seg_id, 0, 0, count, acc)
          :no_more_segments -> {:ok, Enum.reverse(acc)}
        end

      {:error, _} -> {:ok, Enum.reverse(acc)}
    end
  end

  defp read_from_disk(shard, base, pos) do
    path = Path.join(@base_dir, "shard_#{shard}_#{base}.log")

    # CALL THE POOL TO DO THE READ
    case Queue.FDPoolShard.pread(shard, path, pos, @header_size) do
      {:ok, <<0xEE, size::32, crc::32, ulen::16, _ts::64>>} ->
        meta_and_body_size = ulen + 12 + size

        # CALL THE POOL AGAIN FOR THE BODY
        case Queue.FDPoolShard.pread(shard, path, pos + @header_size, meta_and_body_size) do
          {:ok, full_payload} ->
            <<user_bin::binary-size(ulen), p::32, off::64, body_bin::binary>> = full_payload
            # ... rest of your parsing logic ...
            {:ok, %{data: :erlang.binary_to_term(body_bin, [:safe]), off: off, u: user_bin, p: p}, pos + @header_size + meta_and_body_size}
          _ -> {:error, :body_read_failed}
        end
      :eof -> {:error, :eof}
      other -> {:error, other}
    end
  end


  # ------------------------------------------------------------------
  # GENSERVER LIFECYCLE
  # ------------------------------------------------------------------

# Inside Queue.QueueLogImpl

  def init(shard) do
    # Ensure the directory exists immediately
    File.mkdir_p!(@base_dir)

    manifest = load_manifest(shard)

    # FIX: Add :write to the modes to ensure file creation if it doesn't exist
    case :file.open(manifest.log, [:append, :raw, :binary, :read, :write]) do
      {:ok, log_fd} ->
        {:ok, idx_fd} = :file.open(manifest.idx, [:append, :raw, :binary, :read, :write])
        {:ok, pos} = :file.position(log_fd, :cur)

        schedule_flush()

        Logger.info("🚀 Shard #{shard} started. Active segment: #{manifest.base}")

        {:ok, %{
          shard: shard,
          log_fd: log_fd,
          idx_fd: idx_fd,
          current_size: pos,
          active_base: manifest.base
        }}

      {:error, reason} ->
        Logger.error("❌ Failed to open log file for shard #{shard}: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  def handle_info(:flush, state) do
    new_state = perform_flush(state)
    schedule_flush()
    {:noreply, new_state}
  end

  # Helpers
  defp log_buffer(s), do: :"#{@log_buffer_prefix}#{s}"
  defp idx_cache(s), do: :"#{@idx_cache_prefix}#{s}"
  defp worker_name(s), do: :"bimip_shard_#{s}"
  defp schedule_flush, do: Process.send_after(self(), :flush, @flush_interval)

  defp load_manifest(shard) do
    manifest_path = Path.join(@base_dir, "shard_#{shard}.manifest")
    # ... (Same manifest logic as your previous code)
    if File.exists?(manifest_path) do
       %{active_base: base} = :erlang.binary_to_term(File.read!(manifest_path))
       %{log: Path.join(@base_dir, "shard_#{shard}_#{base}.log"),
         idx: Path.join(@base_dir, "shard_#{shard}_#{base}.idx"), base: base}
    else
       base = System.system_time(:second)
       %{log: Path.join(@base_dir, "shard_#{shard}_#{base}.log"),
         idx: Path.join(@base_dir, "shard_#{shard}_#{base}.idx"), base: base}
    end
  end

  defp rotate_segment(state) do
    new_base = System.system_time(:second)
    # Ensure new file name is unique
    new_base = if new_base <= state.active_base, do: state.active_base + 1, else: new_base

    # 1. Close the current Write FDs
    # Note: We close them here so the Pool can manage them independently
    # if it needs to open them for reading later.
    :file.close(state.log_fd)
    :file.close(state.idx_fd)

    # 2. OPTIONAL: Warm up the pool.
    # We don't actually need to "add" the FD because the pool opens files on demand.
    # However, to avoid a race condition where the pool might try to open a file
    # we just closed, we ensure the manifest is updated first.

    new_log = Path.join(@base_dir, "shard_#{state.shard}_#{new_base}.log")
    new_idx = Path.join(@base_dir, "shard_#{state.shard}_#{new_base}.idx")

    # 3. Update manifest on disk so readers know about the new segment
    File.write!(Path.join(@base_dir, "shard_#{state.shard}.manifest"), :erlang.term_to_binary(%{active_base: new_base}))

    # 4. Open new files for writing
    {:ok, l} = :file.open(new_log, [:append, :raw, :binary, :read, :write])
    {:ok, i} = :file.open(new_idx, [:append, :raw, :binary, :read, :write])

    Logger.info("🔄 Shard #{state.shard} rotated to new segment: #{new_base}")

    %{state | log_fd: l, idx_fd: i, active_base: new_base, current_size: 0}
  end

  defp fetch_from_buffer(shard, user, partition_id, start_off, limit) do
    buffer = log_buffer(shard)
    spec = [{{shard, :"$1", %{u: user, p: partition_id, data: :"$2"}}, [{:>, :"$1", start_off}], [:"$2"]}]
    case :ets.select(buffer, spec, limit) do
      :"$end_of_table" -> []
      {results, _} -> results
      results -> results
    end
  end

  defp find_next_segment(shard, current_id) do
    files = Path.wildcard(Path.join(@base_dir, "shard_#{shard}_*.log"))
    ids = Enum.map(files, fn f ->
      f |> Path.basename() |> String.split("_") |> List.last() |> String.replace(".log", "") |> String.to_integer()
    end) |> Enum.sort()

    case Enum.find(ids, &(&1 > current_id)) do
      nil -> :no_more_segments
      next -> {:ok, next}
    end
  end
end
