defmodule BimipsSignal.Connection do
  @moduledoc "Manages the gRPC stream and initial handshake."
  alias BimipServer.BimipService.Stub
  alias BimipServer.TunnelMessage
  require Logger

  # Using your specific test port
  @server_address "127.0.0.1:50052"
  @my_node_id 103

  def connect do
    Logger.info("CONN: Opening channel to #{@server_address}...")
    {:ok, channel} = GRPC.Stub.connect(@server_address)

    # 1. Start the bidirectional stream
    stream = Stub.bimip_tunnel(channel)
    Logger.info("CONN: Stream established. Sending Handshake...")

    # 2. SEND THE CONNECTION MESSAGE (Handshake)
    # Using the values from your JSON example
    handshake = %TunnelMessage{
      id: "conn_#{:os.system_time(:millisecond)}",
      node_id: @my_node_id,
      target_node_id: 1,      # Targeting the Server
      state: 1,        # Or 1 based on your proto
      direction: :CLIENT_TO_SERVER,
      timestamp: DateTime.utc_now() |> DateTime.to_unix()
    }

    GRPC.Stub.send_request(stream, handshake)
    Logger.info("CONN: Handshake sent for Node #{@my_node_id}")

    stream
  end
end
