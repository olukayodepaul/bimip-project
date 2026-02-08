defmodule Queue.FDPoolShard do
  use GenServer
  require Logger

  # Limits open FDs to 11 per shard (64 shards * 11 = 704 total, well under 1024 limit)
  @max_read_fds 11

  def start_link(shard_id), do: GenServer.start_link(__MODULE__, shard_id, name: via(shard_id))

  # --- Client API ---

  def pread(shard_id, path, pos, length), do: GenServer.call(via(shard_id), {:pread, path, pos, length})

  def read_bin(shard_id, path), do: GenServer.call(via(shard_id), {:read_bin, path})

  def close_fd(shard_id, path), do: GenServer.call(via(shard_id), {:close_force, path})

  def atomic_snapshot(shard_id, path, data), do: GenServer.cast(via(shard_id), {:atomic_snapshot, path, data})

  # --- Server Callbacks ---

  def init(shard_id) do
    table = :"fd_pool_#{shard_id}"
    if :ets.info(table) == :undefined do
      :ets.new(table, [:named_table, :public, :ordered_set, {:read_concurrency, true}])
    end
    {:ok, %{shard: shard_id, table: table}}
  end

  @impl true
  def handle_call({:pread, path, pos, length}, _from, state) do
    case get_internal_fd(path, state) do
      {:ok, fd} -> {:reply, :file.pread(fd, pos, length), state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:read_bin, path}, _from, state) do
    case get_internal_fd(path, state) do
      {:ok, fd} ->
        case :file.position(fd, :eof) do
          {:ok, size} -> {:reply, :file.pread(fd, 0, size), state}
          error -> {:reply, error, state}
        end
      error -> {:reply, error, state}
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
      [] -> {:reply, :ok, state}
    end
  end

  @impl true
  def handle_cast({:atomic_snapshot, final_path, data}, state) do
    tmp_path = "#{final_path}.tmp"
    bak_path = "#{final_path}.bak"

    # Close any open read-only FD for this path before renaming
    # This prevents "file in use" errors during the rename
    handle_call({:close_force, final_path}, nil, state)

    case :file.open(tmp_path, [:write, :raw, :binary]) do
      {:ok, fd} ->
        :file.write(fd, data)
        :file.datasync(fd)
        :file.close(fd)
        if File.exists?(final_path), do: :file.rename(final_path, bak_path)
        :file.rename(tmp_path, final_path)
      {:error, reason} ->
        Logger.error("Shard #{state.shard} failed to write snapshot: #{inspect(reason)}")
    end
    {:noreply, state}
  end

  @impl true
  def handle_cast({:touch, path, fd, old_ts}, state) do
    table = state.table
    now = :erlang.monotonic_time(:nanosecond)
    :ets.delete(table, {:evict, old_ts, path})
    :ets.insert(table, [{{:lookup, path}, fd, now}, {{:evict, now, path}, true}])
    {:noreply, state}
  end

  # --- Private Helpers ---

  defp get_internal_fd(path, state) do
    table = state.table
    case :ets.lookup(table, {:lookup, path}) do
      [{_, fd, old_ts}] ->
        GenServer.cast(self(), {:touch, path, fd, old_ts})
        {:ok, fd}
      [] ->
        evict_if_needed(table)
        case :file.open(path, [:read, :raw, :binary]) do
          {:ok, fd} ->
            now = :erlang.monotonic_time(:nanosecond)
            :ets.insert(table, [{{:lookup, path}, fd, now}, {{:evict, now, path}, true}])
            {:ok, fd}
          error -> error
        end
    end
  end

  defp evict_if_needed(table) do
    current_size = :ets.info(table, :size) || 0
    if div(current_size, 2) >= @max_read_fds do
      first_key = :ets.first(table)
      case first_key do
        {:evict, ts, path} ->
          case :ets.lookup(table, {:lookup, path}) do
            [{_, fd, ^ts}] ->
              :file.close(fd)
              :ets.delete(table, {:lookup, path})
              :ets.delete(table, {:evict, ts, path})
              evict_if_needed(table)
            _ ->
              :ets.delete(table, first_key)
              evict_if_needed(table)
          end
        {:lookup, _path} -> find_and_evict_oldest(table, first_key)
        _ -> :ok
      end
    else
      :ok
    end
  end

  defp find_and_evict_oldest(_table, :"$end_of_table"), do: :ok
  defp find_and_evict_oldest(table, key) do
    case key do
      {:evict, _, _} -> evict_if_needed(table)
      _ -> find_and_evict_oldest(table, :ets.next(table, key))
    end
  end

  defp via(s), do: {:via, Registry, {Queue.FDPoolRegistry, s}}
end
