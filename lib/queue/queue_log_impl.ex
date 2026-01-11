defmodule Queue.QueueLogImpl do
  @moduledoc """
  BimipLog v10 — Sharded Append-Only Log.
  Organized by Recipient Inbox with Device-ID filtering and FD Pool Proxy Reading.
  """
  use GenServer
  require Logger

  # ------------------------------------------------------------------
  # CONFIG
  # ------------------------------------------------------------------
# ------------------------------------------------------------------
  # CONFIG
  # ------------------------------------------------------------------

  # The root directory where all log and index files are stored.
  @base_dir "data/bimip"

  # Total number of virtual partitions. phash2 uses this to distribute users.
  @num_shards 64

  # Size in bytes of our binary packet header (Magic + Sizes + CRC + TS).
  @header_size 21

  # How often (in milliseconds) the GenServer flushes the ETS buffer to disk.
  @flush_interval 20

  # CHANGE THIS FOR TESTING:
  # The byte limit for a .log file before it closes and starts a new one.
  # Set to 2000 to trigger rotation after ~4-5 stress test messages.
  @max_segment_size 2000

  # Backpressure limit: If the ETS buffer has more than this many items,
  # the 'write' function returns {:error, :backpressure} to slow down the sender.
  @max_buffer_per_shard 500_000

  # ETS table name for mapping {shard, segment} -> {last_offset, physical_pos}.
  @checkpoints :bimip_segment_checkpoints

  # ETS table name for tracking the global incrementing offset per user.
  @user_offsets :bimip_user_offsets

  # Prefix for naming shard-specific Index cache tables (e.g., :bimip_idx_14).
  @idx_cache_prefix :"bimip_idx_"

  # Prefix for naming shard-specific Write buffers (e.g., :bimip_buf_14).
  @log_buffer_prefix :"bimip_buf_"

  # Every Nth message is recorded in the .idx file.
  # (Set to 3 means: message 3, 6, 9... get a physical pointer in the index).
  @user_stride 3

  # ------------------------------------------------------------------
  # PUBLIC API
  # ------------------------------------------------------------------

  def start_link(shard) do
    GenServer.start_link(__MODULE__, shard, name: worker_name(shard))
  end

  def __startup__ do
    if :ets.info(@user_offsets) == :undefined, do: :ets.new(@user_offsets, [:named_table, :public, :set, {:write_concurrency, true}])
    if :ets.info(@checkpoints) == :undefined, do: :ets.new(@checkpoints, [:named_table, :public, :set, {:read_concurrency, true}])

    for s <- 0..(@num_shards - 1) do
      buf = log_buffer(s)
      idx = idx_cache(s)
      if :ets.info(buf) == :undefined, do: :ets.new(buf, [:named_table, :public, :duplicate_bag, {:write_concurrency, true}])
      if :ets.info(idx) == :undefined, do: :ets.new(idx, [:named_table, :public, :set, {:read_concurrency, true}])
    end
    :ok
  end

  def write(partition_id, sender_uid, recipient_uid, device_id, type, payload_ctx, payload, message_id) do
    shard = :erlang.phash2(recipient_uid, @num_shards)
    buf = log_buffer(shard)

    if :ets.info(buf, :size) > @max_buffer_per_shard do
      {:error, :backpressure}
    else
      offset = :ets.update_counter(@user_offsets, {recipient_uid, partition_id}, {2, 1}, {{recipient_uid, partition_id}, 0})

      # KEEPING YOUR EXACT LOGIC
      data = Queue.Persist.build(%{payload: payload}, offset, recipient_uid, type, payload_ctx)

      # SPEED ADJUST: Serialize in worker process to offload GenServer CPU
      bin_data = :erlang.term_to_binary(data)

      record = %{
        u: recipient_uid,
        p: partition_id,
        off: offset,
        mid: message_id,
        writer_device: to_string(device_id),
        bin: bin_data, # Pass pre-serialized binary
        ts: System.system_time(:second)
      }

      :ets.insert(buf, {shard, offset, record})
      {:ok, offset}
    end
  end

  def fetch_batch(user, partition_id, device_id, batch_size \\ 50) do
    shard = :erlang.phash2(user, @num_shards)
    GenServer.call(worker_name(shard), {:fetch, user, partition_id, to_string(device_id), batch_size}, 15_000)
  end

  # ------------------------------------------------------------------
  # GENSERVER HANDLERS
  # ------------------------------------------------------------------

  @impl true
  def init(shard) do
    File.mkdir_p!(@base_dir)
    manifest = load_manifest(shard)

    # 1. Assign Log and Index FDs
    {:ok, log_fd} = :file.open(manifest.log, [:append, :raw, :binary, :read, :write])
    {:ok, idx_fd} = :file.open(manifest.idx, [:append, :raw, :binary, :read, :write])

    # 2. Assign Bookmark Bin FD (Aligned to this shard)
    bin_path = Path.join("data/device_bookmarks", "shard_#{shard}.bin")
    {:ok, bin_fd} = :file.open(bin_path, [:append, :raw, :binary, :read, :write])

    {:ok, pos} = :file.position(log_fd, :cur)
    schedule_flush()

    {:ok, %{
      shard: shard,
      log_fd: log_fd,
      idx_fd: idx_fd,
      bin_fd: bin_fd, # Persistent write handle
      current_size: pos,
      active_base: manifest.base
    }}
  end

  @impl true
  def handle_call({:fetch, user, p, device_id, batch_size}, _from, state) do
    {seg_id, log_start, phys_start} = Queue.DeviceBookmark.get(device_id, user, p)
    mem_results = fetch_from_buffer(state.shard, user, p, device_id, log_start, batch_size)

    results = if length(mem_results) >= batch_size do
      mem_results
    else
      remaining = batch_size - length(mem_results)
      disk_results = if seg_id == 0 do
        []
      else
        {:ok, res} = stream_messages(state.shard, user, p, seg_id, phys_start, remaining, [], device_id)
        res
      end
      disk_results ++ mem_results
    end

    {:reply, {:ok, results}, state}
  end

  @impl true
  def handle_info(:flush, state) do
    new_state = perform_flush(state)
    schedule_flush()
    {:noreply, new_state}
  end

  # ------------------------------------------------------------------
  # SINGLE-FLUSH ARCHITECTURE (LOG + IDX + BIN)
  # ------------------------------------------------------------------
