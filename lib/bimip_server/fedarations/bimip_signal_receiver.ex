defmodule BimipsSignal.Receiver do
  use GenServer
  alias BimipServer.TunnelMessage
  require Logger

  def start_link(stream) do
    GenServer.start_link(__MODULE__, stream, name: __MODULE__)
  end

  defp listen(stream) do
    # You MUST use the {status, message, updated_stream} format
    case GRPC.Stub.recv(stream, timeout: :infinity) do
      {:ok, msg, new_stream} ->
        # 1. Handle the message
        handle_message(msg)

        # 2. IMPORTANT: You MUST recurse with 'new_stream'
        # If you use the old 'stream', the next call will hang forever
        listen(new_stream)

      {:error, %GRPC.RPCError{status: 4}, new_stream} ->
        # Even on timeouts, the stream state might have evolved
        listen(new_stream)

      {:error, reason, _} ->
        Logger.error("RECEIVER_FATAL: #{inspect(reason)}")
    end
  end

  defp handle_message(msg) do
    # Use IO.inspect to bypass any Logger level issues
    IO.puts ">>> CLIENT_RECEIVED_DATA!"
    IO.inspect(msg, label: "Incoming Message Struct")
  end
end
