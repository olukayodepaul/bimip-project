defmodule BimipQueueTest do
  alias BimipQueue

  @users ["user_1", "user_2", "user_3"]
  @devices ["d1", "d2", "d3"]
  @partition "partition_a"

  def run_test do
    IO.puts("=== WRITING MESSAGES ===")

    # Step 1: Write messages for all users/devices
    Enum.each(@users, fn user ->
      Enum.each(@devices, fn device ->
        1..2
        |> Enum.each(fn i ->
          payload = "Message #{i} from #{device} of #{user}"
          {:ok, offset} = BimipQueue.write(user, @partition, device, user, payload)
          IO.puts("[WRITE] #{device} → #{user}: offset #{offset}, payload=#{payload}")
        end)
      end)
    end)

    IO.puts("\n=== FETCH PHASE ===")

    # Step 2: Fetch concurrently for all devices
    Enum.each(@users, fn user ->
      Enum.each(@devices, fn device ->
        {:ok, messages, last_offset} = BimipQueue.fetch(user, device, @partition, user, 10)
        IO.puts("[FETCH] #{device} fetched #{length(messages)} messages for #{user}, last_offset=#{last_offset}")
        Enum.with_index(messages, 1)
        |> Enum.each(fn {msg, idx} -> IO.puts("   #{idx}: #{msg.payload}") end)

        # Update device offset after fetch
        BimipQueue.update_device_offset(user, device, last_offset)
      end)
    end)

    IO.puts("\n=== ACK PHASE ===")

    # Step 3: Acknowledge the first message for each device
    Enum.each(@users, fn user ->
      Enum.each(@devices, fn device ->
        BimipQueue.ack(user, @partition, device, user, 1)
        IO.puts("[ACK] #{device} acknowledged offset 1 for #{user}")
      end)
    end)

    IO.puts("\n=== INDEXES ===")
    Enum.each(@users, fn user ->
      indexes = BimipQueue.list_indexes(user)
      IO.puts("Indexes for #{user}: #{inspect(indexes)}")
    end)

    :ok
  end
end


# BimipQueueTest.run_test()