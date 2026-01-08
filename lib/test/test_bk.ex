defmodule Queue.DebugUtils do
  @moduledoc """
  Helper tools for inspecting the internal state of the Bimip system.
  """

  @base_path "data/device_bookmarks"

  @doc """
  Reads and prints the persistent bookmark data for a specific shard.
  Usage: Queue.DebugUtils.inspect_bookmarks(18)
  """
  def inspect_bookmarks(shard_id) do
    path = Path.join(@base_path, "shard_#{shard_id}.bin")

    case File.read(path) do
      {:ok, bin} ->
        data = :erlang.binary_to_term(bin)
        IO.inspect(data, label: "🔍 Bookmarks for Shard #{shard_id}")
        :ok

      {:error, :enoent} ->
        IO.puts("❌ Error: No bookmark file found for Shard #{shard_id} at #{path}")
        {:error, :not_found}

      {:error, reason} ->
        IO.puts("❌ Error reading file: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Helper to see how many users are in the RAM cache vs Disk for a shard.
  """
  def check_ram_cache(shard_id) do
    cache = :"device_bookmarks_cache_#{shard_id}"
    case :ets.info(cache) do
      :undefined -> "Cache not initialized"
      info ->
        size = Keyword.get(info, :size)
        IO.puts("⚡ RAM Cache for Shard #{shard_id} contains #{size} users.")
    end
  end
end

#Queue.DebugUtils.inspect_bookmarks(18)
