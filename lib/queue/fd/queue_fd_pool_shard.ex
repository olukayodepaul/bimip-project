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

  @doc """
  Triggers an atomic write-rename snapshot for the shard state.
  """
  def atomic_snapshot(shard_id, path, data) do
    GenServer.cast(via(shard_id), {:atomic_snapshot, path, data})
  end

  # Add to Client API
  def read_bin(shard_id, path) do
    GenServer.call(via(shard_id), {:read_bin, path})
  end

# Add to Server Callbacks


  # --- Server Callbacks ---

  def init(shard_id) do
    table = :"fd_pool_#{shard_id}"
    # Ensure ETS table exists for this shard
    if :ets.info(table) == :undefined do
      :ets.new(table, [:named_table, :public, :ordered_set, {:read_concurrency, true}])
    end
    {:ok, %{shard: shard_id, table: table}}
  end

  @impl true
  def handle_call({:pread, path, pos, length}, _from, state) do
    case get_internal_fd(path, state) do
      {:ok, fd} ->
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
  def handle_cast({:atomic_snapshot, final_path, data}, state) do
    tmp_path = "#{final_path}.tmp"

    # Write-Rename Pattern
    case :file.open(tmp_path, [:write, :raw, :binary]) do
      {:ok, fd} ->
        :file.write(fd, data)
        :file.datasync(fd)
        :file.close(fd)
        :file.rename(tmp_path, final_path)
      {:error, _reason} ->
        :ok # Fail silently or Log
    end
    {:noreply, state}
  end

  @impl true
  def handle_cast({:touch, path, fd, old_ts}, state) do
    table = state.table
    now = :erlang.monotonic_time(:millisecond)
    :ets.delete(table, {:evict, old_ts, path})
    :ets.insert(table, [{{:lookup, path}, fd, now}, {{:evict, now, path}, true}])
    {:noreply, state}
  end

  @impl true
  def handle_call({:read_bin, path}, _from, state) do
    case get_internal_fd(path, state) do
      {:ok, fd} ->
        # 1. Seek to the end to find the file size
        case :file.position(fd, :eof) do
          {:ok, size} ->
            # 2. Read the full size from the beginning (offset 0)
            {:reply, :file.pread(fd, 0, size), state}
          error ->
            {:reply, error, state}
        end
      error ->
        {:reply, error, state}
    end
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
            now = :erlang.monotonic_time(:millisecond)
            :ets.insert(table, [{{:lookup, path}, fd, now}, {{:evict, now, path}, true}])
            {:ok, fd}
          error -> error
        end
    end
  end

  defp evict_if_needed(table) do
    if div(:ets.info(table, :size), 2) >= @max_read_fds do
      case :ets.first(table) do
        {:evict, ts, path} ->
          case :ets.lookup(table, {:lookup, path}) do
            [{_, fd, ^ts}] ->
              :file.close(fd)
              :ets.delete(table, {:lookup, path})
              :ets.delete(table, {:evict, ts, path})
              evict_if_needed(table)
            _ ->
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
