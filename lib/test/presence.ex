# defmodule QueueLogTest do
#   @user_count 64
#   @total_messages 2_000_000
#   @num_shards 64

#   # Shared Agent to track per-shard timing
#   def start_timer do
#     {:ok, agent} = Agent.start_link(fn -> %{} end, name: __MODULE__.Timer)
#     agent
#   end

#   def run_test do
#     user_list = for i <- 1..@user_count, do: "user#{i}@domain.com"

#     IO.puts("Starting HIGH-CONCURRENCY test...")
#     IO.puts("Spawning #{@user_count} independent worker processes...")

#     start_timer()
#     start_time = System.monotonic_time(:millisecond)

#     user_list
#     |> Task.async_stream(
#       fn user ->
#         write_loop_for_user(user, user_list)
#       end,
#       max_concurrency: @user_count,
#       timeout: :infinity
#     )
#     |> Stream.run()

#     end_time = System.monotonic_time(:millisecond)
#     IO.puts("\nAll user processes finished in #{div(end_time - start_time, 1000)} seconds.")

#     # Print per-shard timing
#     IO.puts("\nPer-shard processing times (ms):")
#     Agent.get(__MODULE__.Timer, & &1)
#     |> Enum.sort_by(fn {shard, _} -> shard end)
#     |> Enum.each(fn {shard, time} -> IO.puts("Shard #{shard}: #{time} ms") end)
#   end

#   defp write_loop_for_user(user, all_users) do
#     Enum.each(1..@total_messages, fn i ->
#       if rem(i, 10_000) == 0, do: IO.puts("[#{user}] Sent #{i} messages...")

#       unique_id = :crypto.strong_rand_bytes(16) |> Base.encode64()
#       recipient = Enum.random(all_users -- [user])

#       ts = System.system_time(:second)
#       seq = System.unique_integer([:monotonic, :positive])

#       msg = %Chat.MessageStruct{
#         peer_uid: unique_id,
#         timestamp: System.system_time(:millisecond),
#         payload: "Message ##{i} for #{user}",
#         payload_context: 1,
#         encryption_type: "E2E",
#         encrypted: "DATA_#{i}",
#         signature: "SIG_#{i}",
#         device_id: "device_#{user}",
#         uupid: "1",
#         eid: user,
#         from: %Chat.EntityStruct{eid: user, connection_resource_id: "device_#{user}"},
#         to: %Chat.EntityStruct{eid: recipient, connection_resource_id: nil}
#       }

#       # --- NEW SHARD ASSIGNMENT: round-robin across shards ---
#       shard = rem(seq, @num_shards)
#       shard_start = System.monotonic_time(:millisecond)

#       Queue.QueueLogImpl.write(1, user, recipient, "device_#{user}", 1, 1, msg, unique_id, ts)

#       shard_end = System.monotonic_time(:millisecond)

#       # Accumulate time per shard
#       Agent.update(__MODULE__.Timer, fn map ->
#         Map.update(map, shard, shard_end - shard_start, &(&1 + shard_end - shard_start))
#       end)
#     end)
#   end
# end


# # 09:09


# shard_to_check = 37
# table_name = :"bimip_buf_#{shard_to_check}"
# :ets.tab2list(table_name)

# shard_to_check = 37
# table_name = :"bimip_user_offsets_#{shard_to_check}"
# :ets.tab2list(table_name)


# # ps aux | grep beam
# # top -l 1 -s 0 | grep PhysMem








defmodule QueueLogTest do
  # Now explicitly defined
  @test_users ["user57@domain.com", "user1@domain.com", "user1_alias@domain.com"]
  @total_messages 200
  @num_shards 64

  def start_timer do
    if Process.whereis(__MODULE__.Timer), do: Process.unregister(__MODULE__.Timer)
    {:ok, agent} = Agent.start_link(fn -> %{} end, name: __MODULE__.Timer)
    agent
  end

  def run_test do
    IO.puts("Starting TARGETED test for: #{inspect(@test_users)}")

    start_timer()
    start_time = System.monotonic_time(:millisecond)

    # We spawn exactly 3 tasks
    @test_users
    |> Task.async_stream(
      fn user ->
        write_loop_for_user(user, @test_users)
      end,
      max_concurrency: 3, # Limited to your 3 specific workers
      timeout: :infinity
    )
    |> Stream.run()

    end_time = System.monotonic_time(:millisecond)
    IO.puts("\nTest finished in #{div(end_time - start_time, 1000)} seconds.")

    # Show results
    IO.puts("\nPer-shard processing times (ms):")
    Agent.get(__MODULE__.Timer, & &1)
    |> Enum.sort()
    |> Enum.each(fn {shard, time} -> IO.puts("Shard #{shard}: #{time} ms") end)
  end

  defp write_loop_for_user(user, all_users) do
    # Note: 2,000,000 messages * 3 users = 6 million total writes.
    Enum.each(1..@total_messages, fn i ->
      if rem(i, 10_000) == 0, do: IO.puts("[#{user}] Progress: #{i} messages...")

      unique_id = :crypto.strong_rand_bytes(16) |> Base.encode64()
      # Pick someone else to talk to
      recipient = Enum.random(all_users)

      ts = System.system_time(:second)
      seq = System.unique_integer([:monotonic, :positive])

      # Using your existing Struct
      msg = %Chat.MessageStruct{
        peer_uid: unique_id,
        timestamp: System.system_time(:millisecond),
        payload: "Message ##{i} from #{user}",
        payload_context: 1,
        device_id: "device_#{user}",
        eid: user,
        from: %Chat.EntityStruct{eid: user, connection_resource_id: "device_#{user}"},
        to: %Chat.EntityStruct{eid: recipient, connection_resource_id: nil}
      }

      shard = rem(seq, @num_shards)
      shard_start = System.monotonic_time(:millisecond)

      # YOUR SYSTEM CALL
      Queue.QueueLogImpl.write(1, user, recipient, "device_#{user}", 1, 1, msg, unique_id, ts)

      shard_end = System.monotonic_time(:millisecond)

      Agent.update(__MODULE__.Timer, fn map ->
        Map.update(map, shard, shard_end - shard_start, &(&1 + (shard_end - shard_start)))
      end)
    end)
  end
end

# # QueueLogTest.run_test()
