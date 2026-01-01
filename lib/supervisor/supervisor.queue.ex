defmodule Queue.BimipSupervisor do
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    # Global setup for ETS and Directory
    Queue.QueueLogImpl.__startup__()

    # Create 64 Worker children
    shard_workers = for s <- 0..63 do
      Supervisor.child_spec({Queue.QueueLogImpl, s}, id: :"shard_#{s}")
    end

    # Compactor child
    children = shard_workers ++ [Queue.BimipCompactor]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
