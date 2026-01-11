defmodule Queue.Config do
  @doc "Returns the configured number of shards, defaulting to 16."
  def num_shards do
    Application.get_env(:bimip, :num_shards, 16)
  end
end
