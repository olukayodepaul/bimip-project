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



# # Setup
# user_a = "a@domain.com"
# partition = 1
# device_a1 = 101   # Numeric ID for the sender
# device_a2 = 102   # Numeric ID for the syncing device

# IO.puts "🚀 Testing Multi-Device Sync for User A with numeric device IDs..."

# # 1. Device 101 writes a message to its own account
# unique_id = :crypto.strong_rand_bytes(16) |> Base.encode64()
# msg = %Chat.MessageStruct{
#   peer_uid: unique_id,
#   timestamp: System.system_time(:millisecond),
#   payload: "Sync test with numeric ID",
#   payload_context: 1,
#   device_id: device_a1,
#   eid: user_a,
#   from: %Chat.EntityStruct{eid: user_a, connection_resource_id: to_string(device_a1)},
#   to: %Chat.EntityStruct{eid: user_a}
# }

# # EXECUTE WRITE: Lands in User A's shard tagged with writer_device: "101"
# Queue.QueueLogImpl.write(partition, user_a, user_a, device_a1, 1, 1, msg, unique_id)

# IO.puts "🏁 Waiting for flush..."
# Process.sleep(200)

# # 2. TEST: Device 101 (The original sender) fetches
# # Result should be 0 because the filter matches "101" == "101"
# {:ok, res_a1} = Queue.QueueLogImpl.fetch_batch(user_a, partition, device_a1)
# IO.inspect(length(res_a1), label: "Device 101 Fetch (Sender)")

# # 3. TEST: Device 102 (The other device) fetches
# # Result should be 1 because "101" != "102"
# {:ok, res_a2} = Queue.QueueLogImpl.fetch_batch(user_a, partition, device_a2)
# IO.inspect(length(res_a2), label: "Device 102 Fetch (Sync)")
