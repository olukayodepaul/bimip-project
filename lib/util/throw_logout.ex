defmodule ThrowLogouResponseSchema do

  def logout(eid, device_id, type \\ 2,  status \\ 3) do

    logout = %Bimip.Logout{
      to: %Bimip.Identity{
        eid: eid,
        connection_resource_id: device_id
      },
      type: type,
      status: status,
      timestamp: System.system_time(:millisecond)
    }

    %Bimip.MessageScheme{
      route: 10,
      payload: {:logout, logout}
    }
    |> Bimip.MessageScheme.encode()

  end
end
