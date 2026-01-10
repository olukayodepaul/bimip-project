defmodule Queue.Benchmark do
  @total_messages 30_000_000
  @concurrency 12          # 🚀 TENSION: Matches CPU cores for higher speed
  @batch_size 5_000        # 🚀 TENSION: Larger pallets to flood the ETS buffers

  def run do
    # Pull the shard count from your config to ensure it matches the 16 we set
    num_shards = 64

    IO.puts "🚀 Starting BATCH-CONCURRENT TEST: #{@total_messages} Records..."
    IO.puts "📦 Batch Size: #{@batch_size} | Workers: #{@concurrency} | Shards: #{num_shards}"

    start_time = System.monotonic_time(:millisecond)
    msgs_per_worker = div(@total_messages, @concurrency)

    1..@concurrency
    |> Task.async_stream(fn w_id ->
      perform_batched_work(w_id, msgs_per_worker)
    end, max_concurrency: @concurrency, timeout: :infinity)
    |> Stream.run()

    duration_ms = System.monotonic_time(:millisecond) - start_time
    duration_sec = duration_ms / 1000

    IO.puts "\n---------------------------------------------------"
    IO.puts "🏁 BATCH TEST COMPLETE"
    IO.puts "⏱  Total Time: #{Float.round(duration_sec, 2)} seconds"
    IO.puts "🚀 Average Throughput: #{Float.round(@total_messages / duration_sec, 2)} msg/sec"
    IO.puts "---------------------------------------------------"
  end

  defp perform_batched_work(w_id, total_count) do
    num_batches = div(total_count, @batch_size)

    Enum.each(1..num_batches, fn b_id ->
      batch = Enum.map(1..@batch_size, fn i ->
        global_i = (w_id * total_count) + (b_id * @batch_size) + i
        prepare_message(global_i)
      end)

      send_to_shards(batch)

      # Visual feedback
      if rem(b_id, 10) == 0, do: IO.write(".")
    end)
  end

  defp prepare_message(i) do
    user = "user_#{rem(i, 500)}@domain.com"
    recipient = "user_#{rem(i, 100_000)}@domain.com"
    {user, recipient, %Chat.MessageStruct{
      peer_uid: "mid_#{i}",
      timestamp: System.system_time(:millisecond),
      payload: "Batch message ##{i}",
      eid: user,
      from: %Chat.EntityStruct{eid: user},
      to: %Chat.EntityStruct{eid: recipient}
    }}
  end

  defp send_to_shards(batch) do
    Enum.each(batch, fn {user, recipient, msg} ->
      execute_write(user, recipient, msg, msg.peer_uid)
    end)
  end

  defp execute_write(user, recipient, msg, mid) do
    case Queue.QueueLogImpl.write(1, user, recipient, "aaaaa1", 1, 1, msg, mid) do
      {:ok, _offset} -> :ok
      {:error, :backpressure} ->
        :erlang.yield()
        execute_write(user, recipient, msg, mid)
    end
  end
end

# r(Queue.Benchmark)
# Queue.Benchmark.run()
