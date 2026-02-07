defmodule QueueLogTest do
  @user_count 64
  @total_messages 1_000_000 # Total per user process
  @num_shards 64

  def run_test do
    user_list = for i <- 1..@user_count, do: "user#{i}@domain.com"

    IO.puts("🚀 Starting HIGH-SPEED Stress Test...")
    IO.puts("Target: #{@user_count * @total_messages} total messages across #{@num_shards} shards.")

    start_time = System.monotonic_time(:millisecond)

    # We spawn workers manually and use message passing to collect results
    # to avoid the overhead of Task.async_stream's internal management logic.
    parent = self()

    user_list
    |> Enum.each(fn user ->
      spawn_link(fn ->
        t1 = System.monotonic_time(:millisecond)
        write_loop_for_user(user, user_list)
        t2 = System.monotonic_time(:millisecond)

        # Send the duration back to parent
        send(parent, {:done, user, t2 - t1})
      end)
    end)

    # Collect results
    results = wait_for_results(@user_count, [])

    end_time = System.monotonic_time(:millisecond)
    total_secs = (end_time - start_time) / 1000
    total_msgs = @user_count * @total_messages

    IO.puts("\n" <> String.duplicate("-", 40))
    IO.puts("🏁 TEST FINISHED")
    IO.puts("Total Time: #{Float.round(total_secs, 2)} seconds")
    IO.puts("Throughput: #{Float.round(total_msgs / total_secs, 2)} msg/sec")
    IO.puts(String.duplicate("-", 40))

    # Summary
    {min_t, max_t} = results |> Enum.map(&elem(&1, 1)) |> Enum.min_max()
    IO.puts("Fastest User: #{min_t}ms")
    IO.puts("Slowest User: #{max_t}ms")
  end

defp write_loop_for_user(user, all_users) do
    device = "device_#{user}"
    recipients = Enum.take_random(all_users, 10)

    for i <- 1..@total_messages do
      unique_id = "m_#{user}_#{i}"
      recipient_eid = Enum.at(recipients, rem(i, 10))
      ts = System.system_time(:second)

      # 🚀 THE FIX: Create the struct that Queue.Persist.build expects
      msg = %Chat.MessageStruct{
        peer_uid: unique_id,
        timestamp: System.system_time(:millisecond),
        payload: "Message ##{i}",
        payload_context: 1,
        device_id: device,
        eid: user,
        from: %Chat.EntityStruct{eid: user, connection_resource_id: device},
        to: %Chat.EntityStruct{eid: recipient_eid, connection_resource_id: nil}
      }

      # Pass the 'msg' struct instead of the string "msg_data"
      Queue.QueueLogImpl.write(1, user, recipient_eid, device, 1, 1, msg, unique_id, ts)

      if rem(i, 500_000) == 0 do
        IO.puts("[#{user}] Sent #{div(i, 1000)}k...")
      end
    end
  end

  defp wait_for_results(0, acc), do: acc
  defp wait_for_results(count, acc) do
    receive do
      {:done, user, duration} ->
        wait_for_results(count - 1, [{user, duration} | acc])
    after
      600_000 -> # 10 minute timeout
        IO.puts("❌ Timeout waiting for workers!")
        acc
    end
  end
end
# QueueLogTest.run_test()
# # 09:09


# shard_to_check = 37
# table_name = :"bimip_buf_#{shard_to_check}"
# :ets.tab2list(table_name)

# shard_to_check = 37
# table_name = :"bimip_user_offsets_#{shard_to_check}"
# :ets.tab2list(table_name)


# # ps aux | grep beam
# # top -l 1 -s 0 | grep PhysMem








# defmodule QueueLogTest do
#   # Now explicitly defined
#   @test_users ["user57@domain.com", "user1@domain.com", "user1_alias@domain.com"]
#   @total_messages 200
#   @num_shards 64

#   def start_timer do
#     if Process.whereis(__MODULE__.Timer), do: Process.unregister(__MODULE__.Timer)
#     {:ok, agent} = Agent.start_link(fn -> %{} end, name: __MODULE__.Timer)
#     agent
#   end

#   def run_test do
#     IO.puts("Starting TARGETED test for: #{inspect(@test_users)}")

#     start_timer()
#     start_time = System.monotonic_time(:millisecond)

#     # We spawn exactly 3 tasks
#     @test_users
#     |> Task.async_stream(
#       fn user ->
#         write_loop_for_user(user, @test_users)
#       end,
#       max_concurrency: 3, # Limited to your 3 specific workers
#       timeout: :infinity
#     )
#     |> Stream.run()

#     end_time = System.monotonic_time(:millisecond)
#     IO.puts("\nTest finished in #{div(end_time - start_time, 1000)} seconds.")

#     # Show results
#     IO.puts("\nPer-shard processing times (ms):")
#     Agent.get(__MODULE__.Timer, & &1)
#     |> Enum.sort()
#     |> Enum.each(fn {shard, time} -> IO.puts("Shard #{shard}: #{time} ms") end)
#   end

#   defp write_loop_for_user(user, all_users) do
#     # Note: 2,000,000 messages * 3 users = 6 million total writes.
#     Enum.each(1..@total_messages, fn i ->
#       if rem(i, 10_000) == 0, do: IO.puts("[#{user}] Progress: #{i} messages...")

#       unique_id = :crypto.strong_rand_bytes(16) |> Base.encode64()
#       # Pick someone else to talk to
#       recipient = Enum.random(all_users)

#       ts = System.system_time(:second)
#       seq = System.unique_integer([:monotonic, :positive])

#       # Using your existing Struct
#       msg = %Chat.MessageStruct{
#         peer_uid: unique_id,
#         timestamp: System.system_time(:millisecond),
#         payload: "Message ##{i} from #{user}",
#         payload_context: 1,
#         device_id: "device_#{user}",
#         eid: user,
#         from: %Chat.EntityStruct{eid: user, connection_resource_id: "device_#{user}"},
#         to: %Chat.EntityStruct{eid: recipient, connection_resource_id: nil}
#       }

#       shard = rem(seq, @num_shards)
#       shard_start = System.monotonic_time(:millisecond)

#       # YOUR SYSTEM CALL
#       Queue.QueueLogImpl.write(1, user, recipient, "device_#{user}", 1, 1, msg, unique_id, ts)

#       shard_end = System.monotonic_time(:millisecond)

#       Agent.update(__MODULE__.Timer, fn map ->
#         Map.update(map, shard, shard_end - shard_start, &(&1 + (shard_end - shard_start)))
#       end)
#     end)
#   end
# end

# # QueueLogTest.run_test()
