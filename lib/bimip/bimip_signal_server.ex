defmodule Bimip.SignalServer do
  use GenServer
  alias Supervisor.{Registry, Client}
  alias Route.SignalCommunication
  alias Chat.SendMessage
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
  require Logger


  @stale_threshold_seconds ServerState.stale_threshold_seconds()

  # ----------------------
  # Start
  # ----------------------
  def start_link(%{eid: eid, device_id: device_id, exp: exp, ws_pid: ws_pid} = state) do
    GenServer.start_link(__MODULE__, state,
      name: Registry.via_monitor_registry(eid)
    )
  end

  @impl true
  def init(%{eid: eid, device_id: device_id, exp: exp, ws_pid: ws_pid} = state) do
    registration =
      case Registration.fetch_registration(eid) do
        {:ok, record} ->
          record

        {:error, :not_found} ->
          %{
            eid: eid,
            display_name: "Unknown User",
            visibility: 1
          }

        {:error, reason} ->
          Logger.error("Failed to fetch registration for #{eid}: #{inspect(reason)}")
          %{
            eid: eid,
            display_name: "Unknown User",
            visibility: 1
          }
      end

    # Start initial device session asynchronously
    GenServer.cast(self(), {:start_device, {eid, device_id, exp, ws_pid}})
    {:ok,
    %{
      eid: eid,
      visibility: registration.visibility,
      display_name: registration.display_name,
      current_timer: nil,
      force_stale: DateTime.utc_now(),
      devices: %{}
    }}
  end

  # ----------------------
  # Device management
  # ----------------------
  @impl true
  def handle_cast({:start_device, {eid, device_id, exp, ws_pid}}, state) do
    case Client.start_session({eid, device_id, exp, ws_pid}) do
      {:ok, pid} ->
        devices = Map.put(state.devices, device_id, pid)
        GenServer.cast(self(), {:persist_device_state, %{eid: eid, device_id: device_id, ws_pid: ws_pid}})
        {:noreply, %{state | devices: devices}}
      {:error, reason} ->
        Logger.error("Failed to start device #{device_id} for #{eid}: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:persist_device_state, %{device_id: device_id, eid: eid, ws_pid: ws_pid}}, state) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    payload = %{
      device_id: device_id,
      eid: eid,
      last_seen: now,
      ws_pid: :erlang.pid_to_list(ws_pid) |> to_string(),
      status: "ONLINE",
      last_received_version: 0,
      ip_address: nil,
      app_version: nil,
      os: nil,
      last_activity: now,
      supports_notifications: true,
      supports_media: true,
      status_source: "LOGIN",
      visibility: state.visibility,
      inserted_at: now
    }

    DeviceStorage.register_device_session(device_id, eid, payload)
    Broker.group(eid, ThrowAwarenessSchema.success(eid, device_id, "", "", 6), state.visibility)
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

  # Note when working on ping pong, verify is this is a system ping pong. network ping pong is not allow on server
  # Only client server ping pong is allow on the server. client genserver should handle network ping pong
  # only send message to server only when want to terminate
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
    DeviceStorage.delete_device(device_id, eid)
    if Storage.DeviceStorage.remaining_active_devices?(eid) do
      DeviceStorage.cancel_termination_if_any_device_are_online(current_timer)
      {:noreply, state}
    else
      DeviceStorage.schedule_termination_if_all_offline(state)
      {:noreply, state}
    end
  end

  def handle_info(:terminate, %{eid: eid, current_timer: current_timer} = state) do
    if Storage.DeviceStorage.remaining_active_devices?(eid) do
      Logger.warning("Active devices detected. Skipping termination.", eid: eid, timer: current_timer, reason: :devices_still_active)
      {:noreply, state}
    else
      Logger.warning("Client process terminated gracefully", eid: eid, reason: :no_active_devices)
      {:stop, :normal, state}
    end
  end

  # ----------------------
  # Awareness routing
  # ----------------------
  def handle_cast({:route_awareness, from_eid, from_device_id, to_eid, to_device_id, type, data}, %{visibility: visibility} = state) do

    case type do

      s when s in 1..2 ->

        DeviceStorage.update_device_status(from_device_id, from_eid, "AWARENESS", StatusMapper.status_name(type))
        if type == 1 do
          # fan out offline queue
          IO.inspect("Fanout offline queue")
        end
          Broker.group(from_eid, data, visibility)

      s when s in 3..6 ->
        Broker.group(from_eid, data, visibility)
      _ -> :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:awareness_update, encoded_msg}, %{eid: eid} = state) do
    with %Bimip.MessageScheme{payload: {:awareness, %Bimip.Awareness{} = awareness}} <- Bimip.MessageScheme.decode(encoded_msg) do
      from_eid = awareness.from.eid
      status = awareness.status

      case status do
        s when s in 1..2 ->
          Subscriber.update_subscriber(eid, from_eid, StatusMapper.status_name(s))
          AwarenessFanOut.group_fan_out(encoded_msg, eid)
        s when s in 3..5 ->
          Subscriber.update_subscriber(eid, from_eid, "ONLINE")
        6 ->
          Subscriber.update_subscriber(eid, from_eid, "ONLINE")
          AwarenessFanOut.group_fan_out(encoded_msg, eid)
        _ -> Logger.warning("Unknown awareness status: #{inspect(status)} from #{from_eid}")
      end
    else
      {:error, reason} -> Logger.error("Failed to decode awareness payload: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  def handle_cast({:route_awareness_visibility, visibility}, state) do
    # Log type for debugging
    IO.inspect(visibility.type, label: "Awareness type")

    # Call RPC to update global awareness state
    case BimipRPCClient.awareness_visibility(
          visibility.id,
          visibility.eid,
          visibility.device_id,
          visibility.type,
          visibility.timestamp
        ) do

      {:ok, %BimipServer.AwarenessVisibilityRes{status: 0} = res} ->

        Registration.upsert_registration(res.eid, res.type, res.display_name)
        success_payload = {res.id, res.eid, res.device_id, res.type}
        AwarenessFanOut.device_group_fan_out(success_payload, res.eid)

      {:ok, %BimipServer.AwarenessVisibilityRes{status: status} = res} when status != 0 ->
        error_payload = ThrowAwarenessVisibilitySchema.error(
          res.id,
          res.eid,
          res.device_id,
          res.message
        )

        AwarenessFanOut.pair_fan_out(error_payload, visibility.device_id)

      {:error, reason} ->
        error_payload = ThrowAwarenessVisibilitySchema.error(
          visibility.id,
          visibility.eid,
          visibility.device_id,
          "RPC call failed: #{inspect(reason)}"
        )

        AwarenessFanOut.pair_fan_out(error_payload, visibility.device_id)
    end

    Subscriber.update_subscriber(visibility.eid, visibility.device_id, "ONLINE")

    {:noreply, state}
  end

  # -------------------------------
  # Route and persist message
  # -------------------------------
  @impl true
  def handle_cast({:route_message, eid, device_id, post}, state) do
    GenServer.cast(self(), {:chat_queue, post.from, post.to, post.id, post})
    {:noreply, state}
  end

  @impl true
  def handle_cast({:chat_queue, from, to, id, payload},  state) do
    SendMessage.store_message({from, to, id, payload}, state)
  end

  @impl true
  def handle_cast({:send_message_to_receiver_server,  payload}, state) do
    SignalCommunication.send_message_to_all_receiver_devices(payload)
    {:noreply, state}
  end

  # ----------------------
  # Message logging (via BimipLog GenServer)
  # ----------------------
  @impl true
  def handle_cast({:log_user_message, partition_id, from, to, payload}, %{eid: eid} = state) do
    case BimipLog.write("#{from}_#{to}", partition_id, from, to, payload) do
      {:ok, offset} ->
        Logger.info("[LOG] eid=#{eid} partition=#{partition_id} offset=#{offset} from=#{from} to=#{to}")
      {:error, reason} ->
        Logger.error("[LOG] failed write eid=#{eid} partition=#{partition_id} reason=#{inspect(reason)}")
    end

    {:noreply, state}
  end

  # ----------------------
  # Fetch messages
  # ----------------------
  @impl true
  def handle_cast({:fetch_batch_chat, eid, device_id}, state) do
    case BimipLog.fetch(eid, device_id, 1, 10) do
      {:ok, %{messages: messages}} -> Enum.each(messages, &IO.inspect(&1))
      {:error, reason} -> Logger.error("[FETCH] failed for eid=#{eid}: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:fetch_batch_notification, eid, device_id}, state) do
    case BimipLog.fetch(eid, device_id, 2, 10) do
      {:ok, %{messages: messages}} -> Enum.each(messages, &IO.inspect(&1))
      {:error, reason} -> Logger.error("[FETCH] failed for eid=#{eid}: #{inspect(reason)}")
    end

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
end
