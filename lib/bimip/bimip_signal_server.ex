defmodule Bimip.SignalServer do
  use GenServer
  require Logger
  alias Supervisor.{Registry, Client}
  alias Route.SignalCommunication
  alias Chat.{SendMessage, ReceivedSignal}
  # refactoring



  alias Storage.DeviceStorage
  alias Storage.Registration
  alias Bimip.Broker
  alias Settings.ServerState
  alias Route.AwarenessFanOut
  alias ThrowAwarenessSchema
  alias Util.StatusMapper
  alias Storage.Subscriber
  alias BimipLog
  alias BimipRPCClient
  alias Storage.Registration



  @stale_threshold_seconds ServerState.stale_threshold_seconds()
  # ----------------------
  # Start
  # ----------------------
  def start_link(%{eid: eid} = state) do
    GenServer.start_link(__MODULE__, state, name: Registry.via_monitor_registry(eid))
  end

  @impl true
  def init(%{eid: eid, device_id: device_id, exp: _exp, ws_pid: ws_pid, uupid: uupid} = _state) do
    {:ok,
    %{
      eid: eid,
      current_timer: nil,
      force_stale: DateTime.utc_now(),
      devices: %{
        device_id => %{
          ws_pid: ws_pid,
          uupid: uupid,
          last_seen: DateTime.utc_now()
        }
      }
    }}
  end

  # ----------------------
  # Device management
  # ----------------------
 `x@impl true
  def handle_cast({:start_device, {_eid, device_id, exp, ws_pid, uupid}}, state) do

    #start the device genserver....

    device_info = %{
      ws_pid: ws_pid,
      uupid: uupid,
      exp: exp,
      last_seen: DateTime.utc_now()
    }
    new_devices = Map.put(state.devices, device_id, device_info)
    new_state = %{state | devices: new_devices}
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:persist_device_state, %{device_id: device_id, eid: eid, ws_pid: ws_pid, uupid: uupid}}, state) do
    # now = DateTime.utc_now() |> DateTime.truncate(:second)

    # payload = %{
    #   device_id: device_id,
    #   uupid: uupid,
    #   eid: eid,
    #   last_seen: now,
    #   ws_pid: :erlang.pid_to_list(ws_pid) |> to_string(),
    #   status: "ONLINE",
    #   last_received_version: 0,
    #   ip_address: nil,
    #   app_version: nil,
    #   os: nil,
    #   last_activity: now,
    #   supports_notifications: true,
    #   supports_media: true,
    #   status_source: "LOGIN",
    #   visibility: state.visibility,
    #   inserted_at: now
    # }

    # DeviceStorage.register_device_session(device_id, eid, payload)
    # Broker.group(eid, ThrowAwarenessSchema.success(eid, device_id, "", "", 6), state.visibility)
    {:noreply, state}
  end

  # ----------------------
  # Client pong handler
  # ----------------------
  # Note when working on ping pong, verify is this is a system ping pong. network ping pong is not allow on server
  # Only client server ping pong is allow on the server. client genserver should handle network ping pong
  # only send message to server only when want to terminate
  @impl true
  def handle_cast({:client_send_pong, {eid, device_id, status}}, %{force_stale: force_stale} = state) do
    # now = DateTime.utc_now()
    # DeviceStorage.update_device_status(device_id, eid, "PONG", StatusMapper.status_name(status))

    # case Storage.DeviceStateChange.track_state_change(eid) do
    #   {:changed, _user_status, _online_devices} ->
    #     {:noreply, %{state | force_stale: now}}
    #   {:unchanged, _user_status, _online_devices} ->
    #     idle_too_long? = DateTime.diff(now, force_stale) >= @stale_threshold_seconds
    #     if idle_too_long?, do: {:noreply, %{state | force_stale: now}}, else: {:noreply, state}
    # end

    {:noreply, state}
  end

  def handle_cast({:route_ping_pong, eid, device_id}, %{visibility: visibility} = state) do
    DeviceStorage.update_device_status(device_id, eid, "PING_PONG", StatusMapper.status_name(1))
    Broker.group(eid, ThrowAwarenessSchema.success(eid, device_id, "", "", 6), visibility)
    {:noreply, state}
  end

  # ----------------------
  # Termination handling
  # ----------------------
  @impl true
  def handle_cast({:send_terminate_signal_to_server, %{device_id: device_id, eid: eid}}, %{current_timer: current_timer} = state) do
    # DeviceStorage.delete_device(device_id, eid)
    # if Storage.DeviceStorage.remaining_active_devices?(eid) do
    #   DeviceStorage.cancel_termination_if_any_device_are_online(current_timer)
    #   {:noreply, state}
    # else
    #   DeviceStorage.schedule_termination_if_all_offline(state)
    #   {:noreply, state}
    # end
    {:noreply, state}
  end

  def handle_info(:terminate, %{eid: eid, current_timer: current_timer} = state) do
    # if Storage.DeviceStorage.remaining_active_devices?(eid) do
    #   Logger.warning("Active devices detected. Skipping termination.", eid: eid, timer: current_timer, reason: :devices_still_active)
    #   {:noreply, state}
    # else
    #   Logger.warning("Client process terminated gracefully", eid: eid, reason: :no_active_devices)
    #   {:stop, :normal, state}
    # end
    {:noreply, state}
  end

  # ----------------------
  # Awareness routing
  # ----------------------
  def handle_cast({:route_awareness, from_eid, from_device_id, to_eid, to_device_id, type, data}, %{visibility: visibility} = state) do

    # case type do

    #   s when s in 1..2 ->

    #     DeviceStorage.update_device_status(from_device_id, from_eid, "AWARENESS", StatusMapper.status_name(type))
    #     if type == 1 do
    #       # fan out offline queue
    #       IO.inspect("Fanout offline queue")
    #     end
    #       Broker.group(from_eid, data, visibility)

    #   s when s in 3..6 ->
    #     Broker.group(from_eid, data, visibility)
    #   _ -> :ok
    # end

    {:noreply, state}
  end

  @impl true
  def handle_info({:awareness_update, encoded_msg}, %{eid: eid} = state) do
    # with %Bimip.MessageScheme{payload: {:awareness, %Bimip.Awareness{} = awareness}} <- Bimip.MessageScheme.decode(encoded_msg) do
    #   from_eid = awareness.from.eid
    #   status = awareness.status

    #   case status do
    #     s when s in 1..2 ->
    #       Subscriber.update_subscriber(eid, from_eid, StatusMapper.status_name(s))
    #       AwarenessFanOut.group_fan_out(encoded_msg, eid)
    #     s when s in 3..5 ->
    #       Subscriber.update_subscriber(eid, from_eid, "ONLINE")
    #     6 ->
    #       Subscriber.update_subscriber(eid, from_eid, "ONLINE")
    #       AwarenessFanOut.group_fan_out(encoded_msg, eid)
    #     _ -> Logger.warning("Unknown awareness status: #{inspect(status)} from #{from_eid}")
    #   end
    # else
    #   {:error, reason} -> Logger.error("Failed to decode awareness payload: #{inspect(reason)}")
    # end

    {:noreply, state}
  end

  def handle_cast({:route_awareness_visibility, visibility}, state) do
    # # Log type for debugging
    # IO.inspect(visibility.type, label: "Awareness type")

    # # Call RPC to update global awareness state
    # case BimipRPCClient.awareness_visibility(
    #       visibility.id,
    #       visibility.eid,
    #       visibility.device_id,
    #       visibility.type,
    #       visibility.timestamp
    #     ) do

    #   {:ok, %BimipServer.AwarenessVisibilityRes{status: 0} = res} ->

    #     Registration.upsert_registration(res.eid, res.type, res.display_name)
    #     success_payload = {res.id, res.eid, res.device_id, res.type}
    #     AwarenessFanOut.device_group_fan_out(success_payload, res.eid)

    #   {:ok, %BimipServer.AwarenessVisibilityRes{status: status} = res} when status != 0 ->
    #     error_payload = ThrowAwarenessVisibilitySchema.error(
    #       res.id,
    #       res.eid,
    #       res.device_id,
    #       res.message
    #     )

    #     AwarenessFanOut.pair_fan_out(error_payload, visibility.device_id)

    #   {:error, reason} ->
    #     error_payload = ThrowAwarenessVisibilitySchema.error(
    #       visibility.id,
    #       visibility.eid,
    #       visibility.device_id,
    #       "RPC call failed: #{inspect(reason)}"
    #     )

    #     AwarenessFanOut.pair_fan_out(error_payload, visibility.device_id)
    # end

    # Subscriber.update_subscriber(visibility.eid, visibility.device_id, "ONLINE")

    {:noreply, state}
  end





  # ----------------------
  # Fetch messages
  # ----------------------
  @impl true
  def handle_cast({:fetch_batch_chat, eid, device_id}, state) do
    # case BimipLog.fetch(eid, device_id, 1, 10) do
    #   {:ok, %{messages: messages}} -> Enum.each(messages, &IO.inspect(&1))
    #   {:error, reason} -> Logger.error("[FETCH] failed for eid=#{eid}: #{inspect(reason)}")
    # end

    {:noreply, state}
  end


  # ----------------------
  # Catch-all for unexpected messages
  # ----------------------
  @impl true
  def handle_info(msg, state) do
    Logger.warning("Unhandled message received in Master GenServer: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def handle_cast({:fetch_batch_notification, eid, device_id}, state) do
    # case BimipLog.fetch(eid, device_id, 2, 10) do
    #   {:ok, %{messages: messages}} -> Enum.each(messages, &IO.inspect(&1))
    #   {:error, reason} -> Logger.error("[FETCH] failed for eid=#{eid}: #{inspect(reason)}")
    # end

    {:noreply, state}
  end

  # ----------------------
  # Chat Queue Integration
  # ----------------------
  @impl true
  def handle_cast({:route_message, %Chat.MessageStruct{} = payload},  state) do

    message_id = payload.peer_uid
    user = payload.eid

    case Queue.MessageTracker.check_and_insert(user, payload.device_id, message_id) do
      {:ok, :inserted} ->

        %Chat.EntityStruct{eid: to_eid} = payload.to

        reply_to = to_eid
        uupid = payload.uupid
        type = 1
        partition_payloay_ctx = payload.payload_context

        result = Queue.QueueLogImpl.write(partition_payloay_ctx, user, reply_to, uupid, type, partition_payloay_ctx, payload, message_id)

        case result do
          {:ok, offset} ->
            IO.inspect({1, offset})
            Chat.SendMessage.send_received_ack_to_sender(message_id, user, reply_to, offset, payload.device_id)
            Chat.SendMessage.push_message_to_other_devices(payload, offset, :device)
            {:noreply, state}

          {:error, :backpressure} ->
            {:noreply, state}
        end

      {:error, :already_exists} ->
        Logger.debug("2 Duplicate message ignored: #{payload.peer_uid}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:message_transmiter, payload}, %{eid: eid} = state) do

    message_id = payload.peer_uid
    from_device = payload.from.connection_resource_id

    case Queue.MessageTracker.check_and_insert(eid, from_device, message_id) do
      {:ok, :inserted} ->

        partition_payloay_ctx = payload.payload_context
        reply_to = payload.from.eid
        type = 3
        from_device = payload.from.connection_resource_id

        new_payload = %{
          peer_uid: message_id,
          timestamp: Until.UniPosTime.uni_pos_time(),
          payload: payload.payload,
          payload_context: partition_payloay_ctx,
          encryption_type: payload.encryption_type,
          encrypted: payload.encrypted,
          signature: payload.signature,
          device_id: from_device,
          uupid: nil,
          eid: reply_to,
          from: %Chat.EntityStruct{
            eid: reply_to,
            connection_resource_id: from_device
          },
          to: %Chat.EntityStruct{eid: payload.to.eid, connection_resource_id: nil}
        }
        |> Chat.Message.Model.to_message_struct()

        result = Queue.QueueLogImpl.write(partition_payloay_ctx, eid, reply_to, 0, type, partition_payloay_ctx, new_payload, message_id)

        case result do
          {:ok, offset} ->
            {:noreply, state}

          {:error, :backpressure} ->
            {:noreply, state}
        end

      {:error, :already_exists} ->
        Logger.debug("2 Duplicate message ignored: #{payload.peer_uid}")
        {:noreply, state}
    end
    {:noreply, state}
  end


  # # -------------------------------
  # # Signal
  # # -------------------------------
  # @impl true
  # def handle_cast({:signal_to_server, payload}, state) do
  #   {:noreply, state}
  # end



  # def handle_cast({:signal_deliver_ack_server, payload}, state) do

  #   %Bimip.BatchedOffset{
  #     owners: %Bimip.OWNERS {
  #     from: _from,
  #     to: _to
  #     }
  #   } = List.first(payload)

  #   {:noreply, state}

  # end


  @impl true
  def handle_cast({:signal_to_server_ack, payload}, %{eid: eid} = state) do
    # IO.inspect({payload, eid})
    {:noreply, state}
  end



end


# Queue.QueueLogImpl.fetch_for_device("a@domain.com", 1, "aaaaa1", 1)
