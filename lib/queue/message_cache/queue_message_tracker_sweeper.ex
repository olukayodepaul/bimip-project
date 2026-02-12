defmodule Queue.MessageTracker.Sweeper do
  use GenServer
  require Logger

  @sweep_interval :timer.minutes(2)
  @rotate_interval :timer.minutes(5)

  def start_link(shard) when is_integer(shard) do
    name = :"message_tracker_sweeper_#{shard}"
    GenServer.start_link(__MODULE__, shard, name: name)
  end

  @impl true
  def init(shard) do
    # Jitter: Stagger starts over 128 seconds (64 shards * 2s) to flatten CPU spikes
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
