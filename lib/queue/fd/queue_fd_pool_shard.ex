defmodule Queue.FDPoolShard do
  use GenServer

  # We use 7 as the limit for historical reads
  @max_read_fds 11

  def start_link(shard_id), do: GenServer.start_link(__MODULE__, shard_id, name: via(shard_id))

  # --- Client API ---

  def pread(shard_id, path, pos, length) do
    GenServer.call(via(shard_id), {:pread, path, pos, length})
  end

  def close_fd(shard_id, path) do
    GenServer.call(via(shard_id), {:close_force, path})
  end

  # --- Server Callbacks ---

  def init(shard_id) do
    table = :"fd_pool_#{shard_id}"
    {:ok, %{shard: shard_id, table: table}}
  end

  @impl true
  def handle_call({:pread, path, pos, length}, _from, state) do
    case get_internal_fd(path, state) do
      {:ok, fd} ->
        # The Pool owns this FD, so pread here is safe and fast
        {:reply, :file.pread(fd, pos, length), state}
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:close_force, path}, _from, state) do
    table = state.table
    case :ets.lookup(table, {:lookup, path}) do
      [{_, fd, ts}] ->
        :file.close(fd)
        :ets.delete(table, {:lookup, path})
        :ets.delete(table, {:evict, ts, path})
        {:reply, :ok, state}
      [] ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_cast({:touch, path, fd, old_ts}, state) do
    table = state.table
    now = :erlang.monotonic_time(:millisecond)
    :ets.delete(table, {:evict, old_ts, path})
    :ets.insert(table, [{{:lookup, path}, fd, now}, {{:evict, now, path}, true}])
    {:noreply, state}
  end

  # --- Private Helpers ---

  defp get_internal_fd(path, state) do
    table = state.table
    case :ets.lookup(table, {:lookup, path}) do
      [{_, fd, old_ts}] ->
        # Refresh LRU status so it isn't evicted
        GenServer.cast(self(), {:touch, path, fd, old_ts})
        {:ok, fd}
      [] ->
        # Limit check before opening new one
        evict_if_needed(table)
        case :file.open(path, [:read, :raw, :binary]) do
          {:ok, fd} ->
            now = :erlang.monotonic_time(:millisecond)
            :ets.insert(table, [{{:lookup, path}, fd, now}, {{:evict, now, path}, true}])
            {:ok, fd}
          error -> error
        end
    end
  end

  defp evict_if_needed(table) do
    # 2 keys per file (lookup + evict). If size/2 >= 7, we evict.
    if div(:ets.info(table, :size), 2) >= @max_read_fds do
      case :ets.first(table) do
        {:evict, ts, path} ->
          case :ets.lookup(table, {:lookup, path}) do
            [{_, fd, ^ts}] ->
              :file.close(fd)
              :ets.delete(table, {:lookup, path})
              :ets.delete(table, {:evict, ts, path})
              # Recursive check in case size is still high
              evict_if_needed(table)
            _ ->
              # Stale key, just clean and retry
              :ets.delete(table, {:evict, ts, path})
              evict_if_needed(table)
          end
        _ -> :ok
      end
    else
      :ok
    end
  end

  defp via(s), do: {:via, Registry, {Queue.FDPoolRegistry, s}}
end
