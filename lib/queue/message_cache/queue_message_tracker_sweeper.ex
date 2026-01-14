defmodule Queue.MessageTracker.Sweeper do
  use GenServer
  require Logger

  @sweep_interval :timer.hours(1)
  @rotate_interval :timer.hours(5)

  def start_link(shard) do
    name = :"message_tracker_sweeper_#{shard}"
    GenServer.start_link(__MODULE__, shard, name: name)
  end

  @impl true
  def init(shard) do
    # Stagger starts so 64 shards don't hit the CPU at the exact same millisecond
    jitter = shard * 2000

    Process.send_after(self(), :sweep, @sweep_interval + jitter)
    Process.send_after(self(), :rotate, @rotate_interval + jitter)

    {:ok, %{shard: shard}}
  end

  @impl true
  def handle_info(:sweep, %{shard: shard} = state) do
    Queue.MessageTracker.sweep(shard)
    Process.send_after(self(), :sweep, @sweep_interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(:rotate, %{shard: shard} = state) do
    Queue.MessageTracker.rotate(shard)
    Process.send_after(self(), :rotate, @rotate_interval)
    {:noreply, state}
  end
end
