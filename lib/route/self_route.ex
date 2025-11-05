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


  # Generic group fan-out for awareness messages
  def send_offline_message(from_eid, to_id) do
    now = DateTime.utc_now()

    case DeviceStorage.fetch_devices_by_eid(from_eid) do
      {:error, reason} ->
        Logger.error("❌ Failed to fetch devices for EID #{from_eid}: #{inspect(reason)}")
        {:error, reason}

      devices ->
        devices
        |> Enum.filter(fn d ->
          d.status == "ONLINE" and DateTime.diff(now, d.last_seen) <= @stale_threshold_seconds
        end)
        |> Task.async_stream(
          fn device ->
            from_device_id = device.device_id
            user_key = from_eid <> "_" <> to_id
            

            # Fetch pending messages for this user's device
            
            case BimipLog.fetch(user_key, from_device_id, 1, 10000) do
              {:ok, %{messages: msgs}} ->

                filtered =
                  msgs
                  |> Enum.filter(fn msg ->
                    msg.payload.device_id != from_device_id
                  end)

                # Step 2: build structured messages
                built =
                  Enum.map(filtered, fn msg ->
                    ThrowMessageSchema.build_message(msg.payload)
                  end)

                if built != [] do
                  send_batch_to_device(from_eid, from_device_id, built)
                else
                  Logger.info("✅ No pending messages for #{from_eid}/#{from_device_id}")
                end

              {:error, reason} ->
                Logger.error("❌ Failed to fetch messages for #{from_eid}/#{from_device_id}: #{inspect(reason)}")
            end
          end,
          max_concurrency: 10,
          timeout: 5_000,
          on_timeout: :kill_task
        )
        |> Stream.run()

        :ok
    end
  end

  # ----------------------------------------------------------------------
  # Wrap all messages in a single <message> stanza and fan-out once
  # ----------------------------------------------------------------------
  defp send_batch_to_device(eid, device_id, messages) do
    encoded = ThrowMessageSchema.success(messages)
    pair_fan_out({encoded, device_id, eid})
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
  def pair_fan_out({message, device_id, eid}) do
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


# 1. SEND message.
# 2. save on a queue for A and B
# 3. fetch other device pending data and send to A
# 4. send ack of newly sent message to A.
# 5. A on receiving pending data of other device, send offset dispose to A to move the offset