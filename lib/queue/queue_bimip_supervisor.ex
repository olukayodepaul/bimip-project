defmodule Queue.BimipSupervisor do
  use Supervisor

  def start_link(_init_arg \\ []) do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    # Initialize ETS tables once
    Queue.QueueLogImpl.__startup__()

    shard_workers =
      for s <- 0..63 do
        Supervisor.child_spec({Queue.QueueLogImpl, s}, id: :"shard_#{s}")
      end

    children = shard_workers ++ [
      {Queue.BimipCompactor, []}  # only here
    ]


    Supervisor.init(children, strategy: :one_for_one)
  end
end
