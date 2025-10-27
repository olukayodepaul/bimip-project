defmodule Bimip.Service.Master do
  use GenServer
  alias Bimip.Registry
  alias Bimip.Device.Supervisor
  alias Storage.DeviceStorage
  alias Bimip.Broker
  alias Storage.DeviceStateChange
  alias Settings.ServerState
  alias Route.AwarenessFanOut
  alias ThrowAwareness
  alias Storage.Subscriber
  alias ThrowAwarenessSchema
  alias Util.StatusMapper
  alias BimipLog
  require Logger

  @stale_threshold_seconds ServerState.stale_threshold_seconds()
  @fetch_interval 100 # milliseconds between fetch batches

  # ----------------------
  # GenServer start
  # ----------------------
  def start_link(%{eid: eid, device_id: device_id, exp: exp, ws_pid: ws_pid} = state) do
    GenServer.start_link(__MODULE__, state,
      name: Registry.via_monitor_registry(eid)
    )
  end

  @impl true
  def init(%{eid: eid, device_id: device_id, exp: exp, ws_pid: ws_pid} = state) do
    # Fetch awareness level for user
    Broker.presence_subscriber(eid)
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

    # # Start initial device
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

    # Register in storage
    DeviceStorage.register_device_session(device_id, eid, payload)

    # Broadcast awareness
    Broker.group(
      eid,
      ThrowAwarenessSchema.success(eid, device_id),
      state.awareness
    )

  
    {:noreply, state}
  end

  # ----------------------
  # Client pong handler
  # ----------------------
  def handle_cast({:client_send_pong, {eid, device_id, status}}, %{force_stale: force_stale, awareness: awareness} = state) do
    now = DateTime.utc_now()
    DeviceStorage.update_device_status(device_id, eid, "PONG", status)

    case Storage.DeviceStateChange.track_state_change(eid) do
      {:changed, _user_status, _online_devices} ->
        # awareness_response = ThrowAwarenessSchema.success(eid, device_id, "", "", StatusMapper.map_status_to_code(status), 2)
        # Broker.group(eid, awareness_response, awareness)
        {:noreply, %{state | force_stale: now}}
      {:unchanged, _user_status, _online_devices} ->
        idle_too_long? = DateTime.diff(now, force_stale) >= @stale_threshold_seconds
        if idle_too_long? do
          # awareness_response = ThrowAwarenessSchema.success(eid, device_id, "", "", StatusMapper.map_status_to_code(status), 2)
          # Broker.group(eid, awareness_response, awareness)
          {:noreply, %{state | force_stale: now}}
        else
          {:noreply, state}
        end
    end
  end

  # ----------------------
  # Termination handling
  # ----------------------
  @impl true
  def handle_cast({:send_terminate_signal_to_server, %{device_id: device_id, eid: eid}}, %{current_timer: current_timer} = state) do
    DeviceStorage.delete_device(device_id, eid)
    if Storage.DeviceStateCchange.remaining_active_devices?(eid) do
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

    case type do
      1 -> 
        
        DeviceStorage.update_device_status(from_device_id, from_eid, "AWARENESS", StatusMapper.status_name(type))
        # GenServer.cast(self(), {:fetch_batch_chat, from_eid, from_device_id} )
        # GenServer.cast(self(), {:fetch_batch_notification, from_eid, from_device_id} )
        Broker.group(from_eid, data, awareness)
      
      s when s in 2..5 ->

        # User Awareness
        # 1..5 →  OFFLINE, AWAY, BUSY, DND
        # Send to all subscribers (group awareness)
        # Also send chat/notification messages to sender
        # send_group_awareness(from, to, s)
        # send_chat_notification(from, to, s)
        DeviceStorage.update_device_status(from_device_id, from_eid, "AWARENESS", StatusMapper.status_name(type))
        Broker.group(from_eid, data, awareness)
 
      s when s in 6..11 ->
        # System Awareness
        # 6..11 → TYPING, RECORDING
        # Send pair-to-pair awareness only
        # send_pair_awareness(from, to, s)
        # send_chat_notification(from, to, s)
        DeviceStorage.update_device_status(from_device_id, from_eid, "AWARENESS", StatusMapper.status_name(1))
        # GenServer.cast(self(), {:fetch_batch_chat, from_eid, from_device_id} )
        Broker.peer(to_eid, data, awareness)
        
      other ->
        
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:awareness_update, awareness_msg}, %{eid: eid} = state) do
    msg = Bimip.MessageScheme.decode(awareness_msg)

    case msg.payload do
      {:awareness, %Bimip.Awareness{} = awareness_msg_response} ->
        
        case awareness_msg_response.status do
          s when s in 1..2 ->
            Storage.Subscriber.update_subscriber(
              eid,
              awareness_msg_response.from.eid,
              StatusMapper.status_name(s)
            )

          s when s in 6..11 ->
            Storage.Subscriber.update_subscriber(
              eid,
              awareness_msg_response.from.eid,
              "ONLINE"
            )

          # ✅ Catch-all for unexpected or new status codes
          other ->
        end

        AwarenessFanOut.awareness(awareness_msg, eid)
        {:noreply, state}
      {:error, reason} ->
        Logger.error("Failed to decode awareness payload: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  # ----------------------
  # Message writing
  # ----------------------
  @doc """
  Handles logging a new message payload by delegating the write to the
  BimipLog.UserWriter GenServer, which handles serialization and durability.

  Note: The Master process must call BimipLog.write/5, which is already designed
  to handle the necessary GenServer delegation to ensure concurrency safety.
  """
  def handle_cast({:log_user_message, partition_id, from, to, payload}, %{eid: eid} = state) do
    # synchronous effect still executed in the genserver process
    case BimipLog.write(eid, partition_id, from, to, payload) do
      {:ok, offset} ->
        Logger.info("[LOG] eid=#{eid} partition=#{partition_id} offset=#{offset} from=#{from} to=#{to}")
      {:error, reason} ->
        Logger.error("[LOG] failed write eid=#{eid} partition=#{partition_id} reason=#{inspect(reason)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:fetch_batch_chat, eid, devices}, state) do
    case BimipLog.fetch(eid, devices, 1) do
      {_, _, {:ok, %{messages: messages}}} when is_list(messages) ->
        Enum.each(messages, &IO.inspect(&1))

      {_, _, {:ok, %{messages: []}}} ->
        # no messages to process
        :ok

      other ->
        IO.puts("Unexpected response: #{inspect(other)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:fetch_batch_notification, eid, devices}, state) do
    case BimipLog.fetch(eid, devices, 2) do
      {_, _, {:ok, %{messages: messages}}} when is_list(messages) ->
        Enum.each(messages, &IO.inspect(&1))

      {_, _, {:ok, %{messages: []}}} ->
        # no messages to process
        :ok

      other ->
        IO.puts("Unexpected response: #{inspect(other)}")
    end

    {:noreply, state}
  end


end
