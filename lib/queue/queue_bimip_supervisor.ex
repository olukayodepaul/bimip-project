defmodule Queue.BimipSupervisor do
  use Supervisor

  def start_link(_init_arg \\ []) do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end


  @impl true
  def init(_init_arg) do
    # 1. Infrastructure Setup (Synchronous)
    Queue.QueueLogImpl.__startup__()
    Queue.MessageTracker.init()
    Queue.DeviceBookmark.startup()

    for s <- 0..63 do
      table = :"fd_pool_#{s}"
      if :ets.info(table) == :undefined do
        :ets.new(table, [:ordered_set, :public, :named_table, read_concurrency: true])
      end
    end

    # 2. Define the static workers
    base_children = [
      {Queue.FDPoolSupervisor, []},
      {Queue.MessageTracker.Sweeper, []},
      {Queue.BimipCompactor, []}
    ]

    # 3. Define the 64 shards as direct children
    shard_children = for s <- 0..63 do
      %{
        id: :"shard_#{s}",
        start: {Queue.QueueLogImpl, :start_link, [s]},
        restart: :permanent,
        type: :worker
      }
    end

    # 4. Change strategy to :one_for_one
    # (So if shard 5 crashes, shards 1-4 and 6-63 stay alive!)
    Supervisor.init(base_children ++ shard_children, strategy: :one_for_one)
  end

  defp start_shards do
    for s <- 0..63 do
      Supervisor.start_child(__MODULE__,
        Supervisor.child_spec({Queue.QueueLogImpl, s}, id: :"shard_#{s}")
      )
    end
  end
end
