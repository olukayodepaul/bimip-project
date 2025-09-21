defmodule Bimip.Service.Master do
  #bimip

  use GenServer
  alias Bimip.Registry
  alias Bimip.Device.Supervisor
  alias Storage.DeviceStorage
  alias Bimip.SubscriberPresence
  alias Storage.DeviceStateChange
  alias Settings.ServerState
  

  require Logger

  @stale_threshold_seconds ServerState.stale_threshold_seconds()

  def start_link(eid) do
    GenServer.start(__MODULE__, eid, name: Registry.via_monitor_registry(eid))
  end

  @impl true
  def init(eid) do
    SubscriberPresence.presence_subscriber(eid)
    {:ok, %{eid: eid, current_timer: nil, force_stale: DateTime.utc_now(), awareness: nil, devices: %{}}}
  end

  # Device session start
  def start_device(eid, {eid, device_id, ws_pid}) do
    GenServer.call(Registry.via_monitor_registry(eid), {:start_device, {eid, device_id, ws_pid}})
  end

  @impl true
  def handle_call({:start_device, {eid, device_id, ws_pid}}, _from, state) do
    case Supervisor.start_session({eid, device_id, ws_pid}) do
      {:ok, pid} ->
        devices = Map.put(state.devices, device_id, pid)
        {:reply, {:ok, pid}, %{state | devices: devices}}
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end
  
  @impl true
  def handle_cast({:persist_device_state, %{device_id: device_id, eid: eid, ws_pid: ws_pid}}, state) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    device_payload = %{
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
        awareness_intention: 2,
        inserted_at: now,
    }
  
    case DeviceStorage.save(device_id, eid, device_payload) do
      {:ok, awareness} ->
        case Storage.DeviceStateChange.track_state_change(eid) do
          {:changed, user_status, _online_devices} ->
            Logger.info(""" 
            [LOGIN] changed eid=#{eid} device_id=#{device_id} awareness=#{awareness}
            → user_status CHANGED to #{user_status}
            """)
            
            SubscriberPresence.broadcast_awareness(eid, awareness, user_status)
            DeviceStateChange.cancel_termination_if_all_offline(state, awareness)

          {:unchanged, user_status, _online_devices} ->

            Logger.debug(""" 
            [LOGIN] unchanged eid=#{eid} device_id=#{device_id} awareness=#{awareness}
            → user_status remains #{user_status}
            """)
            DeviceStateChange.cancel_termination_if_all_offline(state, awareness)

        end

      {:error, reason} ->
        Logger.error("""
        [LOGIN-FAILED] eid=#{eid} device_id=#{device_id}
        → failed to save device, reason=#{inspect(reason)}
        """)
        # terminate_user(device_id, eid)
        {:noreply, state}
    end
    
  end

  # @impl true
  def handle_cast({:client_send_pong, {eid, device_id, status}},  %{ force_stale: force_stale, awareness: awareness } = state) do
    
    now = DateTime.utc_now()
    DeviceStorage.update_device_status(device_id, eid, "PONG")
    
    case Storage.DeviceStateChange.track_state_change(eid) do
      {:changed, user_status, _online_devices} ->

        SubscriberPresence.broadcast_awareness(eid, awareness, user_status)
        {:noreply, %{state | force_stale: now}}

      {:unchanged, user_status, _online_devices} ->

        idle_too_long? = DateTime.diff(now, force_stale) >= @stale_threshold_seconds

        if idle_too_long? do
          IO.inspect({eid, "PONG 3", :unchanged})
          SubscriberPresence.broadcast_awareness(eid, awareness, user_status)
          {:noreply, %{state | force_stale: now}}
        else
          {:noreply, state}
        end
    end
  end

  @impl true
  def handle_cast({:send_terminate_signal_to_server, %{device_id: device_id, eid: eid}}, %{awareness: awareness} = state) do
      # remove the device
      DeviceStorage.delete_device(device_id, eid)
      case DeviceStateChange.remaining_active_devices?(eid) do
      true ->
        # At least one device is still active
        Logger.warning("2 No active devices for #{eid}. Terminating process.")
        DeviceStateChange.cancel_termination_if_all_offline(state, awareness)
      false ->
        # No active devices → safe to terminate
        Logger.warning("No active devices for #{eid}. Terminating process.")
        DeviceStateChange.schedule_termination_if_all_offline(state)
      end
  end

  def handle_info(:terminate, %{eid: eid, awareness: awareness} = state) do
    case DeviceStateChange.remaining_active_devices?(eid) do
      true ->
        # At least one device is still active
        Logger.info("Devices still active for #{eid}. Not terminating.")
        {:noreply, %{state | current_timer: nil}}

      false ->
        # No active devices → safe to terminate
        Logger.warning("No active devices for #{eid}. Terminating process.")
        SubscriberPresence.broadcast_awareness(eid, awareness, :offline)
        {:stop, :normal, state}
      end
  end

  #still need to make adjustment to this
  @impl true
  def handle_info({:awareness_update, %Strucs.Awareness{} = awareness}, %{eid: eid} = state) do
    IO.inspect({ awareness})
    {:noreply, state}
  end

  @impl true
  def handle_info(:fetch_batch, state) do
    # Only fetch if devices are active
    if DeviceStateChange.remaining_active_devices?(state.eid) do
      # Get latest offsets from queue_index
      {last_offset, max_id} = QueueStorage.fetch_queue_index(state.eid, state.channel)

      # Fetch next batch starting from last_offset + 1
      batch = QueueStorage.fetch(state.eid, state.channel, state.batch_size, last_offset + 1)

      if batch != [] do
        # Fan-out messages to devices
        Logger.info("Fetched batch: #{inspect(batch)} for active devices")
        # TODO: push batch to online devices

        new_last_offset = last_offset + length(batch)
        QueueStorage.update_queue_index(state.eid, state.channel, new_last_offset, max_id)

        # Schedule next batch fetch after a short delay
        state = schedule_fetch(state)
        {:noreply, state}
      else
        # No more messages → stop fan-out
        Logger.info("No more messages to fetch for #{state.eid}")
        {:noreply, %{state | fetch_timer: nil}}
      end
    else
      # No devices online → terminate process
      Logger.warning("No active devices for #{state.eid}. Terminating fan relay.")
      #schdule termination
      {:noreply, state}
    end
  end

  defp schedule_fetch(state) do
    if DeviceStateChange.remaining_active_devices?(state.eid) do
      fetch_timer = Process.send_after(self(), :fetch_batch, 100)
      %{state | fetch_timer: fetch_timer}
    else
      #schdule termination
      {:noreply, state}
    end
  end

end