defmodule BimipsSignal.SignalManager do
  use GenServer
  alias BimipServer.TunnelMessage
  require Logger

  # Client API
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  # Server Callbacks
  def init(_) do
    # 1. Connect and Handshake
    initial_stream = BimipsSignal.Connection.connect()
    # Note: Sender.register must return the updated stream
    stream = BimipsSignal.Sender.register(initial_stream)

    Logger.info("SIGNAL_MANAGER: Connected and Registered.")

    # 2. Start the heartbeat loop
    schedule_heartbeat()

    # 3. Start the listening loop
    send(self(), :listen)

    {:ok, stream}
  end

def handle_info(:listen, stream) do
  # We use a short timeout (e.g., 5 seconds) to keep the GenServer loop responsive
  case GRPC.Stub.recv(stream, timeout: 5_000) do
    {:ok, enum} ->
      # Your stream-processing logic here...
      Task.start(fn ->
        enum |> Stream.each(fn {:ok, msg} -> Logger.info("INCOMING: #{inspect(msg)}") end) |> Stream.run()
      end)
      {:noreply, stream}

    # --- THE CRITICAL FIX START ---
    {:error, %GRPC.RPCError{status: 4}} ->
      # This is just a "no data yet" message.
      # DO NOT STOP. Just tell yourself to listen again.
      send(self(), :listen)
      {:noreply, stream}
    # --- THE CRITICAL FIX END ---

    {:error, reason} ->
      # This handles status 13 (Internal), 14 (Unavailable), etc.
      Logger.error("SIGNAL_FATAL: #{inspect(reason)}")
      {:stop, :connection_lost, stream}
  end
end

  def handle_info(:send_heartbeat, stream) do
    # 5. Send using the SAME stream variable
    # Ensure send_to_server returns the updated stream
    new_stream = BimipsSignal.Sender.send_to_server(stream, "Heartbeat data...")

    schedule_heartbeat()
    {:noreply, new_stream}
  end

  defp schedule_heartbeat, do: Process.send_after(self(), :send_heartbeat, 10_000)
end
