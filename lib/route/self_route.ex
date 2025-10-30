defmodule Route.AwarenessFanOut do
  @moduledoc """
  Handles awareness fan-out for devices in the same EID group.
  Uses concurrent async streaming for scalable, non-blocking broadcasting.
  """

  require Logger
  alias Storage.DeviceStorage
  alias Settings.ServerState
  alias App.RegistryHub
  alias ThrowAwarenessVisibilitySchema

  @stale_threshold_seconds ServerState.stale_threshold_seconds()

  # Generic group fan-out for awareness messages
  def group_fan_out(message, eid) do
    now = DateTime.utc_now()

    case DeviceStorage.fetch_devices_by_eid(eid) do
      {:error, reason} ->
        Logger.error("❌ Failed to fetch devices for EID #{eid}: #{inspect(reason)}")
        {:error, reason}

      devices ->
        devices
        |> Enum.filter(fn d ->
          d.status == "ONLINE" and DateTime.diff(now, d.last_seen) <= @stale_threshold_seconds
        end)
        |> Task.async_stream(
          fn device ->
            pair_fan_out({message, device.device_id, eid})
          end,
          max_concurrency: 10,
          timeout: 5_000,
          on_timeout: :kill_task
        )
        |> Stream.run()

        :ok
    end
  end

  # Specialized group fan-out for awareness visibility toggles
  def device_group_fan_out({id, eid, _device_id, type}, eid) do
    now = DateTime.utc_now()

    case DeviceStorage.fetch_devices_by_eid(eid) do
      {:error, reason} ->
        Logger.error("❌ Failed to fetch devices for EID #{eid}: #{inspect(reason)}")
        {:error, reason}

      devices ->
        devices
        |> Enum.filter(fn d ->
          d.status == "ONLINE" and DateTime.diff(now, d.last_seen) <= @stale_threshold_seconds
        end)
        |> Task.async_stream(
          fn device ->
            success = ThrowAwarenessVisibilitySchema.success(id, eid, device.device_id, type)
            pair_fan_out({success, device.device_id, eid})
          end,
          max_concurrency: 10,
          timeout: 5_000,
          on_timeout: :kill_task
        )
        |> Stream.run()

        :ok
    end
  end

  # Send message to a single device safely
  defp pair_fan_out({message, device_id, eid}) do
    try do
      RegistryHub.receive_awareness_from_server(device_id, eid, message)
    rescue
      error ->
        Logger.error("⚠️ Fan-out failed for device #{device_id} (EID #{eid}): #{inspect(error)}")
        {:error, error}
    end
  end
end


# JWT.generate_tokens(%{device_id: "bbbbb1", eid: "a@domain.com", user_id: "1"})
# Storage.DeviceStorage.fetch_devices_by_eid("a@domain.com")