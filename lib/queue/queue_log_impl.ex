defmodule Queue.QueueLogImpl do
  @moduledoc """
  BimipLog v9 — Sharded Append-Only Log with Adaptive Sparse Index + Runtime Segment Rotation

  Features:
  - Sparse indexing with adaptive stride
  - Per-device checkpoints
  - Segment-aware ETS cleanup
  - Runtime segment rotation when full
  - Bounded scans
  - Metrics for monitoring
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
  @max_segment_size 100 * 1024 * 1024
  @max_buffer_per_shard 100_000
  @pool_quota 500
  @max_disk_write_retries 3

  # Sparse + Scan
  @min_stride 100
  @max_stride 5_000
  @max_scan_records 5_000
  @device_stride 100

  # Metrics
  @metrics :bimip_metrics
  @checkpoints :bimip_segment_checkpoints

  # ------------------------------------------------------------------
  # PUBLIC API
  # ------------------------------------------------------------------

  def write(partition_id, user, reply_to, device_id, type, payload_ctx, payload, message_id) do
    shard = :erlang.phash2(user, @num_shards)
    buf = log_buffer(shard)

    if :ets.info(buf, :size) > @max_buffer_per_shard do
      {:error, :backpressure}
    else
      offset =
        :ets.update_counter(
          @user_offsets,
          {user, partition_id},
          {2, 1},
          {{user, partition_id}, 0}
        )

      data = Queue.Persist.build(%{payload: payload}, offset, reply_to, type, payload_ctx)

      record = %{
        u: user,
        p: partition_id,
        off: offset,
        mid: message_id,
        writer_device: device_id,
        data: data,
        ts: System.system_time(:second)
      }

      :ets.insert(buf, {shard, offset, record})

      maybe_device_checkpoint(shard, user, device_id, partition_id, offset)

      {:ok, offset}
    end
  end

  def fetch(user, partition_id, offset) do
    shard = :erlang.phash2(user, @num_shards)

    case :ets.match_object(log_buffer(shard), {shard, offset, %{u: user, p: partition_id}}) do
      [{_, _, rec}] ->
        inc(:hit)
        {:ok, rec.data}

      [] ->
        case lookup_index(shard, user, partition_id, offset) do
          {:ok, rec} ->
            inc(:hit)
            {:ok, rec.data}

          :scan ->
            inc(:miss)
            bounded_scan(shard, user, partition_id, offset)
        end
    end
  end

  # ------------------------------------------------------------------
  # GENSERVER
  # ------------------------------------------------------------------

  def start_link(shard),
    do: GenServer.start_link(__MODULE__, shard, name: worker_name(shard))

  def init(shard) do
    Process.flag(:trap_exit, true)
    File.mkdir_p!(@base_dir)

    manifest = load_manifest(shard)
    load_historical_indices(shard, manifest.base)

    {:ok, log_fd} = :file.open(manifest.log, [:append, :raw, :binary])
    {:ok, idx_fd} = :file.open(manifest.idx, [:append, :raw, :binary])
    {:ok, pos} = :file.position(log_fd, :cur)

    schedule_flush()

    {:ok,
     %{
       shard: shard,
       log_fd: log_fd,
       idx_fd: idx_fd,
       current_size: pos,
       active_base: manifest.base,
       stride: @min_stride
     }}
  end

  def handle_info(:flush, state), do: {:noreply, perform_flush(state)}

  def terminate(_, state) do
    if :ets.info(log_buffer(state.shard)) != :undefined do
      perform_flush(state)
    end

    :file.close(state.log_fd)
    :file.close(state.idx_fd)
  end

  # ------------------------------------------------------------------
  # RUNTIME SEGMENT ROTATION
  # ------------------------------------------------------------------

  defp rotate_segment(state) do
    new_base = System.unique_integer([:positive])
    new_log = Path.join(@base_dir, "shard_#{state.shard}_#{new_base}.log")
    new_idx = Path.join(@base_dir, "shard_#{state.shard}_#{new_base}.idx")

    {:ok, log_fd} = :file.open(new_log, [:append, :raw, :binary])
    {:ok, idx_fd} = :file.open(new_idx, [:append, :raw, :binary])

    Logger.info("Shard #{state.shard} rotated: new log #{Path.basename(new_log)}")

    persist_manifest(state.shard, new_base)

    %{state |
      log_fd: log_fd,
      idx_fd: idx_fd,
      active_base: new_base,
      current_size: 0
    }
  end

  # ------------------------------------------------------------------
  # FLUSH / WRITE
  # ------------------------------------------------------------------

  defp perform_flush(state) do
    buf = log_buffer(state.shard)

    if :ets.info(buf) != :undefined do
      items =
        :ets.select(buf, [
          {{state.shard, :"$1", :"$2"}, [], [{{:"$1", :"$2"}}]}
        ])

      :ets.delete_all_objects(buf)

      Enum.reduce(items, state, fn {off, rec}, acc ->
        do_write(acc, rec, off, @max_disk_write_retries)
      end)
      |> adjust_stride()
    else
      state
    end
  end

  defp do_write(state, rec, offset, retries) when retries > 0 do
    # Rotate segment if full BEFORE writing
    state = if state.current_size >= @max_segment_size, do: rotate_segment(state), else: state

    try do
      {:ok, pos} = :file.position(state.log_fd, :cur)
      bin = :erlang.term_to_binary(rec.data, [:compressed])
      user_bin = to_string(rec.u)

      packet = [
        <<0xEE, byte_size(bin)::32, :erlang.crc32(bin)::32, byte_size(user_bin)::16,
          rec.ts::64>>,
        user_bin,
        <<rec.p::32, offset::64>>,
        bin
      ]

      :ok = :file.write(state.log_fd, packet)

      if should_index?(state, offset) do
        :ok =
          :file.write(
            state.idx_fd,
            <<byte_size(user_bin)::16, user_bin::binary, rec.p::32, offset::64, pos::64>>
          )

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

  defp do_write(_, rec, _, 0), do: raise("I/O failure #{rec.mid}")

  defp should_index?(state, offset) do
    rem(offset, state.stride) == 0
  end

  # ------------------------------------------------------------------
  # MANIFEST PERSISTENCE
  # ------------------------------------------------------------------

  defp persist_manifest(shard, base) do
    manifest_file = Path.join(@base_dir, "shard_#{shard}.manifest")
    tmp_file = manifest_file <> ".tmp"

    File.write!(tmp_file, :erlang.term_to_binary(%{active_base: base}))
    {:ok, fd} = :file.open(tmp_file, [:read, :write, :binary])
    :file.sync(fd)
    :file.close(fd)
    File.rename!(tmp_file, manifest_file)
  end

  # ------------------------------------------------------------------
  # READ / INDEX / SCAN
  # ------------------------------------------------------------------

  defp lookup_index(shard, user, p, off) do
    case :ets.lookup(idx_cache(shard), {user, p, off}) do
      [{{_, _, _}, {b, pos}}] ->
        {:ok, read_from_disk(shard, b, pos)}

      [] ->
        :scan
    end
  end

  defp bounded_scan(shard, user, p, target) do
    case :ets.lookup(@checkpoints, {shard, :"$1"}) do
      [] ->
        {:error, :not_found}

      [{_, {_, pos}}] ->
        base = get_active_base(shard)
        scan_loop(shard, user, p, target, pos, 0, base)
    end
  end

  defp scan_loop(_, _, _, _, _, depth, _) when depth > @max_scan_records do
    inc(:scan_abort)
    {:error, :scan_limit}
  end

  defp scan_loop(shard, user, p, target, pos, depth, base) do
    inc({:scan_depth, 1})

    case read_from_disk(shard, base, pos) do
      {:ok, %{off: ^target, u: ^user, p: ^p} = rec} ->
        {:ok, rec}

      {:ok, %{}} ->
        scan_loop(shard, user, p, target, pos + 1, depth + 1, base)

      _ ->
        {:error, :not_found}
    end
  end

  # ------------------------------------------------------------------
  # DEVICE CHECKPOINTS
  # ------------------------------------------------------------------

  defp maybe_device_checkpoint(shard, user, device, partition, offset) do
    key = {user, device}

    last =
      case :ets.lookup(idx_cache_device(shard), key) do
        [{^key, last_off}] -> last_off
        [] -> 0
      end

    if rem(offset - last, @device_stride) == 0 do
      :ets.insert(idx_cache_device(shard), {key, offset})
    end
  end

  # ------------------------------------------------------------------
  # ADAPTIVE STRIDE
  # ------------------------------------------------------------------

  defp adjust_stride(state) do
    scan_depth =
      case :ets.lookup(@metrics, {:scan_depth, state.shard}) do
        [{_, depth}] -> depth
        [] -> 0
      end

    new_stride =
      cond do
        scan_depth > 1_000 -> max(@min_stride, div(state.stride, 2))
        scan_depth < 100 -> min(@max_stride, state.stride * 2)
        true -> state.stride
      end

    :ets.insert(@metrics, {{:scan_depth, state.shard}, 0})
    %{state | stride: new_stride}
  end

  # ------------------------------------------------------------------
  # DISK READ
  # ------------------------------------------------------------------

  defp read_from_disk(shard, base, pos) do
    path = Path.join(@base_dir, "shard_#{shard}_#{base}.log")

    with {:ok, fd} <- reader_fd(@read_pool_log, path),
         {:ok, <<0xEE, size::32, crc::32, ulen::16, _::64>>} <- :file.pread(fd, pos, @header_size),
         {:ok, bin} <- :file.pread(fd, pos + @header_size + ulen + 12, size),
         true <- :erlang.crc32(bin) == crc do
      {:ok, :erlang.binary_to_term(bin, [:safe])}
    else
      _ -> {:error, :read_failed}
    end
  end

  # ------------------------------------------------------------------
  # METRICS
  # ------------------------------------------------------------------

  defp inc(key), do: :ets.update_counter(@metrics, key, 1, {key, 0})

  # ------------------------------------------------------------------
  # SYSTEM HELPERS
  # ------------------------------------------------------------------

  def __startup__ do
    maybe_new_table(@user_offsets, [:named_table, :public])
    maybe_new_table(@read_pool_log, [:named_table, :public])
    maybe_new_table(@metrics, [:named_table, :public])
    maybe_new_table(@checkpoints, [:named_table, :public])

    for s <- 0..(@num_shards - 1) do
      maybe_new_table(log_buffer(s), [:named_table, :duplicate_bag, :public])
      maybe_new_table(idx_cache(s), [:named_table, :ordered_set, :public])
      maybe_new_table(idx_cache_device(s), [:named_table, :set, :public])
    end
  end

  defp maybe_new_table(name, opts) do
    if :ets.info(name) == :undefined do
      :ets.new(name, opts)
    end
  end

  defp reader_fd(pool, path) do
    case :ets.lookup(pool, path) do
      [{_, fd, _}] -> {:ok, fd}
      [] ->
        {:ok, fd} = :file.open(path, [:read, :raw, :binary])
        :ets.insert(pool, {path, fd, :erlang.monotonic_time()})
        {:ok, fd}
    end
  end

  defp load_manifest(shard) do
    files = Path.wildcard(Path.join(@base_dir, "shard_#{shard}_*.log"))

    case files do
      [] ->
        base = System.unique_integer([:positive])
        %{
          log: Path.join(@base_dir, "shard_#{shard}_#{base}.log"),
          idx: Path.join(@base_dir, "shard_#{shard}_#{base}.idx"),
          base: base
        }

      _ ->
        latest_log = Enum.max_by(files, &File.stat!(&1).mtime)
        base =
          latest_log
          |> Path.basename()
          |> String.replace_prefix("shard_#{shard}_", "")
          |> String.replace_suffix(".log", "")
          |> String.to_integer()

        %{
          log: Path.join(@base_dir, "shard_#{shard}_#{base}.log"),
          idx: Path.join(@base_dir, "shard_#{shard}_#{base}.idx"),
          base: base
        }
    end
  end

  # ------------------------------------------------------------------
  # ACTIVE BASE HELPER
  # ------------------------------------------------------------------
  defp get_active_base(shard) do
    case :ets.lookup(@checkpoints, {shard, :"$1"}) do
      [{_, {_, _pos}}] ->
        [{base, _}] = :ets.match(@checkpoints, {{shard, :"$1"}, :_})
        base

      [] ->
        System.unique_integer([:positive])
    end
  end

  defp load_historical_indices(_, _), do: :ok

  defp log_buffer(s), do: :"bimip_buf_#{s}"
  defp idx_cache(s), do: :"bimip_idx_#{s}"
  defp idx_cache_device(s), do: :"bimip_idx_device_#{s}"
  defp worker_name(s), do: :"bimip_shard_#{s}"
  defp schedule_flush, do: Process.send_after(self(), :flush, @flush_interval)
end