defp perform_flush(state) do
  buf = log_buffer(state.shard)
  case :ets.take(buf, state.shard) do
    [] -> state
    items ->
      # Check rotation ONCE before starting the batch
      state = if state.current_size >= @max_segment_size, do: rotate_segment(state), else: state

      sorted = Enum.sort_by(items, fn {_shard, off, _rec} -> off end)
      initial_pos = state.current_size

      {io_list, final_pos, final_state} =
        Enum.reduce(sorted, {[], initial_pos, state}, fn {_shard, off, rec}, {acc_io, curr_phys_pos, acc_state} ->
          # We pass acc_state here, which now has stable FDs
          {packet, packet_size, updated_state} = build_packet_data(acc_state, rec, off, curr_phys_pos)

          Queue.DeviceBookmark.mark_anchor(rec.u, rec.p, updated_state.active_base, off, curr_phys_pos)
          {[acc_io | packet], curr_phys_pos + packet_size, updated_state}
        end)

      case :file.write(final_state.log_fd, io_list) do
        :ok ->
          bookmark_data = :ets.tab2list(:"device_bookmarks_cache_#{state.shard}")
          bin_payload = :erlang.term_to_binary(bookmark_data)
          :file.pwrite(final_state.bin_fd, 0, bin_payload)

          %{final_state | current_size: final_pos}
        {:error, reason} ->
          IO.puts "❌ Write failed: #{reason}"
          final_state
      end
  end
end

  defp build_packet_data(state, rec, offset, curr_pos) do
  # 🔥 REMOVED THE ROTATION CHECK FROM HERE 🔥
  # It is now handled by perform_flush at the start of the batch.

  user_bin = to_string(rec.u)
  device_bin = to_string(rec.writer_device)

  packet = [
    <<0xEE, byte_size(rec.bin)::32, :erlang.crc32(rec.bin)::32, byte_size(user_bin)::16, byte_size(device_bin)::16, rec.ts::64>>,
    user_bin,
    device_bin,
    <<rec.p::32, offset::64>>,
    rec.bin
  ]

  packet_size = IO.iodata_length(packet)

  if rem(offset, @user_stride) == 0 do
    index_entry = <<byte_size(user_bin)::16, user_bin::binary, rec.p::32, offset::64, curr_pos::64>>
    :ok = :file.write(state.idx_fd, index_entry)
    :ets.insert(idx_cache(state.shard), {{rec.u, rec.p, offset}, {state.active_base, curr_pos}})
  end

  :ets.insert(@checkpoints, {{state.shard, state.active_base}, {offset, curr_pos}})

  {packet, packet_size, state}
