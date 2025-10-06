defmodule Route.SelfFanOut do

  alias Storage.DeviceStorage
  alias Settings.ServerState

  #use this to also shedule termination
  @stale_threshold_seconds ServerState.stale_threshold_seconds()

  def awareness(awareness, eid) do

    now = DateTime.utc_now()
    devices = DeviceStorage.fetch_devices_by_eid(eid)

    devices 
    |> Enum.filter(fn d -> d.status == "ONLINE" and DateTime.diff(now, d.last_seen) <= @stale_threshold_seconds end)
    |> Enum.each(fn device -> send_to_owner_device({awareness, device.device_id, eid}) end)

  end

  def send_to_owner_device({awareness, device_id, eid}) do
    IO.inspect({awareness, device_id, eid})
  end

end