defmodule Device.Transmission do

  alias Route.Connect

  def emit(eid, device_id, all_devices, payload) do

    stale_limit = get_stale_threshold()
    now = DateTime.utc_now()

    online_devices =
      all_devices
      |> Enum.filter(fn {_id, dev} ->
        DateTime.diff(now, dev.last_seen, :second) <= stale_limit and
          dev.device_id != device_id
      end)
      |> Enum.map(fn {_id, dev} -> dev end)

      online_devices
      |> Task.async_stream(
        fn dev ->
          Connect.outbouce(dev.device_id, payload)
        end,
        max_concurrency: 10,
        ordered: false,
        timeout: 5_000
      )
      |> Stream.run()

  end

  defp get_stale_threshold do
    Settings.Connections.stale_threshold_seconds()
  end
end
