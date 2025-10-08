defmodule ThrowPingPongSchema do
  @moduledoc """
  Builds PingPong messages:
    - same/4: Server ↔ Client (resource = 1)
    - others/6: User ↔ User (resource = 2)
  """

  # 🔹 SAME (server ↔ client)
  def same(to_eid, to_device_id, ping_time) do
    ping_pong = %Bimip.PingPong{
      to: %Bimip.Identity{
        eid: to_eid,
        connection_resource_id: to_device_id
      },
      from: %Bimip.Identity{
        eid: to_eid,
        connection_resource_id: to_device_id
      },
      resource: 1, # SAME
      type: 2,  # 1=PING, 2=PONG
      ping_time: ping_time,
      pong_time: System.system_time(:millisecond)
    }

    %Bimip.MessageScheme{
      route: 3,
      payload: {:ping_pong, ping_pong}
    }
    |> Bimip.MessageScheme.encode()
  end


  def others(from_eid, from_device_id, to_eid, to_device_id, ping_time) do
    ping_pong = %Bimip.PingPong{
      from: %Bimip.Identity{
        eid: from_eid,
        connection_resource_id: from_device_id
      },
      to: %Bimip.Identity{
        eid: to_eid,
        connection_resource_id: to_device_id
      },
      resource: 2, # OTHERS
      type: 2,  # 1=PING, 2=PONG
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
