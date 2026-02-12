defmodule Queue.Benchmark do
  @moduledoc """
  High-speed stress test for Queue.QueueLogImpl using batch writes.
  """

  @total_messages 1_000_000
  @batch_size 1_000
  @num_shards 64
  @users 500
  @partitions 10

  def run do
    IO.puts("🚀 Starting HYPER-BATCH TEST: #{@total_messages} messages...")

    start_time = System.monotonic_time(:millisecond)

    # Pre-generate all messages
    batches =
      1..@total_messages
      |> Enum.chunk_every(@batch_size)
      |> Enum.map(fn chunk ->
        Enum.map(chunk, &prepare_message/1)
      end)

    # Send batches concurrently
    batches
    |> Task.async_stream(
      fn batch -> send_batch(batch) end,
      max_concurrency: 64,
      timeout: :infinity,
      ordered: false
    )
    |> Stream.run()

    duration_ms = System.monotonic_time(:millisecond) - start_time
    duration_sec = duration_ms / 1000

    IO.puts "\n---------------------------------------------------"
    IO.puts("🏁 HYPER-BATCH TEST COMPLETE")
    IO.puts("⏱ Total Time: #{Float.round(duration_sec, 2)} seconds")
    IO.puts("🚀 Average Throughput: #{Float.round(@total_messages / duration_sec, 2)} msg/sec")
    IO.puts("📦 Total Records: #{@total_messages}")
    IO.puts("---------------------------------------------------")
  end

  defp prepare_message(i) do
    user_num = rem(i, @users)
    partition_id = rem(i, @partitions)
    recipient_num = rem(i * 7, 1_000_000)
    user = "user_#{user_num}@domain.com"
    recipient = "user_#{recipient_num}@domain.com"
    unique_id = "mid_#{i}"

    {user, recipient, %Chat.MessageStruct{
      peer_uid: unique_id,
      timestamp: System.system_time(:millisecond),
      payload: "Batch message ##{i}",
      payload_context: partition_id,
      encryption_type: "E2E",
      encrypted: "DATA_#{i}",
      signature: "SIG_#{i}",
      device_id: "aaaaa1",
      uupid: partition_id,
      eid: user,
      from: %Chat.EntityStruct{eid: user, connection_resource_id: "aaaaa1"},
      to: %Chat.EntityStruct{eid: recipient, connection_resource_id: nil}
    }, partition_id}
  end

  defp send_batch(batch) do
    Enum.each(batch, fn {user, recipient, msg, partition_id} ->
      shard = :erlang.phash2(recipient, @num_shards)
      Queue.QueueLogImpl.write(partition_id, user, recipient, "aaaaa1", 1, 1, msg, msg.peer_uid, shard)
    end)
    IO.write(".")  # Progress indicator per batch
    :ok
  end
end

# r(Queue.Benchmark)
# Queue.Benchmark.run()
