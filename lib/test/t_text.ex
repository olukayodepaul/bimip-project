defmodule Queue.Benchmark do
  # 🚀 TUNED PARAMETERS
  @total_messages 5_000_000
  @concurrency 12          # Matches physical cores to reduce context switching
  @batch_size 5_000        # Larger pallets = more efficient ETS bursts

  def run do
    # Pull dynamic shard count for verification
    num_shards = 64

    IO.puts "🚀 Starting HIGH-PRESSURE TEST: #{@total_messages} Records..."
    IO.puts "📦 Batch Size: #{@batch_size} | Workers: #{@concurrency} | Shards: #{num_shards}"
    IO.puts "---------------------------------------------------"

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
    IO.puts "🏁 HIGH-PRESSURE TEST COMPLETE"
    IO.puts "⏱  Total Time: #{Float.round(duration_sec, 2)} seconds"
    IO.puts "🚀 Average Throughput: #{Float.round(@total_messages / duration_sec, 2)} msg/sec"
    IO.puts "---------------------------------------------------"
  end

  defp perform_batched_work(w_id, total_count) do
    num_batches = div(total_count, @batch_size)

    # 🔥 PRE-OPTIMIZATION: Static strings used to avoid repeated interpolation
    domain = "@domain.com"
    device = "bench_worker_#{w_id}"

    Enum.each(1..num_batches, fn b_id ->
      # 1. Prepare Pallet (Simplified to reduce CPU overhead)
      batch = Enum.map(1..@batch_size, fn i ->
        global_id = (w_id * total_count) + (b_id * @batch_size) + i

        # Reuse strings to keep GC pressure low
        u_id = rem(global_id, 500)
        r_id = rem(global_id, 100_000)

        user = "u#{u_id}#{domain}"
        recipient = "r#{r_id}#{domain}"

        # Build the message
        msg = %Chat.MessageStruct{
          peer_uid: "m#{global_id}",
          timestamp: System.system_time(:millisecond),
          payload: "data", # Short payload to test IO overhead specifically
          eid: user
        }

        {user, recipient, msg}
      end)

      # 2. Blast to storage
      send_to_shards(batch, device)

      # Visual feedback (less frequent to save console IO time)
      if rem(b_id, 50) == 0, do: IO.write(".")
    end)
  end

  defp send_to_shards(batch, device) do
    Enum.each(batch, fn {user, recipient, msg} ->
      execute_write(user, recipient, device, msg)
    end)
  end

  defp execute_write(user, recipient, device, msg) do
    # Hit the storage engine
    case Queue.QueueLogImpl.write(1, user, recipient, device, 1, 1, msg, msg.peer_uid) do
      {:ok, _} -> :ok
      {:error, :backpressure} ->
        # If storage is full, back off slightly then retry
        Process.sleep(1)
        execute_write(user, recipient, device, msg)
    end
  end
end

# r(Queue.Benchmark)
# Queue.Benchmark.run()
