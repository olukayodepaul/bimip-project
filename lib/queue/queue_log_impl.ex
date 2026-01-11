defmodule Queue.QueueLogImpl do
  @moduledoc """
  BimipLog v10 — Sharded Append-Only Log.
  World-Class Continuity: Recovers state from Bin-Anchor and Manifest on restart.
  Optimized FD: Maintains open handle for Anchor Bin across segment rotations.
  """
  use GenServer
  require Logger

  # ------------------------------------------------------------------
  # CONFIG
  # ------------------------------------------------------------------
  @base_dir "data/bimip"
  @num_shards 64
  @header_size 21
  @flush_interval 20
  # 🚀 CHANGED: Now using message count for rotation
  @max_messages_per_seg 10_000
  @max_buffer_per_shard 500_000

  @checkpoints :bimip_segment_checkpoints
  @user_offsets :bimip_user_offsets
  @idx_cache_prefix :"bimip_idx_"
  @log_buffer_prefix :"bimip_buf_"
  @user_stride 1000

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

  def sync_flush(recipient_uid) do
    shard = :erlang.phash2(recipient_uid, @num_shards)
    GenServer.call(worker_name(shard), :force_flush, 15_000)
  end

  def write(partition_id, sender_uid, recipient_uid, device_id, type, payload_ctx, payload, message_id) do
    shard = :erlang.phash2(recipient_uid, @num_shards)
    buf = log_buffer(shard)

    if :ets.info(buf, :size) > @max_buffer_per_shard do
      {:error, :backpressure}
    else
      offset = :ets.update_counter(@user_offsets, {recipient_uid, partition_id}, {2, 1}, {{recipient_uid, partition_id}, 0})

      data = Queue.Persist.build(%{payload: payload}, offset, recipient_uid, type, payload_ctx)
      bin_data = :erlang.term_to_binary(data)

      record = %{
        u: recipient_uid,
        s: sender_uid,
        p: partition_id,
        off: offset,
        mid: message_id,
        writer_device: to_string(device_id),
        bin: bin_data,
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
    File.mkdir_p!("data/device_bookmarks")

    bin_path = Path.join("data/device_bookmarks", "shard_#{shard}.bin")
    recover_counters_from_anchor(shard, bin_path)

    manifest = load_manifest(shard)
    base = manifest.base

    log_path = Path.join(@base_dir, "shard_#{shard}_#{base}.log")
    idx_path = Path.join(@base_dir, "shard_#{shard}_#{base}.idx")

    {:ok, log_fd} = :file.open(log_path, [:append, :raw, :binary, :read, :write])
    {:ok, idx_fd} = :file.open(idx_path, [:append, :raw, :binary, :read, :write])
    {:ok, bin_fd} = :file.open(bin_path, [:append, :raw, :binary, :read, :write])

    if not manifest.exists do
      manifest_path = Path.join(@base_dir, "shard_#{shard}.manifest")
      File.write!(manifest_path, :erlang.term_to_binary(%{active_base: base}))
    end

    {:ok, actual_pos} = :file.position(log_fd, :cur)

    schedule_flush()

    {:ok, %{
      shard: shard,
      log_fd: log_fd,
      idx_fd: idx_fd,
      bin_fd: bin_fd,
      current_size: actual_pos,
      msg_count: 0, # 🚀 Initialize count for this segment
      active_base: base
    }}
  end

  defp recover_counters_from_anchor(shard, bin_path) do
    if File.exists?(bin_path) do
      case File.read(bin_path) do
        {:ok, binary} when binary != <<>> ->
          try do
            anchor_data = :erlang.binary_to_term(binary)
            Enum.each(anchor_data, fn
              {user, %{"__anchor__" => {_base, offset, _pos}}} ->
                :ets.insert(@user_offsets, {{user, 1}, offset})
              _ -> :ok
            end)
          rescue
            _ -> :ok
          end
        _ -> :ok
      end
    end
    :ok
  end

  @impl true
  def handle_call(:force_flush, _from, state) do
    new_state = perform_flush(state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:fetch, user, p, device_id, batch_size}, _from, state) do
    {seg_id, log_off, phys_pos} = Queue.DeviceBookmark.get(device_id, user, p)

    gate_off = if log_off > 0 do
      log_off - rem(log_off - 1, @user_stride)
    else
      0
    end

    {actual_seg, actual_phys} = case :ets.lookup(idx_cache(state.shard), {user, p, gate_off}) do
      [{_, {s, pos}}] -> {s, pos}
      _ -> {seg_id, phys_pos}
    end

    {:ok, disk_results} = stream_messages(state.shard, user, p, actual_seg, actual_phys, batch_size, [], device_id)
    filtered_results = Enum.filter(disk_results, fn msg -> msg.off > log_off end)

    {:reply, {:ok, filtered_results}, state}
  end

  @impl true
  def handle_info(:flush, state) do
    new_state = perform_flush(state)
    schedule_flush()
    {:noreply, new_state}
  end

  # ------------------------------------------------------------------
  # FLUSH ENGINE
  # ------------------------------------------------------------------
  defp perform_flush(state) do
    buf = log_buffer(state.shard)
    case :ets.take(buf, state.shard) do
      [] -> state
      items ->
        # 🚀 ROTATION BY COUNT: Check if current segment is full by message count
        state = if state.msg_count >= @max_messages_per_seg, do: rotate_segment(state), else: state

        sorted = Enum.sort_by(items, fn {_shard, off, _rec} -> off end)
        initial_pos = state.current_size

        # We now track final_msg_count in the reduction
        {io_list, final_pos, final_msg_count, final_state} =
          Enum.reduce(sorted, {[], initial_pos, state.msg_count, state}, fn {_shard, off, rec}, {acc_io, curr_phys_pos, acc_count, acc_state} ->

            if off == 1 do
              Queue.DeviceBookmark.mark_initializer(
                rec.u,
                rec.p,
                {rec.s, acc_state.active_base, off, curr_phys_pos}
              )
            end

            {packet, packet_size, updated_state} = build_packet_data(acc_state, rec, off, curr_phys_pos)

            Queue.DeviceBookmark.mark_anchor(rec.u, rec.p, updated_state.active_base, off, curr_phys_pos)

            {[acc_io | packet], curr_phys_pos + packet_size, acc_count + 1, updated_state}
          end)

        case :file.write(final_state.log_fd, io_list) do
          :ok ->
            bookmark_data = :ets.tab2list(:"device_bookmarks_cache_#{state.shard}")
            :file.pwrite(final_state.bin_fd, 0, :erlang.term_to_binary(bookmark_data))

            # Update both the byte size and the message count
            %{final_state | current_size: final_pos, msg_count: final_msg_count}

          {:error, err} ->
            Logger.error("Flush failed: #{inspect(err)}")
            final_state
        end
  end
