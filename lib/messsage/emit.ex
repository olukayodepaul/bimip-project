defmodule Device.Transmission do
  alias Route.Connect

  @doc """
  Sends to other devices of the same user, excluding the sender.
  """
  def emit(_eid, sender_device_id, all_devices, payload) when is_binary(payload) do
    now = System.system_time(:second)
    stale_limit = get_stale_threshold()

    Enum.each(all_devices, fn {id, dev} ->
      if id != sender_device_id and (now - dev.last_seen) <= stale_limit and dev.presence in [1] do
        Connect.outbouce(dev.device_id, payload)
      end
    end)
    :ok
  end

  @doc """
  Sends to ALL active devices in the map (Broadcast).
  """
  def emit_broadcast(all_devices, bin) when is_binary(bin) do
    now = System.system_time(:second)
    stale_limit = get_stale_threshold()

    Enum.each(all_devices, fn {id, dev} ->
      if (now - dev.last_seen) <= stale_limit and dev.presence in [1] do
        Connect.outbouce(dev.device_id, bin)
      end
    end)
    :ok
  end

  defp get_stale_threshold do
    Settings.Connections.stale_threshold_seconds()
  end
end
