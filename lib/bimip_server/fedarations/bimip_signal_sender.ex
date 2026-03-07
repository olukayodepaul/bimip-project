defmodule BimipsSignal.Sender do
  @moduledoc "API for sending messages to the federation."

  # 1. MAKE SURE THE ALIAS MATCHES THE GENERATED CODE EXACTLY
  # If you copied the file, check the first line of the .pb.ex file
  # to see the real module name (e.g., BimipServer.TunnelMessage)
  alias BimipServer.TunnelMessage

  require Logger

  # 2. DEFINE THE ATTRIBUTE HERE (Before functions)
  @node_id 103
  @server_id 1

  def register(stream) do
    # Now @node_id is valid
    msg = %TunnelMessage{node_id: @node_id, state: :CONNECT}
    new_stream = GRPC.Stub.send_request(stream, msg)
    Logger.info("SENDER: Register request sent.")
    new_stream
  end

  def send_to_server(stream, payload) do
    msg = %TunnelMessage{
      node_id: @node_id,
      target_node_id: @server_id,
      state: :COMMUNICATION,
      action_type: :FORWARD,
      payload: payload
    }
    GRPC.Stub.send_request(stream, msg)
  end
end
