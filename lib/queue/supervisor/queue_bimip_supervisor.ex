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

    # Create ETS tables (optimizing for 64-core concurrency)
    for s <- 0..(@num_shards - 1) do
      table = :"fd_pool_#{s}"
      if :ets.info(table) == :undefined do
        :ets.new(table, [
          :ordered_set,
          :public,
          :named_table,
          read_concurrency: true,
          write_concurrency: :auto # Critical for 64-core write performance
        ])
      end
    end

    # 2. Define the static global workers
    base_children = [
      {Queue.DeviceBookmark, []},
      {Queue.FDPoolSupervisor, []},
      {Queue.BimipCompactor, []}
    ]

    # 3. Define the PartitionSupervisor
    # This replaces your manual 'for' loop and distributes the 64 shards
    # across 64 internal partition-managers.
    partition_child = {
      PartitionSupervisor,
      child_spec: Queue.ShardGroup,
      name: Queue.ShardPartitions,
      partitions: @num_shards,
      # Pass the partition index (0..63) to each ShardGroup
      with_arguments: fn [_arg], partition -> [partition] end
    }

    Supervisor.init(base_children ++ [partition_child], strategy: :one_for_one)
  end
end