end

  defp stream_messages(shard, user, p, seg_id, phys_pos, count, acc, device_id) do
    if count <= 0 do
      {:ok, Enum.reverse(acc)}
    else
      case read_from_disk(shard, seg_id, phys_pos) do
        {:ok, rec, next_phys_pos} ->
          is_target = rec.u == to_string(user) and rec.p == p
          is_from_self = rec.writer_device == device_id

          {new_acc, new_count} = if is_target and not is_from_self do
            {[rec.data | acc], count - 1}
          else
            {acc, count}
          end
          stream_messages(shard, user, p, seg_id, next_phys_pos, new_count, new_acc, device_id)

        {:error, :eof} ->
          case find_next_segment(shard, seg_id) do
            {:ok, next_seg_id} -> stream_messages(shard, user, p, next_seg_id, 0, count, acc, device_id)
            :no_more_segments -> {:ok, Enum.reverse(acc)}
          end
        _ -> {:ok, Enum.reverse(acc)}
      end
    end
  end

  defp read_from_disk(shard, base, pos) do
    path = Path.join(@base_dir, "shard_#{shard}_#{base}.log")
    case Queue.FDPoolShard.pread(shard, path, pos, @header_size) do
      {:ok, <<0xEE, size::32, _crc::32, ulen::16, dlen::16, _ts::64>>} ->
        total_meta_size = ulen + dlen + 12 + size
        case Queue.FDPoolShard.pread(shard, path, pos + @header_size, total_meta_size) do
          {:ok, payload} ->
            <<u::binary-size(ulen), d::binary-size(dlen), p::32, off::64, body::binary>> = payload
            {:ok, %{
              u: u,
              writer_device: d,
              p: p,
              off: off,
              data: :erlang.binary_to_term(body, [:safe])
            }, pos + @header_size + total_meta_size}
          _ -> {:error, :body_failed}
        end
      :eof -> {:error, :eof}
      other -> other
    end
  end

  defp fetch_from_buffer(shard, user, p, device_id, start_off, limit) do
    buffer = log_buffer(shard)
    # Changed :data to :bin to match your write/8 record
    spec = [{{shard, :"$1", %{u: user, p: p, writer_device: :"$2", bin: :"$3"}},
            [{:andalso, {:>, :"$1", start_off}, {:not, {:==, :"$2", device_id}}}],
            [:"$3"]}]

    case :ets.select(buffer, spec, limit) do
      :"$end_of_table" -> []
      {results, _} -> Enum.map(results, & :erlang.binary_to_term(&1))
      results ->
        Enum.map(results, & :erlang.binary_to_term(&1))
    end
  end

defp rotate_segment(state) do
    new_base = System.system_time(:second)
    # Safety: Ensure the timestamp always moves forward
    new_base = if new_base <= state.active_base, do: state.active_base + 1, else: new_base

    # ------------------------------------------------------------------
    # 1. PERSIST THE MANIFEST (The "GPS" for restarts)
    # ------------------------------------------------------------------
    manifest_path = Path.join(@base_dir, "shard_#{state.shard}.manifest")
    manifest_data = :erlang.term_to_binary(%{active_base: new_base})
    File.write!(manifest_path, manifest_data)

    # 2. Close the old handles
    :file.close(state.log_fd)
    :file.close(state.idx_fd)
    :file.close(state.bin_fd)

    # 3. Define new paths
    new_log = Path.join(@base_dir, "shard_#{state.shard}_#{new_base}.log")
    new_idx = Path.join(@base_dir, "shard_#{state.shard}_#{new_base}.idx")
    bin_path = Path.join("data/device_bookmarks", "shard_#{state.shard}.bin")

    # 4. Open New "Write-Trinity"
    {:ok, l} = :file.open(new_log, [:append, :raw, :binary, :read, :write])
    {:ok, i} = :file.open(new_idx, [:append, :raw, :binary, :read, :write])
    {:ok, b} = :file.open(bin_path, [:append, :raw, :binary, :read, :write])

    IO.puts "🔄 ROTATED SHARD #{state.shard}: New base is #{new_base}"

    %{state | log_fd: l, idx_fd: i, bin_fd: b, active_base: new_base, current_size: 0}
  end

  defp load_manifest(shard) do
    path = Path.join(@base_dir, "shard_#{shard}.manifest")
    base = if File.exists?(path), do: :erlang.binary_to_term(File.read!(path)).active_base, else: System.system_time(:second)
    %{base: base,
      log: Path.join(@base_dir, "shard_#{shard}_#{base}.log"),
      idx: Path.join(@base_dir, "shard_#{shard}_#{base}.idx")}
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

  defp log_buffer(s), do: :"#{@log_buffer_prefix}#{s}"
  defp idx_cache(s), do: :"#{@idx_cache_prefix}#{s}"
  defp worker_name(s), do: :"bimip_shard_#{s}"
  defp schedule_flush, do: Process.send_after(self(), :flush, @flush_interval)
end
