defmodule Queue.Replicator do
  @moduledoc """
  Gateway for the three pillars of BimipLog replication.
  """

  # 1. THE STREAM (High frequency)
  def push_flush(shard, base, bin_io, idx_io) do
    # V2: Append bytes to the remote log/idx
    :ok
  end

  # 2. THE MAP (Medium frequency)
  def push_manifest(shard, manifest_map) do
    # V2: Update the remote .manifest file
    :ok
  end

  # 3. THE BRAIN (Medium frequency)
  def push_snapshot(shard, bin_data) do
    # V2: Overwrite the remote .bin file
    :ok
  end
end
