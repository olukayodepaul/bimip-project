defmodule Queue.FDPoolSupervisor do
  @moduledoc """
  Starts the Registry and all shard-local FD pools under supervision
  """
  use Supervisor

  @num_shards 64

  def start_link(_) do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    # 1️⃣ Registry for all shards
    registry = %{
      id: Queue.FDPoolRegistry,
      start: {Registry, :start_link, [[keys: :unique, name: Queue.FDPoolRegistry]]},
      type: :worker,
      restart: :permanent
    }

    # 2️⃣ All shard workers
    shard_workers =
      for shard <- 0..(@num_shards - 1) do
        %{
          id: {:fd_pool, shard},
          start: {Queue.FDPoolShard, :start_link, [shard]},
          type: :worker,
          restart: :permanent
        }
      end

    children = [registry | shard_workers]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
