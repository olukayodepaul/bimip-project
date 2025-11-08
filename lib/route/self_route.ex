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

  # Specialized group fan-out for awareness visibility toggles
  
  def send_direct_message(signal_ack_state, from_eid, signal_offset, user_offset, message, from_device_id \\ nil, signal_type \\ nil) do
    now = DateTime.utc_now()

    case DeviceStorage.fetch_devices_by_eid(from_eid) do
      {:error, reason} ->
        Logger.error("❌ Failed to fetch devices for EID #{from_eid}: #{inspect(reason)}")
        {:error, reason}

      devices ->
        devices
        |> Enum.filter(fn d ->
          d.status == "ONLINE" 
          and DateTime.diff(now, d.last_seen) <= @stale_threshold_seconds
          and d.device_id != from_device_id  # remove sender device sp as not to get the message twice
        end)
        |> Task.async_stream(
          fn device ->
            payload = ThrowMessageSchema.build_message(signal_ack_state, message, signal_offset, user_offset, signal_type)
            pair_fan_out({payload, device.device_id, device.eid})
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

  # def grace_expired?(user, device) do
  #   key = {user, device}

  #   case :mnesia.transaction(fn -> :mnesia.read(:resume_grace, key) end) do
  #     {:atomic, [{:resume_grace, ^key, timestamp}]} ->
  #       System.system_time(:millisecond) >= timestamp

  #     {:atomic, []} ->
  #       true

  #     {:aborted, reason} ->
  #       # fallback to allow processing
  #       Logger.error("❌ Failed to read grace period for #{inspect(key)}: #{inspect(reason)}")
  #       true
  #   end
  # end

  # def set_grace(user, device, duration_ms) do
  #   key = {user, device}
  #   ts = System.system_time(:millisecond) + duration_ms

  #   :mnesia.transaction(fn ->
  #     :mnesia.write({:resume_grace, key, ts})
  #   end)
  # end


end


# JWT.generate_tokens(%{device_id: "bbbbb1", eid: "a@domain.com", user_id: "1"})
# Storage.DeviceStorage.fetch_devices_by_eid("a@domain.com")


# 1. SEND message.
# 2. save on a queue for A and B
# 3. fetch other device pending data and send to A
# 4. send ack of newly sent message to A.
# 5. A on receiving pending data of other device, send offset dispose to A to move the offset

# Route.AwarenessFanOut.set_grace("a@domain.com", "aaaaa1", 30_000)
# Route.AwarenessFanOut.grace_expired?("a@domain.com", "aaaaa4") 