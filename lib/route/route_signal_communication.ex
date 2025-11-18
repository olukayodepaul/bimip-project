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
            # pair_fan_out({message, device.device_id, eid})
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

  def send_direct_message(
        signal_ack_state,
        from_eid,
        signal_offset,
        user_offset,
        message,
        from_device_id \\ nil,
        signal_type \\ nil
      ) do
    now = DateTime.utc_now()

    case DeviceStorage.fetch_devices_by_eid(from_eid) do
      {:error, reason} ->
        Logger.error("❌ Failed to fetch devices for EID #{from_eid}: #{inspect(reason)}")
        {:error, reason}

      devices ->
        devices
        |> Enum.filter(fn d ->
          # remove sender device sp as not to get the message twice
          d.status == "ONLINE" and
            DateTime.diff(now, d.last_seen) <= @stale_threshold_seconds and
            d.device_id != from_device_id
        end)
        |> Task.async_stream(
          fn device ->
            payload =
              ThrowMessageSchema.build_message(
                signal_ack_state,
                message,
                signal_offset,
                user_offset,
                signal_type
              )

            # pair_fan_out({payload, device.device_id, device.eid})
          end,
          max_concurrency: 10,
          timeout: 5_000,
          on_timeout: :kill_task
        )
        |> Stream.run()

        :ok
    end
  end

  # # Generic group fan-out for awareness messages
  # def send_offline_message(from_eid, to_id, limit \\ 1) do
  #   now = DateTime.utc_now()

  #   case DeviceStorage.fetch_devices_by_eid(from_eid) do
  #     {:error, reason} ->
  #       Logger.error("❌ Failed to fetch devices for EID #{from_eid}: #{inspect(reason)}")
  #       {:error, reason}

  #     devices ->
  #       devices
  #       |> Enum.filter(fn d ->
  #         d.status == "ONLINE" and DateTime.diff(now, d.last_seen) <= @stale_threshold_seconds
  #       end)
  #       |> Task.async_stream(
  #         fn device ->
  #           from_device_id = device.device_id

  #           # --- Check grace period first ---
  #           # if grace_expired?(from_eid, from_device_id) do
  #             user_key = from_eid <> "_" <> to_id

  #             case BimipLog.fetch(user_key, from_device_id, 1, limit) do
  #               {:ok, %{messages: msgs}} ->
  #                 filtered =
  #                   msgs
  #                   |> Enum.filter(fn msg -> msg.payload.device_id != from_device_id end)

  #                 if filtered != [] do
  #                   built =
  #                     Enum.map(filtered, fn msg -> ThrowMessageSchema.build_message(msg.payload) end)

  #                   # send_batch_to_device(from_eid, from_device_id, built)
  #                   # Set grace period: 30 seconds = 30_000 milliseconds
  #                   # set_grace(from_eid, from_device_id, 30_000)
  #                 else
  #                   Logger.info("✅ No pending messages for #{from_eid}/#{from_device_id}")
  #                 end

  #               {:error, reason} ->
  #                 Logger.error("❌ Failed to fetch messages for #{from_eid}/#{from_device_id}: #{inspect(reason)}")
  #             end
  #           # else
  #           #   # Grace period active — skip all processing
  #           #   Logger.debug("⏱ Grace period active for #{from_eid}/#{from_device_id}, skipping fetch & send")
  #           # end
  #         end,
  #         max_concurrency: 10,
  #         timeout: 5_000,
  #         on_timeout: :kill_task
  #       )
  #       |> Stream.run()
  #       :ok
  #   end
  # end

  # # ----------------------------------------------------------------------
  # # Wrap all messages in a single <message> stanza and fan-out once
  # # ----------------------------------------------------------------------
  # defp send_batch_to_device(eid, device_id, messages) do
  #   encoded = ThrowMessageSchema.success(messages)
  #   pair_fan_out({encoded, device_id, eid})
  # end

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
            # pair_fan_out({success, device.device_id, eid})
          end,
          max_concurrency: 10,
          timeout: 5_000,
          on_timeout: :kill_task
        )
        |> Stream.run()

        :ok
    end
  end

  def single_signal_message(%{
    to: %{eid: to_eid, connection_resource_id: to_device_id},
    from: %{eid: from_eid, connection_resource_id: from_device_id},
    } = payload ) do

    now = DateTime.utc_now()

    case DeviceStorage.fetch_devices_by_eid(from_eid) do
      {:error, reason} ->
        Logger.error("❌ Failed to fetch devices for EID #{from_eid}: #{inspect(reason)}")
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

            new_payload =
              payload
              |> Map.put(:from, %{eid: device.eid, connection_resource_id: device.device_id})
              |> ThrowMessageSchema.build_message
              |> then(fn data -> single_signal_communication(%{eid: device.eid, connection_resource_id: device.device_id}, data) end)

          end,
          max_concurrency: 10,
          timeout: 5_000,
          on_timeout: :kill_task
        )
        |> Stream.run()
        :ok
    end
  end

  def single_signal_communication(from, binary_payload) do
    try do
      Connect.receive_awareness_from_server(from.connection_resource_id, from.eid, binary_payload)
    rescue
      error ->
        Logger.error("⚠️ Fan-out failed for device #{from.connection_resource_id} (EID #{from.eid}): #{inspect(error)}")
        {:error, error}
    end
  end

end
