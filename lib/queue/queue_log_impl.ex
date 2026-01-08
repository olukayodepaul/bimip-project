defmodule Queue.QueueLogImpl do
  @moduledoc """
  BimipLog v10 — Sharded Append-Only Log.

  Logic:
  - Checks ETS log_buffer first (real-time data).
  - Falls back to Disk Log if not found in memory (historical data).
  - Uses Birthmark Anchors for new device jumps.
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
  # @max_segment_size 100 * 1024 * 1024
  @max_segment_size 1_000_000
  @max_buffer_per_shard 100_000
  @max_disk_write_retries 3

  @min_stride 100
  @max_stride 5_000
  @max_scan_records 5_000
  @device_stride 100

  @metrics :bimip_metrics
  @checkpoints :bimip_segment_checkpoints
  @user_offsets :bimip_user_offsets
  @idx_cache_device_prefix :"bimip_idx_device_"
  @idx_cache_prefix :"bimip_idx_"
  @log_buffer_prefix :"bimip_buf_"

  # ------------------------------------------------------------------
  # PUBLIC API
  # ------------------------------------------------------------------

  def write(partition_id, user, reply_to, device_id, type, payload_ctx, payload, message_id) do
    IO.inspect({partition_id, user, reply_to, device_id, type, payload_ctx, payload, message_id})
    shard = :erlang.phash2(user, @num_shards)
    buf = log_buffer(shard)

    if :ets.info(buf, :size) > @max_buffer_per_shard do
      {:error, :backpressure}
    else
      offset = :ets.update_counter(@user_offsets, {user, partition_id}, {2, 1}, {{user, partition_id}, 0})
      data = Queue.Persist.build(%{payload: payload}, offset, reply_to, type, payload_ctx)

      record = %{
        u: user, p: partition_id, off: offset, mid: message_id,
        writer_device: device_id, data: data, ts: System.system_time(:second)
      }

      :ets.insert(buf, {shard, offset, record})
      maybe_device_checkpoint(shard, user, device_id, partition_id, offset)
      {:ok, offset}
    end
  end

  defp maybe_device_checkpoint(shard, user, device, partition, offset) do
    key = {user, device, partition}
    last_offset = case :ets.lookup(idx_cache_device(shard), key) do
      [{^key, last}] -> last
      [] -> 0
    end

    if offset - last_offset >= @device_stride do
      :ets.insert(idx_cache_device(shard), {key, offset})
    end
  end

  @doc """
  FETCH STRATEGY:
  1. Check ETS log_buffer first.
  2. If data is missing or incomplete, go to Disk.
  """
  def fetch_batch(user, partition_id, device_id, batch_size \\ 50) do
    shard = :erlang.phash2(user, @num_shards)
    {seg_id, offset_or_pos} = Queue.DeviceBookmark.get(device_id, user, partition_id)

    # Convert anchor/bookmark to a logical offset for the memory check
    # If offset_or_pos is a large physical byte (pos > 10^9), we treat it as 0 for memory scan
    logical_start = if is_integer(offset_or_pos) and offset_or_pos < 1_000_000_000, do: offset_or_pos, else: 0

    # 1. TRY MEMORY (ETS) FIRST
    mem_results = fetch_from_buffer(shard, user, partition_id, logical_start, batch_size)

    cond do
      # If memory filled the batch, return immediately
      length(mem_results) >= batch_size ->
        {:ok, mem_results}

      # 2. FALLBACK TO DISK
      true ->
        remaining = batch_size - length(mem_results)

        disk_results = if seg_id == 0 do
          []
        else
          case lookup_index(shard, user, partition_id, offset_or_pos) do
            {:ok, rec, _next} ->
              {:ok, res} = stream_messages(shard, user, partition_id, seg_id, rec.off, remaining, [])
              res
            :scan ->
              {:ok, res} = stream_messages(shard, user, partition_id, seg_id, offset_or_pos, remaining, [])
              res
          end
        end

        # Return Disk results (Older) + Memory results (Newer)
        {:ok, disk_results ++ mem_results}
    end
  end

  defp fetch_from_buffer(shard, user, partition_id, start_off, limit) do
    buffer = :"bimip_buf_#{shard}"
    spec = [{{shard, :"$1", %{u: user, p: partition_id, data: :"$2"}}, [{:>, :"$1", start_off}], [:"$2"]}]

    case :ets.select(buffer, spec, limit) do
      :"$end_of_table" ->
        []
      {results, _continuation} ->
        results
      results when is_list(results) ->
        results
      _ ->
        []
    end
  end

  # ------------------------------------------------------------------
  # STREAMING & SEGMENT HOPPING LOGIC
  # ------------------------------------------------------------------

  defp stream_messages(_shard, _user, _p, _seg, _off, 0, acc), do: {:ok, Enum.reverse(acc)}

  defp stream_messages(shard, user, p, seg_id, last_off, count, acc) do
    case fetch_next_in_segment(shard, user, p, seg_id, last_off + 1) do
      {:ok, rec} ->
        stream_messages(shard, user, p, seg_id, rec.off, count - 1, [rec.data | acc])

      {:error, :not_found} ->
        case find_next_segment(shard, seg_id) do
          {:ok, next_seg_id} ->
            stream_messages(shard, user, p, next_seg_id, 0, count, acc)
          :no_more_segments ->
            {:ok, Enum.reverse(acc)}
        end
    end
  end

  defp fetch_next_in_segment(shard, user, p, seg_id, target_off) do
    case lookup_index(shard, user, p, target_off) do
      {:ok, rec, _next} -> {:ok, rec}
      :scan -> bounded_scan(shard, user, p, target_off, seg_id)
    end
  end

  defp find_next_segment(shard, current_seg_id) do
    segments =
      Path.wildcard(Path.join(@base_dir, "shard_#{shard}_*.log"))
      |> Enum.map(fn p ->
        p |> Path.basename() |> String.replace(~r/shard_\d+_/, "") |> String.replace(".log", "") |> String.to_integer()
      end)
      |> Enum.sort()

    case Enum.find(segments, fn s -> s > current_seg_id end) do
      nil -> :no_more_segments
      next_id -> {:ok, next_id}
    end
  end

  # ------------------------------------------------------------------
  # GENSERVER & FLUSH
  # ------------------------------------------------------------------

  def start_link(shard), do: GenServer.start_link(__MODULE__, shard, name: worker_name(shard))

  def init(shard) do
    Process.flag(:trap_exit, true)
    File.mkdir_p!(@base_dir)
    manifest = load_manifest(shard)
    load_historical_indices(shard, manifest.base)

    {:ok, log_fd} = :file.open(manifest.log, [:append, :raw, :binary])
    {:ok, idx_fd} = :file.open(manifest.idx, [:append, :raw, :binary])
    {:ok, pos} = :file.position(log_fd, :cur)

    schedule_flush()
    {:ok, %{shard: shard, log_fd: log_fd, idx_fd: idx_fd, current_size: pos, active_base: manifest.base, stride: @min_stride}}
  end

  # 1. This catches the message that was causing the crash
  def handle_info(:flush_buffer, state) do
    handle_info(:flush, state)
  end

  # 2. This uses your existing logic
  def handle_info(:flush, state) do
    new_state = perform_flush(state)
    schedule_flush() # <--- ADD THIS LINE to keep the loop going!
    {:noreply, new_state}
  end

  defp perform_flush(state) do
    buf = log_buffer(state.shard)
    if :ets.info(buf) != :undefined do
      items = :ets.select(buf, [{{state.shard, :"$1", :"$2"}, [], [{{:"$1", :"$2"}}]}])
      :ets.delete_all_objects(buf)

      Enum.sort_by(items, fn {off, _} -> off end)
      |> Enum.reduce(state, fn {off, rec}, acc ->
        # --- ADJUSTMENT HERE ---
        # 1. Capture physical byte position before writing
        {:ok, physical_pos} = :file.position(acc.log_fd, :cur)

        # 2. Perform the write (this handles rotation internally)
        updated_state = do_write(acc, rec, off, 3)

        # 3. Update Bookmark with all 3 variables
        if off == 1 do
          Queue.DeviceBookmark.mark_anchor(rec.u, rec.p, updated_state.active_base, off, physical_pos)
        end

        Queue.DeviceBookmark.advance(rec.writer_device, rec.u, rec.p, updated_state.active_base, off, physical_pos)

        updated_state
      end)
      |> adjust_stride()
    else
      state
    end
  end

  defp do_write(state, rec, offset, retries) when retries > 0 do
    state = if state.current_size >= @max_segment_size, do: rotate_segment(state), else: state

    try do
      {:ok, pos} = :file.position(state.log_fd, :cur)
      bin = :erlang.term_to_binary(rec.data, [:compressed])
      user_bin = to_string(rec.u)

      packet = [
        <<0xEE, byte_size(bin)::32, :erlang.crc32(bin)::32, byte_size(user_bin)::16, rec.ts::64>>,
        user_bin,
        <<rec.p::32, offset::64>>,
        bin
      ]

      :ok = :file.write(state.log_fd, packet)

      if rem(offset, state.stride) == 0 do
        :ok = :file.write(state.idx_fd, <<byte_size(user_bin)::16, user_bin::binary, rec.p::32, offset::64, pos::64>>)
        :ets.insert(idx_cache(state.shard), {{rec.u, rec.p, offset}, {state.active_base, pos}})
      end

      :ets.insert(@checkpoints, {{state.shard, state.active_base}, {offset, pos}})
      %{state | current_size: state.current_size + IO.iodata_length(packet)}
    rescue
      _ ->
        :timer.sleep(50)
        do_write(state, rec, offset, retries - 1)
    end
  end

  defp rotate_segment(state) do
    new_base = System.unique_integer([:positive])
    new_log = Path.join(@base_dir, "shard_#{state.shard}_#{new_base}.log")
    new_idx = Path.join(@base_dir, "shard_#{state.shard}_#{new_base}.idx")
    {:ok, log_fd} = :file.open(new_log, [:append, :raw, :binary])
    {:ok, idx_fd} = :file.open(new_idx, [:append, :raw, :binary])
    persist_manifest(state.shard, new_base)
    %{state | log_fd: log_fd, idx_fd: idx_fd, active_base: new_base, current_size: 0}
  end

  # ------------------------------------------------------------------
  # READ & SCAN HELPERS
  # ------------------------------------------------------------------

  defp lookup_index(shard, user, p, off) do
    case :ets.lookup(idx_cache(shard), {user, p, off}) do
      [{{_, _, _}, {b, pos}}] -> read_from_disk(shard, b, pos)
      [] -> :scan
    end
  end

  defp bounded_scan(shard, user, p, target, seg_id) do
    start_pos = case :ets.lookup(@checkpoints, {shard, seg_id}) do
      [{_, {_, pos}}] -> pos
      [] -> 0
    end
    scan_loop(shard, user, p, target, start_pos, 0, seg_id)
  end

  defp scan_loop(shard, user, p, target, pos, depth, base) do
    if depth > @max_scan_records do
      {:error, :not_found}
    else
      case read_from_disk(shard, base, pos) do
        {:ok, %{off: ^target, u: ^user, p: ^p} = rec, _next_pos} ->
          {:ok, rec}
        {:ok, _, next_pos} ->
          scan_loop(shard, user, p, target, next_pos, depth + 1, base)
        _ ->
          {:error, :not_found}
      end
    end
  end

  defp read_from_disk(shard, base, pos) do
    path = Path.join(@base_dir, "shard_#{shard}_#{base}.log")
    try do
      with {:ok, fd} <- Queue.FDPoolShard.get_fd(shard, path),
           {:ok, <<0xEE, size::32, crc::32, ulen::16, _ts::64>>} <- :file.pread(fd, pos, @header_size),
           meta_and_body_size = ulen + 12 + size,
           {:ok, full_payload} <- :file.pread(fd, pos + @header_size, meta_and_body_size) do

        <<user_bin::binary-size(ulen), p::32, off::64, body_bin::binary>> = full_payload

        if :erlang.crc32(body_bin) == crc do
          next_pos = pos + @header_size + meta_and_body_size
          record = %{
            data: :erlang.binary_to_term(body_bin, [:safe]),
            off: off,
            u: user_bin,
            p: p
          }
          {:ok, record, next_pos}
        else
          {:error, :crc_failed}
        end
      else
        _ -> {:error, :read_failed}
      end
    rescue
      _ -> {:error, :read_failed}
    end
  end

  # ------------------------------------------------------------------
  # STARTUP & UTILS
  # ------------------------------------------------------------------

  def __startup__ do
    maybe_new_table(@user_offsets, [:named_table, :public])
    maybe_new_table(@metrics, [:named_table, :public])
    maybe_new_table(@checkpoints, [:named_table, :public])
    for s <- 0..(@num_shards - 1) do
      maybe_new_table(log_buffer(s), [:named_table, :duplicate_bag, :public])
      maybe_new_table(idx_cache(s), [:named_table, :ordered_set, :public])
      maybe_new_table(idx_cache_device(s), [:named_table, :set, :public])
    end
    Queue.DeviceBookmark.startup()
  end

  defp load_historical_indices(shard, _) do
    Path.wildcard(Path.join(@base_dir, "shard_#{shard}_*.idx"))
    |> Enum.each(fn path ->
      base = path |> Path.basename() |> String.replace(~r/shard_\d+_/, "") |> String.replace(".idx", "") |> String.to_integer()
      File.stream!(path, [], 2048)
      |> Enum.each(fn
        <<ulen::16, _user::binary-size(ulen), _p::32, off::64, pos::64>> ->
          :ets.insert(@checkpoints, {{shard, base}, {off, pos}})
        _ -> :ok
      end)
    end)
  end

  defp maybe_new_table(name, opts), do: (if :ets.info(name) == :undefined, do: :ets.new(name, opts))
  defp log_buffer(s), do: :"#{@log_buffer_prefix}#{s}"
  defp idx_cache(s), do: :"#{@idx_cache_prefix}#{s}"
  defp idx_cache_device(s), do: :"#{@idx_cache_device_prefix}#{s}"
  defp worker_name(s), do: :"bimip_shard_#{s}"
  defp schedule_flush, do: Process.send_after(self(), :flush, @flush_interval)
  defp persist_manifest(shard, base), do: File.write!(Path.join(@base_dir, "shard_#{shard}.manifest"), :erlang.term_to_binary(%{active_base: base}))

  defp load_manifest(shard) do
    manifest_path = Path.join(@base_dir, "shard_#{shard}.manifest")
    if File.exists?(manifest_path) do
      %{active_base: base} = :erlang.binary_to_term(File.read!(manifest_path))
      %{log: Path.join(@base_dir, "shard_#{shard}_#{base}.log"), idx: Path.join(@base_dir, "shard_#{shard}_#{base}.idx"), base: base}
    else
      files = Path.wildcard(Path.join(@base_dir, "shard_#{shard}_*.log"))
      base = case files do
        [] -> System.unique_integer([:positive])
        _ -> files |> Enum.map(fn p -> p |> Path.basename() |> String.replace(~r/shard_#{shard}_|\.log/, "") |> String.to_integer() end) |> Enum.max()
      end
      persist_manifest(shard, base)
      %{log: Path.join(@base_dir, "shard_#{shard}_#{base}.log"), idx: Path.join(@base_dir, "shard_#{shard}_#{base}.idx"), base: base}
    end
  end

  defp adjust_stride(state), do: state
end
