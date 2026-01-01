defmodule Queue.QueueLogImpl do
  @moduledoc """
  BimipLog v6 — Production-Grade Sharded Append-Only Log.
  Includes fsync durability, graceful shutdown, and compaction swap.
  """
  use GenServer
  require Logger

  # ------------------------------------------------------------------
  # CONFIGURATION
  # ------------------------------------------------------------------
  @base_dir "data/bimip"
  @num_shards 64
  @header_size 19 # Updated: 0xEE(1) + size(4) + crc(4) + ulen(2) + ts(8)
  @flush_interval 100
  @max_segment_size 100 * 1024 * 1024
  @max_buffer_per_shard 100_000
  @user_offsets :bimip_user_offsets
  @read_pool_log :bimip_log_reader_pool
  @pool_quota 500
  @max_disk_write_retries 3

  # ------------------------------------------------------------------
  # PUBLIC API
  # ------------------------------------------------------------------

  def write(partition_id, user, device_id, type, payload_ctx, payload, message_id) do
    shard = :erlang.phash2(user, @num_shards)
    buf = log_buffer(shard)

    if :ets.info(buf, :size) > @max_buffer_per_shard do
      {:error, :backpressure}
    else
      offset = :ets.update_counter(@user_offsets, {user, partition_id}, {2, 1}, {{user, partition_id}, 0})

      record = %{
        u: user,
        p: partition_id,
        off: offset,
        mid: message_id,
        writer_device: device_id,         # NEW: track which device wrote it
        data: Queue.Persist.build(payload, offset, type, payload_ctx),
        ts: System.system_time(:second)
      }

      :ets.insert(buf, {shard, offset, record})
      {:ok, offset}
    end
  end

  # Fetch messages skipping ones written by this device
  def fetch_for_device(user, partition_id, device_id, offset) do
    shard = :erlang.phash2(user, @num_shards)

    case :ets.match_object(log_buffer(shard), {shard, offset, %{u: user, p: partition_id}}) do
      [{_, _, rec}] ->
        if rec.writer_device == device_id do
          {:ok, []} # skip own message
        else
          {:ok, [rec.data]}
        end

      [] ->
        case :ets.lookup(idx_cache(shard), {user, partition_id, offset}) do
          [{{^user, ^partition_id, ^offset}, {seg_base, pos}}] ->
            with {:ok, rec} <- read_from_disk(shard, seg_base, pos) do
              # assume rec has writer_device stored in it
              if Map.get(rec, :writer_device) == device_id do
                {:ok, []} # skip own message
              else
                {:ok, [rec.data]}
              end
            else
              _ -> {:error, :read_failed}
            end

          [] -> {:error, :not_found}
        end
    end
  end


  def fetch(user, partition_id, offset) do
    shard = :erlang.phash2(user, @num_shards)
    case :ets.match_object(log_buffer(shard), {shard, offset, %{u: user, p: partition_id}}) do
      [{_, _, rec}] -> {:ok, rec.data}
      [] ->
        case :ets.lookup(idx_cache(shard), {user, partition_id, offset}) do
          [{{^user, ^partition_id, ^offset}, {seg_base, pos}}] ->
            read_from_disk(shard, seg_base, pos)
          [] -> {:error, :not_found}
        end
    end
  end

  # ------------------------------------------------------------------
  # GENSERVER CORE
  # ------------------------------------------------------------------

  def start_link(shard), do: GenServer.start_link(__MODULE__, shard, name: worker_name(shard))

  @impl true
  def init(shard) do
    Process.flag(:trap_exit, true)
    File.mkdir_p!(@base_dir)
    manifest = load_manifest(shard)
    load_historical_indices(shard, manifest.base)

    opts = [:append, :raw, :binary, {:delayed_write, 64 * 1024, 100}]
    {:ok, log_fd} = :file.open(manifest.log, opts)
    {:ok, idx_fd} = :file.open(manifest.idx, opts)
    {:ok, pos} = :file.position(log_fd, :cur)

    schedule_flush()
    {:ok, %{shard: shard, log_fd: log_fd, idx_fd: idx_fd, current_size: pos, active_base: manifest.base}}
  end

  @impl true
  def handle_info(:flush, state) do
    {:noreply, perform_flush(state)}
  end

  @impl true
  def terminate(_reason, state) do
    Logger.info("Shard #{state.shard} shutting down. Finalizing flush...")
    perform_flush(state)
    :file.close(state.log_fd)
    :file.close(state.idx_fd)
  end

  @impl true
  def handle_call({:compact_swap, old_bases, new_base, _files, mappings}, _from, state) do
    if state.active_base in old_bases do
      {:reply, {:error, :active_segment_collision}, state}
    else
      :ets.insert(idx_cache(state.shard), mappings)
      Enum.each(old_bases, fn base ->
        path = Path.join(@base_dir, "shard_#{state.shard}_#{base}.log")
        :ets.delete(@read_pool_log, path)
        File.rm(path)
        File.rm(Path.join(@base_dir, "shard_#{state.shard}_#{base}.idx"))
      end)
      {:reply, :ok, state}
    end
  end

  # ------------------------------------------------------------------
  # STORAGE LOGIC
  # ------------------------------------------------------------------

  defp perform_flush(state) do
    buffer = log_buffer(state.shard)
    items = :ets.select(buffer, [{{state.shard, :"$1", :"$2"}, [], [{{:"$1", :"$2"}}]}] )
    :ets.select_delete(buffer, [{{state.shard, :_, :_}, [], [true]}])

    case items do
      [] -> state
      _ ->
        sorted = Enum.sort_by(items, fn {off, _} -> off end, :asc)
        state = if state.current_size >= @max_segment_size, do: rotate_segment(state), else: state
        new_state = flush_records_safe(state, sorted)

        # Hard Durability (fsync)
        :file.datasync(new_state.log_fd)
        :file.datasync(new_state.idx_fd)

        schedule_flush()
        new_state
    end
  end

  defp flush_records_safe(state, records) do
    Enum.reduce(records, state, fn {offset, rec}, acc ->
      do_write(acc, rec, offset, @max_disk_write_retries)
    end)
  end

  defp do_write(state, rec, offset, retries_left) when retries_left > 0 do
    try do
      {:ok, pos} = :file.position(state.log_fd, :cur)
      bin = :erlang.term_to_binary(rec.data, [:compressed])
      user_bin = to_string(rec.u)

      packet = [
        <<0xEE, byte_size(bin)::32, :erlang.crc32(bin)::32, byte_size(user_bin)::16, rec.ts::64>>,
        user_bin, <<rec.p::32, offset::64>>, bin
      ]

      :ok = :file.write(state.log_fd, packet)
      :ok = :file.write(state.idx_fd, <<byte_size(user_bin)::16, user_bin::binary, rec.p::32, offset::64, pos::64>>)
      :ets.insert(idx_cache(state.shard), {{rec.u, rec.p, offset}, {state.active_base, pos}})

      %{state | current_size: state.current_size + IO.iodata_length(packet)}
    rescue
      _ ->
        :timer.sleep(50)
        do_write(state, rec, offset, retries_left - 1)
    end
  end

  defp do_write(_state, rec, _offset, 0), do: raise "I/O Failure on message #{rec.mid}"

  defp read_from_disk(shard, base, pos) do
    path = Path.join(@base_dir, "shard_#{shard}_#{base}.log")
    with {:ok, fd} <- reader_fd(@read_pool_log, path),
         {:ok, <<0xEE, size::32, crc::32, ulen::16, _ts::64>>} <- :file.pread(fd, pos, @header_size),
         body_total = ulen + 12 + size,
         {:ok, body} <- :file.pread(fd, pos + @header_size, body_total) do
      payload = binary_part(body, ulen + 12, size)
      if :erlang.crc32(payload) == crc, do: {:ok, :erlang.binary_to_term(payload, [:safe])}, else: {:error, :corrupt}
    else
      _ -> {:error, :read_failed}
    end
  end

  # ------------------------------------------------------------------
  # SYSTEM HELPERS
  # ------------------------------------------------------------------

  def __startup__ do
    File.mkdir_p!(@base_dir)
    :ets.new(@user_offsets, [:named_table, :public, {:write_concurrency, true}, {:read_concurrency, true}])
    :ets.new(@read_pool_log, [:named_table, :public])

    for s <- 0..(@num_shards - 1) do
      :ets.new(log_buffer(s), [:named_table, :duplicate_bag, :public, {:write_concurrency, true}, {:read_concurrency, true}])
      :ets.new(idx_cache(s), [:named_table, :ordered_set, :public, {:read_concurrency, true}])
    end
    recover_user_offsets()
  end

  defp recover_user_offsets do
    Path.join(@base_dir, "*.idx") |> Path.wildcard() |> Enum.each(fn path ->
      case File.read(path) do
        {:ok, bin} -> safe_sync_offsets(bin)
        _ -> :ok
      end
    end)
  end

  defp safe_sync_offsets(<<ul::16, u::binary-size(ul), p::32, off::64, _::64, rest::binary>>) do
    :ets.update_counter(@user_offsets, {u, p}, {2, 0}, {{u, p}, off})
    safe_sync_offsets(rest)
  end
  defp safe_sync_offsets(_), do: :ok

  defp rotate_segment(state) do
    :file.close(state.log_fd)
    :file.close(state.idx_fd)
    base = System.unique_integer([:monotonic, :positive])
    log = Path.join(@base_dir, "shard_#{state.shard}_#{base}.log")
    idx = Path.join(@base_dir, "shard_#{state.shard}_#{base}.idx")
    save_manifest(state.shard, log, idx, base)
    opts = [:append, :raw, :binary, {:delayed_write, 64 * 1024, 100}]
    {:ok, n_log} = :file.open(log, opts)
    {:ok, n_idx} = :file.open(idx, opts)
    %{state | log_fd: n_log, idx_fd: n_idx, current_size: 0, active_base: base}
  end

  defp reader_fd(pool, path) do
    case :ets.lookup(pool, path) do
      [{^path, fd, _}] ->
        :ets.insert(pool, {path, fd, :erlang.monotonic_time()})
        {:ok, fd}
      [] ->
        if :ets.info(pool, :size) >= @pool_quota, do: evict_lru(pool)
        case :file.open(path, [:read, :raw, :binary]) do
          {:ok, fd} -> :ets.insert(pool, {path, fd, :erlang.monotonic_time()}); {:ok, fd}
          err -> err
        end
    end
  end

  defp evict_lru(pool) do
    case :ets.tab2list(pool) |> Enum.min_by(&elem(&1, 2), fn -> nil end) do
      {path, fd, _} -> :file.close(fd); :ets.delete(pool, path)
      _ -> :ok
    end
  end

  defp load_historical_indices(shard, active_base) do
    Path.join(@base_dir, "shard_#{shard}_*.idx")
    |> Path.wildcard()
    |> Enum.reject(&String.contains?(&1, "_#{active_base}.idx"))
    |> Enum.each(fn path ->
      case File.read(path) do
        {:ok, bin} ->
          [_, _, base_str] = path |> Path.basename(".idx") |> String.split("_")
          parse_idx_bin(shard, String.to_integer(base_str), bin)
        _ -> :ok
      end
    end)
  end

  defp parse_idx_bin(s, b, <<ul::16, u::binary-size(ul), p::32, o::64, pos::64, rest::binary>>) do
    :ets.insert(idx_cache(s), {{u, p, o}, {b, pos}})
    parse_idx_bin(s, b, rest)
  end
  defp parse_idx_bin(_, _, _), do: :ok

  defp load_manifest(shard) do
    path = Path.join(@base_dir, "shard_#{shard}.manifest")
    case File.read(path) do
      {:ok, bin} -> :erlang.binary_to_term(bin)
      _ ->
        base = System.unique_integer([:monotonic, :positive])
        %{log: Path.join(@base_dir, "shard_#{shard}_#{base}.log"), idx: Path.join(@base_dir, "shard_#{shard}_#{base}.idx"), base: base}
    end
  end

  defp save_manifest(shard, log, idx, base) do
    path = Path.join(@base_dir, "shard_#{shard}.manifest")
    File.write!(path, :erlang.term_to_binary(%{log: log, idx: idx, base: base}))
  end

  defp log_buffer(s), do: :"bimip_buf_#{s}"
  defp idx_cache(s), do: :"bimip_idx_#{s}"
  defp worker_name(s), do: :"bimip_shard_#{s}"
  defp schedule_flush, do: Process.send_after(self(), :flush, @flush_interval)

end
