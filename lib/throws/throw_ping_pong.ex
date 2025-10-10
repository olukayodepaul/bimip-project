defmodule ThrowPingPongSchema do
  @moduledoc """
  Builds PingPong stanzas for both success and error.
  """

  # Same-session ping response (server <-> client)
  def same(to_eid, to_device_id, ping_time) do
    build(to_eid, to_device_id, to_eid, to_device_id, 1, 2, ping_time)
  end

  # Cross-user ping response
  def others(from_eid, from_device_id, to_eid, to_device_id, ping_time) do
    build(from_eid, from_device_id, to_eid, to_device_id, 2, 2, ping_time)
  end

  # Inline error response
  def error(eid, device_id, description) do
    ping_pong = %Bimip.PingPong{
      from: %Bimip.Identity{eid: eid, connection_resource_id: device_id},
      to: %Bimip.Identity{eid: eid, connection_resource_id: device_id},
      resource: 1,
      type: 3, # ERROR
      ping_time: System.system_time(:millisecond),
      pong_time: 0,
      details: description
    }

    %Bimip.MessageScheme{
      route: 3,
      payload: {:ping_pong, ping_pong}
    }
    |> Bimip.MessageScheme.encode()
  end

  # Internal stanza builder
  defp build(from_eid, from_device_id, to_eid, to_device_id, resource, type, ping_time) do
    ping_pong = %Bimip.PingPong{
      from: %Bimip.Identity{eid: from_eid, connection_resource_id: from_device_id},
      to: %Bimip.Identity{eid: to_eid, connection_resource_id: to_device_id},
      resource: resource,
      type: type,
      ping_time: ping_time,
      pong_time: System.system_time(:millisecond)
    }

    %Bimip.MessageScheme{
      route: 3,
      payload: {:ping_pong, ping_pong}
    }
    |> Bimip.MessageScheme.encode()
  end
end
