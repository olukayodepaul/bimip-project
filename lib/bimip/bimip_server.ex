defmodule Bimip.Service.Master do
  use GenServer
  alias Bimip.Registry
  alias Bimip.Device.Supervisor
  alias Storage.DeviceStorage
  alias Storage.DeviceStateChange
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
  @fetch_interval 100 # milliseconds between fetch batches

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
    # Fetch user awareness level
    level =
      case DeviceStorage.fetch_user_awareness(eid) do
        {:ok, level} -> level
        {:error, :not_found} ->
          DeviceStorage.insert_awareness(eid)
          2
        {:error, reason} ->
          Logger.error("Error fetching awareness for #{eid}: #{inspect(reason)}")
          2
      end

    # Start initial device session
    GenServer.cast(self(), {:start_device, {eid, device_id, exp, ws_pid}})

    {:ok,
      %{
        eid: eid,
        awareness: level,
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
    case Supervisor.start_session({eid, device_id, exp, ws_pid}) do
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
      awareness_intention: state.awareness,
      inserted_at: now
    }

    DeviceStorage.register_device_session(device_id, eid, payload)
    Broker.group(eid, ThrowAwarenessSchema.success(eid, device_id), state.awareness)
    {:noreply, state}
  end

  # ----------------------
  # Client pong handler
  # ----------------------
  @impl true
  def handle_cast({:client_send_pong, {eid, device_id, status}}, %{force_stale: force_stale, awareness: awareness} = state) do
    now = DateTime.utc_now()
    DeviceStorage.update_device_status(device_id, eid, "PONG", StatusMapper.status_name(status))

    case Storage.DeviceStateChange.track_state_change(eid) do
      {:changed, _user_status, _online_devices} ->
        {:noreply, %{state | force_stale: now}}
      {:unchanged, _user_status, _online_devices} ->
        idle_too_long? = DateTime.diff(now, force_stale) >= @stale_threshold_seconds
        if idle_too_long?, do: {:noreply, %{state | force_stale: now}}, else: {:noreply, state}
    end
  end

  # ----------------------
  # Termination handling
  # ----------------------
  @impl true
  def handle_cast({:send_terminate_signal_to_server, %{device_id: device_id, eid: eid}}, %{current_timer: current_timer} = state) do
    DeviceStorage.delete_device(device_id, eid)
    if Storage.DeviceStateChange.remaining_active_devices?(eid) do
      DeviceStateChange.cancel_termination_if_any_device_are_online(current_timer)
      {:noreply, state}
    else
      DeviceStateChange.schedule_termination_if_all_offline(state)
      {:noreply, state}
    end
  end

  def handle_info(:terminate, %{eid: eid, current_timer: current_timer} = state) do
    if Storage.DeviceStateChange.remaining_active_devices?(eid) do
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
  def handle_cast({:route_awareness, from_eid, from_device_id, to_eid, to_device_id, type, data}, %{awareness: awareness} = state) do
    DeviceStorage.update_device_status(from_device_id, from_eid, "AWARENESS", StatusMapper.status_name(type))

    case type do
      1 -> Broker.group(from_eid, data, awareness)
      s when s in 2..5 -> Broker.group(from_eid, data, awareness)
      s when s in 6..11 -> Broker.peer(to_eid, data, awareness)
      _ -> :ok
    end

    {:noreply, state}
  end

  def handle_cast({:route_ping_pong, eid, device_id}, %{awareness: awareness} = state) do
    DeviceStorage.update_device_status(device_id, eid, "PING_PONG", StatusMapper.status_name(1))
    Broker.group(eid, ThrowAwarenessSchema.success(eid, device_id, "", "", 12), awareness)
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
        s when s in 6..11 -> 
          Subscriber.update_subscriber(eid, from_eid, "ONLINE")
          AwarenessFanOut.group_fan_out(encoded_msg, eid)
        12 -> Subscriber.update_subscriber(eid, from_eid, "ONLINE")
        _ -> Logger.warning("Unknown awareness status: #{inspect(status)} from #{from_eid}")
      end
    else
      {:error, reason} -> Logger.error("Failed to decode awareness payload: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  def handle_cast({:route_awareness_visibility, visibility}, state) do

    IO.inspect(visibility.type)
    case BimipRPCClient.awareness_visibility(
          visibility.id,
          visibility.eid,
          visibility.device_id,
          visibility.type,
          visibility.timestamp
        ) do
      {:ok, %BimipServer.AwarenessVisibilityRes{status: 0} = res} ->
        
      # let proodcast to all if sucessfull....
      Registration.upsert_registration(
        res.eid, 
        res.type, 
        res.display_name
      )

      AwarenessFanOut.group_fan_out(error_binary, res.eid)

      {:ok, %BimipServer.AwarenessVisibilityRes{} = res} ->

        error_binary = ThrowAwarenessVisibilitySchema.error(
          res.eid,
          res.device_id,
          res.id,
          res.message
        )

        AwarenessFanOut.pair_fan_out(error_binary, res.eid)

      {:error, reason} ->
        # Fan out GRPC errors too
        error_binary = ThrowAwarenessVisibilitySchema.error(
          visibility.eid,
          visibility.device_id,
          visibility.id,
          "RPC call failed: #{inspect(reason)}"
        )

        AwarenessFanOut.pair_fan_out(error_binary, visibility.eid)
    end

    Subscriber.update_subscriber( visibility.eid, visibility.device_id, "ONLINE")
    {:noreply, state}
  end


  # ----------------------
  # Message logging (via BimipLog GenServer)
  # ----------------------
  @impl true
  def handle_cast({:log_user_message, partition_id, from, to, payload}, %{eid: eid} = state) do
    case BimipLog.write(eid, partition_id, from, to, payload) do
      {:ok, offset} -> Logger.info("[LOG] eid=#{eid} partition=#{partition_id} offset=#{offset} from=#{from} to=#{to}")
      {:error, reason} -> Logger.error("[LOG] failed write eid=#{eid} partition=#{partition_id} reason=#{inspect(reason)}")
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
