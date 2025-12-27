defmodule Queue.MessageTracker.Benchmark do
  @moduledoc """
  Concurrent benchmark for Queue.MessageTracker.
  Inserts N records and checks partition sizes.
  """

  alias Queue.MessageTracker

  @total_count 1_000_000

  def run do
    IO.puts("Initializing MessageTracker...")
    MessageTracker.init()

    IO.puts("Generating #{@total_count} messages...")
    messages =
      for i <- 1..@total_count do
        {"user-#{div(i, 10)}", "msg-#{i}"}
      end

    IO.puts("Starting concurrent insert benchmark...")
    start = System.monotonic_time(:microsecond)

    results =
      messages
      |> Task.async_stream(
        fn {user, msg} ->
          MessageTracker.check_and_insert(user, msg)
        end,
        max_concurrency: System.schedulers_online() * 2,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.to_list()

    stop = System.monotonic_time(:microsecond)
    duration_us = stop - start
    duration_ms = duration_us / 1_000
    ops_per_sec = @total_count / (duration_us / 1_000_000)

    success = Enum.count(results, fn {:ok, {:ok, :inserted}} -> true; _ -> false end)
    exists  = Enum.count(results, fn {:ok, {:error, :already_exists}} -> true; _ -> false end)

    IO.puts("""
    ===== MessageTracker Benchmark =====
    Inserts attempted: #{@total_count}
    Successful inserts: #{success}
    Already exists: #{exists}

    Time taken: #{Float.round(duration_ms, 2)} ms
    Throughput: #{Float.round(ops_per_sec, 2)} ops/sec
    ===================================
    """)

    IO.puts("Checking partition sizes...")
    for idx <- 0..(MessageTracker.partitions() - 1) do
      table0 = elem(MessageTracker.gen_0_names(), idx)
      table1 = elem(MessageTracker.gen_1_names(), idx)
      IO.puts("Partition #{idx}: gen0 size=#{:ets.info(table0, :size)}, gen1 size=#{:ets.info(table1, :size)}")
    end

    :ok
  end
end
