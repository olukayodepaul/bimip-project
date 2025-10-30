defmodule Route.AwarenessFanOut do

  alias Storage.DeviceStorage
  alias Settings.ServerState
  alias App.RegistryHub
  alias ThrowAwarenessVisibilitySchema

  @stale_threshold_seconds ServerState.stale_threshold_seconds()

  def group_fan_out(message, eid) do

    now = DateTime.utc_now()
    devices = DeviceStorage.fetch_devices_by_eid(eid)

    devices 
    |> Enum.filter(fn d -> d.status == "ONLINE" and DateTime.diff(now, d.last_seen) <= @stale_threshold_seconds end)
    |> Enum.each(fn device -> pair_fan_out({message, device.device_id, eid}) end)

  end

  def device_group_fan_out({id, eid, device_id, type} = message, eid) do
    now = DateTime.utc_now()
    devices = DeviceStorage.fetch_devices_by_eid(eid)

    devices
    |> Enum.filter(fn d -> d.status == "ONLINE" and DateTime.diff(now, d.last_seen) <= @stale_threshold_seconds end)
    |> Enum.each(fn device ->
      success = ThrowAwarenessVisibilitySchema.success(id,eid,device.device_id,type)
      pair_fan_out({success, device.device_id, eid})
      
    end)
  end


  def pair_fan_out({message, device_id, eid}) do
    RegistryHub.receive_awareness_from_server(device_id, eid, message)
  end

end

# JWT.generate_tokens(%{device_id: "bbbbb1", eid: "a@domain.com", user_id: "1"})
# Storage.DeviceStorage.fetch_devices_by_eid("a@domain.com")