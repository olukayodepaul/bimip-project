defmodule Tracker50MTest do
  def run do
    count = 50_000_000
    IO.puts("--- STARTING 50 MILLION RECORD TEST ---")
    Queue.MessageTracker.init()

    {time_micros, _} = :timer.tc(fn ->
      # Chunking prevents the generator from eating all RAM before the test even starts
      1..count
      |> Stream.chunk_every(100_000)
      |> Enum.each(fn chunk ->
        Enum.each(chunk, fn i ->
          Queue.MessageTracker.check_and_insert("u_#{i}", "m_#{i}")
        end)
        IO.write(".") # Progress indicator
      end)
    end)

    seconds = time_micros / 1_000_000
    IO.puts("\n--- 50M RESULTS ---")
    IO.puts("Total Time: #{Float.round(seconds, 2)}s")
    IO.puts("Throughput: #{Float.round(count / seconds, 2)} ops/sec")

    # Check Memory
    ets_mem = :erlang.memory(:ets) / 1024 / 1024
    IO.puts("ETS RAM Usage: #{Float.round(ets_mem, 2)} MB")
  end
end
