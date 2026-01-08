defmodule Queue.FDPoolShard do
  use GenServer

  @max_read_fds 16

  def start_link(shard_id), do: GenServer.start_link(__MODULE__, shard_id, name: via(shard_id))

  def get_fd(shard_id, path) do
    table = table_name(shard_id)
    case :ets.lookup(table, {:lookup, path}) do
      [{_, fd, old_ts}] ->
        # Pass old_ts to allow O(1) deletion in the cast
        GenServer.cast(via(shard_id), {:touch, path, fd, old_ts})
        {:ok, fd}
      [] ->
        GenServer.call(via(shard_id), {:open_fd, path})
    end
  end

  @impl true
  def init(shard_id) do
    table = table_name(shard_id)
    # MUST be :ordered_set for :ets.first to return the oldest timestamp
    :ets.new(table, [:ordered_set, :public, read_concurrency: true])
    {:ok, %{shard: shard_id, table: table}}
  end

  @impl true
  def handle_cast({:touch, path, fd, old_ts}, state) do
    table = state.table
    now = :erlang.monotonic_time(:millisecond)

    # O(1) update logic
    :ets.delete(table, {:evict, old_ts, path})
    :ets.insert(table, {{:lookup, path}, fd, now})
    :ets.insert(table, {{:evict, now, path}, true})
    {:noreply, state}
  end

  @impl true
  def handle_call({:open_fd, path}, _from, state) do
    table = state.table
    evict_if_needed(table)
    now = :erlang.monotonic_time(:millisecond)

    case :file.open(path, [:read, :raw, :binary]) do
      {:ok, fd} ->
        :ets.insert(table, [{{:lookup, path}, fd, now}, {{:evict, now, path}, true}])
        {:reply, {:ok, fd}, state}
      {:error, reason} ->
        {:reply, {:error, reason}, state}
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
              # Entry was likely updated by a concurrent touch; drop stale evict key
              :ets.delete(table, {:evict, ts, path})
              evict_if_needed(table)
          end
        _ -> :ok
      end
    end
  end

  defp table_name(s), do: :"fd_pool_#{s}"
  defp via(s), do: {:via, Registry, {Queue.FDPoolRegistry, s}}
end
