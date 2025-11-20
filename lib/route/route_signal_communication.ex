defmodule Route.SignalCommunication do
  @moduledoc """
  Handles awareness fan-out for devices in the same EID group.
  Uses concurrent async streaming for scalable, non-blocking broadcasting.
  """

  require Logger
  alias Storage.DeviceStorage
  alias Settings.ServerState
  alias Route.Connect
  alias ThrowAwarenessVisibilitySchema
  alias ThrowMessageSchema

  @stale_threshold_seconds ServerState.stale_threshold_seconds()

  def send_message_to_sender_other_devices(%{
    to: %{eid: to_eid, connection_resource_id: to_device_id},
    from: %{eid: from_eid, connection_resource_id: from_device_id},
    } = payload ) do

      if payload != %{} do

        now = DateTime.utc_now()

        case DeviceStorage.fetch_devices_by_eid(from_eid) do
          {:error, reason} ->
            Logger.error("Failed to fetch devices for EID #{from_eid}: #{inspect(reason)}")
            {:error, reason}

          devices ->
            devices
            |> Enum.filter(fn d ->
              d.status == "ONLINE" and
                DateTime.diff(now, d.last_seen) <= @stale_threshold_seconds and
                d.device_id != from_device_id
            end)
            |> Task.async_stream(
              fn device ->

                payload
                |> set_from(device.eid, device.device_id)
                |> ThrowMessageSchema.build_message
                |> then(fn data -> outbouce(%{eid: device.eid, connection_resource_id: device.device_id}, data) end)

              end,
              max_concurrency: 10,
              timeout: 5_000,
              on_timeout: :kill_task
            )
            |> Stream.run()
            :ok
        end
    end
  end

  def send_message_to_all_receiver_devices(%{
    to: %{eid: to_eid, connection_resource_id: to_device_id},
    from: %{eid: from_eid, connection_resource_id: from_device_id},
    } = payload ) do

      if(payload != %{}) do

        now = DateTime.utc_now()

        case DeviceStorage.fetch_devices_by_eid(to_eid) do
          {:error, reason} ->
            Logger.error("Failed to fetch devices for EID #{from_eid}: #{inspect(reason)}")
            {:error, reason}

          devices ->
            devices
            |> Enum.filter(fn d ->
              d.status == "ONLINE" and
                DateTime.diff(now, d.last_seen) <= @stale_threshold_seconds and
                d.device_id != from_device_id
            end)
            |> Task.async_stream(
              fn device ->

                  payload
                  |> set_from(device.eid, device.device_id)
                  |> ThrowMessageSchema.build_message
                  |> then(fn data -> outbouce(%{eid: device.eid, connection_resource_id: device.device_id}, data) end)

              end,
              max_concurrency: 10,
              timeout: 5_000,
              on_timeout: :kill_task
            )
            |> Stream.run()
            :ok
        end
      end
  end

  def set_from(payload, eid, device_id) do
    result = %{payload |
      to: %{
        eid: eid,
        connection_resource_id: device_id
      }
    }
    result
  end

  def outbouce(from, binary_payload) do
    try do
      Connect.outbouce(from.connection_resource_id, binary_payload)
    rescue
      error ->
        Logger.error("Fan-out failed for device #{from.connection_resource_id} (EID #{from.eid}): #{inspect(error)}")
        {:error, error}
    end
  end

end
