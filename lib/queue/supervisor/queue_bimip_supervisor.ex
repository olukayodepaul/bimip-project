defmodule Queue.BimipSupervisor do
  use Supervisor

  @num_shards 64

  def start_link(_init_arg \\ []) do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    # 1. Infrastructure Setup
    Queue.QueueLogImpl.__startup__()
    Queue.MessageTracker.init()

    for s <- 0..(@num_shards - 1) do
      table = :"fd_pool_#{s}"
      if :ets.info(table) == :undefined do
        :ets.new(table, [:ordered_set, :public, :named_table, read_concurrency: true])
      end
    end

    # 2. Define the static global workers
    # Removed the single Sweeper from here
    base_children = [
      {Queue.DeviceBookmark, []},
      {Queue.FDPoolSupervisor, []},
      {Queue.BimipCompactor, []}
    ]

    # 3. Define the 64 Shards AND 64 Sweepers
    # We pair each Log Worker with its dedicated Sweeper
    shard_children = for s <- 0..(@num_shards - 1) do
      [
        Supervisor.child_spec({Queue.ShardServer, s}, id: :"shard_sequencer_#{s}"),
        Supervisor.child_spec({Queue.QueueLogImpl, s}, id: :"shard_#{s}", shutdown: 30_000),
        Supervisor.child_spec({Queue.MessageTracker.Sweeper, s}, id: :"sweeper_#{s}")
      ]
    end |> List.flatten()

    # Use :one_for_one so a crash in Shard 5 doesn't reset Shard 6
    Supervisor.init(base_children ++ shard_children, strategy: :one_for_one)
  end
end
