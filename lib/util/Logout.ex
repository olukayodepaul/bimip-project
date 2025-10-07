defmodule LogouResponseSchema do

  def logout(eid, device_id, type \\ 2,  status \\ 3) do

    logout = %Bimip.Logout{
      to: %Bimip.Identity{
        eid: eid,
        connection_resource_id: device_id
      },
      type: 2,
      status: 3,
      timestamp: System.system_time(:millisecond)
    }

    response = %Bimip.MessageScheme{
      route: 10,
      payload: {:logout, logout}
    }

    Bimip.MessageScheme.encode(response)

  end
end
