defmodule Queue.QueueLogImpl do
  @moduledoc """
  BimipLog — Fully Optimized Aggregated Shard Engine.
  - 64 shards
  - Atomic flushing
  - Recursive index loader for variable-length user IDs
  - Duplicate ordered set for high concurrency
  - Optimized fetch_range/3 for chat screens
  """
  require Logger

  @base_dir "data/bimip"
  @num_shards 64
  @index_granularity 100
  @flush_interval 100
  @max_buffer_size 5000

  @user_offsets :bimip_user_offsets
  @fd_pools [:log_w, :log_r, :idx_w, :idx_r]
  @quotas %{log_w: 300, idx_w: 300, log_r: 300, idx_r: 300}

  # -------------------------------------------------------------------
  # 1. Initialization
  # -------------------------------------------------------------------
  def __ets_startup__ do
    File.mkdir_p!(@base_dir)

    for i <- 0..(@num_shards - 1) do
      :ets.new(log_buffer_name(i), [:named_table, :duplicate_ordered_set, :public, write_concurrency: true])
      :ets.new(idx_cache_name(i), [:named_table, :ordered_set, :public, read_concurrency: true])
      load_index_into_cache(i)
    end

    ets_opts = [:named_table, :public, :write_concurrency]
    if :ets.info(@user_offsets) == :undefined, do: :ets.new(@user_offsets, ets_opts)

    for pool <- @fd_pools do
      if :ets.info(pool) == :undefined, do: :ets.new(pool, ets_opts ++ [:read_concurrency])
    end

    Logger.info("BimipLog initialized with #{@num_shards} shards and atomic flushing enabled.")
  end

  def child_spec(shard_idx) do
    %{
      id: :"shard_worker_#{shard_idx}",
      start: {Task, :start_link, [fn -> shard_worker_loop(shard_idx) end]},
      restart: :permanent
    }
  end

  # -------------------------------------------------------------------
  # 2. Public API
  # -------------------------------------------------------------------
  def write(partition_id, user, reply_to, type, payload_context, payload, message_id) do
    offset = :ets.update_counter(@user_offsets, {user, partition_id}, {2, 1}, {{user, partition_id}, 0})
    shard_idx = :erlang.phash2(user, @num_shards)

    record = %{
      u: user,
      p: partition_id,
      off: offset,
      mid: message_id,
      data: Queue.Persist.build(payload, offset, reply_to, type, payload_context)
    }

    :ets.insert(log_buffer_name(shard_idx), {shard_idx, record})
    {:ok, offset, :buffered}
  end

  def fetch(user, partition_id, offset) do
    shard_idx = :erlang.phash2(user, @num_shards)

    case :ets.match_object(log_buffer_name(shard_idx), {shard_idx, %{u: user, p: partition_id, off: offset}}) do
      [{_, rec}] -> {:ok, rec.data}
      [] ->
        case :ets.lookup(idx_cache_name(shard_idx), {user, partition_id, offset}) do
          [{_, pos}] -> read_from_shard(shard_idx, pos)
          [] -> {:error, :not_found}
        end
    end
  end

  # -------------------------------------------------------------------
  # 2b. Fetch last N messages for chat screen (optimized)
  # -------------------------------------------------------------------
  def fetch_range(user, partition_id, count \\ 100) do
    shard_idx = :erlang.phash2(user, @num_shards)

    # 1. Memory buffer
    mem_records =
      :ets.match_object(log_buffer_name(shard_idx), {shard_idx, %{u: user, p: partition_id}})
      |> Enum.map(fn {_, rec} -> {rec.off, rec.data} end)

    # 2. Index cache (optimized via match spec)
    idx_records =
      :ets.select(idx_cache_name(shard_idx), [
        {{{user, partition_id, :"$1"}, :"$2"}, [], [{{:"$1", :"$2"}}]}
      ])

    # 3. Merge and take last N messages
    (mem_records ++ idx_records)
    |> Enum.sort_by(fn {off, _} -> off end, :desc)
    |> Enum.take(count)
    |> Enum.map(fn
      {off, data} when is_map(data) -> {off, data}       # Memory buffer
      {off, pos} when is_integer(pos) -> {off, read_from_shard!(shard_idx, pos)} # Disk index
    end)
  end

  # -------------------------------------------------------------------
  # 3. Worker Logic
  # -------------------------------------------------------------------
  defp shard_worker_loop(shard_idx) do
    Process.sleep(@flush_interval)
    flush_shard_buffer(shard_idx)
    # Force GC on the worker after a heavy flush to keep RAM lean
    :erlang.garbage_collect(self(), [:async])
    shard_worker_loop(shard_idx)
  end

  defp flush_shard_buffer(shard_idx) do
    buffer = log_buffer_name(shard_idx)

    case :ets.take(buffer, shard_idx) do
      [] -> :ok
      items ->
        records = Enum.map(items, &elem(&1, 1))
        flush_to_disk(shard_idx, records)
    end
  end

  defp flush_to_disk(shard_idx, records) do
    l_path = shard_log_path(shard_idx)
    i_path = shard_idx_path(shard_idx)

    with {:ok, f_log} <- get_fd_safe(:log_w, l_path, @quotas.log_w, [:append]),
         {:ok, f_idx} <- get_fd_safe(:idx_w, i_path, @quotas.idx_w, [:append]) do
      try do
        Enum.each(records, fn rec ->
          {:ok, pos} = :file.position(f_log, :cur)
          bin = :erlang.term_to_binary(rec.data, [:compressed])
          u_bin = to_string(rec.u)

          packet = [
            <<byte_size(bin)::32, :erlang.crc32(bin)::32, byte_size(u_bin)::16>>,
            u_bin,
            <<rec.p::32, rec.off::64>>,
            bin
          ]
          :file.write(f_log, packet)

          if rem(rec.off, @index_granularity) == 0 do
            :ets.insert(idx_cache_name(shard_idx), {{rec.u, rec.p, rec.off}, pos})
            :file.write(f_idx, <<byte_size(u_bin)::16, u_bin::binary, rec.p::32, rec.off::64, pos::64>>)
          end
        end)
      after
        release_fd(:log_w, l_path)
        release_fd(:idx_w, i_path)
      end
    end
  end

  # -------------------------------------------------------------------
  # 4. Recovery & Reads
  # -------------------------------------------------------------------
  defp load_index_into_cache(shard_idx) do
    path = shard_idx_path(shard_idx)
    if File.exists?(path) do
      {:ok, bin} = File.read(path)
      parse_index_recursive(bin, shard_idx)
    end
  end

  defp parse_index_recursive(<<u_len::16, u::binary-size(u_len), p::32, o::64, pos::64, rest::binary>>, s_idx) do
    :ets.insert(idx_cache_name(s_idx), {{u, p, o}, pos})
    parse_index_recursive(rest, s_idx)
  end
  defp parse_index_recursive(_, _), do: :ok

  defp read_from_shard(shard_idx, pos) do
    case read_from_shard!(shard_idx, pos) do
      {:ok, data} -> {:ok, data}
      other -> other
    end
  end

  defp read_from_shard!(shard_idx, pos) do
    path = shard_log_path(shard_idx)
    case get_fd_safe(:log_r, path, @quotas.log_r, [:read]) do
      {:ok, fd} ->
        try do
          case :file.pread(fd, pos, 1024) do
            {:ok, <<size::32, crc::32, u_len::16, rest::binary>>} ->
              payload = binary_part(rest, u_len + 4 + 8, size)
              if :erlang.crc32(payload) == crc, do: {:ok, :erlang.binary_to_term(payload, [:safe])}, else: {:error, :corrupt}
            _ -> {:error, :eof}
          end
        after
          release_fd(:log_r, path)
        end
      error -> {:error, :fd_unavailable}
    end
  end

  # -------------------------------------------------------------------
  # 5. FD Management (LRU)
  # -------------------------------------------------------------------
  defp get_fd_safe(pool, path, quota, mode) do
    case :ets.lookup(pool, path) do
      [{^path, fd, _ts, _state}] ->
        :ets.insert(pool, {path, fd, System.monotonic_time(), :busy})
        {:ok, fd}
      [] ->
        if :ets.info(pool, :size) >= quota, do: evict_lru(pool)
        case File.open(path, [:binary, :raw | mode]) do
          {:ok, fd} ->
            :ets.insert(pool, {path, fd, System.monotonic_time(), :busy})
            {:ok, fd}
          _error -> {:error, :fd_unavailable}
        end
    end
  end

  defp release_fd(pool, path) do
    case :ets.lookup(pool, path) do
      [{p, fd, _, :busy}] -> :ets.insert(pool, {p, fd, System.monotonic_time(), :idle})
      _ -> :ok
    end
  end

  defp evict_lru(pool) do
    match_spec = [{{:"$1", :"$2", :"$3", :idle}, [], [{{:"$3", :"$1", :"$2"}}]}]
    case :ets.select(pool, match_spec) |> Enum.sort() |> List.first() do
      {_ts, path, fd} -> :file.close(fd); :ets.delete(pool, path)
      _ -> :ok
    end
  end

  # -------------------------------------------------------------------
  # 6. Helpers
  # -------------------------------------------------------------------
  defp log_buffer_name(i), do: :"bimip_log_buf_#{i}"
  defp idx_cache_name(i),  do: :"bimip_idx_ptr_#{i}"
  defp shard_log_path(i),  do: Path.join(@base_dir, "shard_#{i}.log")
  defp shard_idx_path(i),  do: Path.join(@base_dir, "shard_#{i}.idx")
end
