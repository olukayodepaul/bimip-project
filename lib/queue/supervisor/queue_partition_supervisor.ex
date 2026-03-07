defmodule Queue.ShardGroup do
  @moduledoc """
  This module acts as a sub-supervisor for each shard.
  By grouping the Sequencer, Log, and Sweeper, we ensure they are
  managed together on the same core/scheduler.
  """
  use Supervisor

  def start_link(shard_id) do
    Supervisor.start_link(__MODULE__, shard_id)
  end

  @impl true
  def init(shard_id) do
    # These IDs maintain your current naming logic so existing calls don't break
    children = [
      Supervisor.child_spec({Queue.ShardServer, shard_id}, id: :"shard_sequencer_#{shard_id}"),
      Supervisor.child_spec({Queue.QueueLogImpl, shard_id}, id: :"shard_#{shard_id}", shutdown: 30_000),
      Supervisor.child_spec({Queue.MessageTracker.Sweeper, shard_id}, id: :"sweeper_#{shard_id}")
    ]

    # :one_for_all is used because if the ShardServer or Log crashes,
    # the Sweeper for that specific shard should also reset.
    Supervisor.init(children, strategy: :one_for_all)
  end
end
