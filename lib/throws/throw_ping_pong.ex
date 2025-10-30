defmodule ThrowPingPongSchema do
  @moduledoc """
  Builds PingPong stanzas for both success and error, matching the new schema:

  message PingPong {
      string id = 1;                 // Unique message or request ID
      Identity from = 2;               // Target identity
      int32 type = 3;                // 1 = PING, 2 = PONG, 3 = ERROR
      int64 timestamp = 4;           // Unix UTC timestamp in milliseconds
      string details = 5;            // Optional: used only when type = 3 (ERROR)
  }
  """

  alias Bimip.{PingPong, Identity, MessageScheme}

  def success(from_eid, from_device_id, id, type) do
    ping_pong = %PingPong{
      id: id,
      from: %Identity{eid: from_eid, connection_resource_id: from_device_id},
      type: type, # 1 = PING, 2 = PONG
      timestamp: System.system_time(:millisecond),
      details: ""
    }

    %MessageScheme{
      route: 3,
      payload: {:ping_pong, ping_pong}
    }
    |> MessageScheme.encode()
  end


  # Inline error response
  def error(from_eid, from_device_id, id, description) do
    ping_pong = %PingPong{
      id: id,
      from: %Identity{eid: from_eid, connection_resource_id: from_device_id},
      type: 3, # ERROR
      timestamp: System.system_time(:millisecond),
      details: description
    }

    %MessageScheme{
      route: 3,
      payload: {:ping_pong, ping_pong}
    }
    |> MessageScheme.encode()
  end


end
