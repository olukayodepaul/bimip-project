defmodule Queue.FDPoolSupervisor do
  @moduledoc """
  Starts the Registry and all shard-local FD pools under supervision.
  Uses dynamic configuration to match the global shard count.
  """
  use Supervisor

  def start_link(args) do
    Supervisor.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(_) do
    # 🚀 Fetch the source of truth from your config file
    num_shards = Queue.Config.num_shards()

    # 1️⃣ Registry for all shards
    registry = %{
      id: Queue.FDPoolRegistry,
      start: {Registry, :start_link, [[keys: :unique, name: Queue.FDPoolRegistry]]},
      type: :worker,
      restart: :permanent
    }

    # 2️⃣ All shard workers (dynamically generated based on config)
    shard_workers =
      for shard <- 0..(num_shards - 1) do
        %{
          id: {:fd_pool, shard},
          start: {Queue.FDPoolShard, :start_link, [shard]},
          type: :worker,
          restart: :permanent
        }
      end

    children = [registry | shard_workers]

    # Use :one_for_one so a crash in one pool doesn't take down the others
    Supervisor.init(children, strategy: :one_for_one)
  end
end