end

  defp rotate_segment(state) do
    new_base = System.system_time(:second)
    new_base = if new_base <= state.active_base, do: state.active_base + 1, else: new_base

    :file.close(state.log_fd)
    :file.close(state.idx_fd)

    manifest_path = Path.join(@base_dir, "shard_#{state.shard}.manifest")
    File.write!(manifest_path <> ".tmp", :erlang.term_to_binary(%{active_base: new_base}))
    File.rename!(manifest_path <> ".tmp", manifest_path)

    new_log = Path.join(@base_dir, "shard_#{state.shard}_#{new_base}.log")
    new_idx = Path.join(@base_dir, "shard_#{state.shard}_#{new_base}.idx")

    {:ok, l} = :file.open(new_log, [:append, :raw, :binary, :read, :write])
    {:ok, i} = :file.open(new_idx, [:append, :raw, :binary, :read, :write])

    IO.puts "🔄 SHARD #{state.shard} ROTATED -> Segment #{new_base}"
    # 🚀 RESET: msg_count returns to 0 for the new file
    %{state | log_fd: l, idx_fd: i, active_base: new_base, current_size: 0, msg_count: 0}
  end

  defp build_packet_data(state, rec, offset, curr_pos) do
    user_bin = to_string(rec.u)
    device_bin = to_string(rec.writer_device)
    packet = [<<0xEE, byte_size(rec.bin)::32, :erlang.crc32(rec.bin)::32, byte_size(user_bin)::16, byte_size(device_bin)::16, rec.ts::64>>, user_bin, device_bin, <<rec.p::32, offset::64>>, rec.bin]
    packet_size = IO.iodata_length(packet)

    # 🚀 PURE CLOCK: Fixed stride indexing (1, 1001, 2001...)
    if rem(offset, @user_stride) == 1 do
      index_entry = <<
        byte_size(user_bin)::16,
        user_bin::binary,
        rec.p::32,
        offset::64,
        state.active_base::64,
        curr_pos::64
      >>

      :ok = :file.write(state.idx_fd, index_entry)
      :file.datasync(state.idx_fd)

      :ets.insert(idx_cache(state.shard), {{rec.u, rec.p, offset}, {state.active_base, curr_pos}})
    end

    :ets.insert(@checkpoints, {{state.shard, state.active_base}, {offset, curr_pos}})
    {packet, packet_size, state}
  end

  defp stream_messages(shard, user, p, seg_id, phys_pos, count, acc, device_id) do
    if count <= 0 do {:ok, Enum.reverse(acc)} else
      case read_from_disk(shard, seg_id, phys_pos) do
        {:ok, rec, next_phys_pos} ->
          if rec.u == to_string(user) and rec.p == p and rec.writer_device != device_id do
            stream_messages(shard, user, p, seg_id, next_phys_pos, count - 1, [rec.data | acc], device_id)
          else
            stream_messages(shard, user, p, seg_id, next_phys_pos, count, acc, device_id)
          end
        {:error, :eof} ->
          case find_next_segment(shard, seg_id) do
            {:ok, next} -> stream_messages(shard, user, p, next, 0, count, acc, device_id)
            _ -> {:ok, Enum.reverse(acc)}
          end
        _ -> {:ok, Enum.reverse(acc)}
      end
    end
  end

  defp read_from_disk(shard, base, pos) do
    path = Path.join(@base_dir, "shard_#{shard}_#{base}.log")
    case Queue.FDPoolShard.pread(shard, path, pos, @header_size) do
      {:ok, <<0xEE, size::32, _crc::32, ulen::16, dlen::16, _ts::64>>} ->
        case Queue.FDPoolShard.pread(shard, path, pos + @header_size, ulen + dlen + 12 + size) do
          {:ok, <<u::binary-size(ulen), d::binary-size(dlen), p::32, off::64, body::binary>>} ->
            {:ok, %{u: u, writer_device: d, p: p, off: off, data: :erlang.binary_to_term(body, [:safe])}, pos + @header_size + ulen + dlen + 12 + size}
          _ -> {:error, :body_failed}
        end
      :eof -> {:error, :eof}
      _ -> {:error, :read_failed}
    end
  end

  defp fetch_from_buffer(shard, user, p, device_id, start_off, limit) do
    spec = [{{shard, :"$1", %{u: user, p: p, writer_device: :"$2", bin: :"$3"}}, [{:andalso, {:>, :"$1", start_off}, {:not, {:==, :"$2", device_id}}}], [:"$3"]}]
    case :ets.select(log_buffer(shard), spec, limit) do
      :"$end_of_table" -> []
      {res, _} -> Enum.map(res, &:erlang.binary_to_term(&1))
      res -> Enum.map(res, &:erlang.binary_to_term(&1))
    end
  end

  defp load_manifest(shard) do
    path = Path.join(@base_dir, "shard_#{shard}.manifest")
    if File.exists?(path), do: %{base: :erlang.binary_to_term(File.read!(path)).active_base, exists: true},
    else: %{base: System.system_time(:second), exists: false}
  end

  defp find_next_segment(shard, current_id) do
    files = Path.wildcard(Path.join(@base_dir, "shard_#{shard}_*.log"))
    ids = Enum.map(files, fn f -> f |> Path.basename() |> String.split("_") |> List.last() |> String.replace(".log", "") |> String.to_integer() end) |> Enum.sort()
    case Enum.find(ids, &(&1 > current_id)) do nil -> :no_more_segments; next -> {:ok, next} end
  end

  defp log_buffer(s), do: :"#{@log_buffer_prefix}#{s}"
  defp idx_cache(s), do: :"#{@idx_cache_prefix}#{s}"
  defp worker_name(s), do: :"bimip_shard_#{s}"
  defp schedule_flush, do: Process.send_after(self(), :flush, @flush_interval)

  @impl true
  def terminate(_reason, state) do
    perform_flush(state)
    :file.close(state.log_fd)
    :file.close(state.idx_fd)
    :file.close(state.bin_fd)
    Logger.info("💾 Shard #{state.shard} safely closed.")
    :ok
  end
end
