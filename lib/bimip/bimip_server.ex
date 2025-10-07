defmodule Bimip.Service.Master do
  use GenServer
  alias Bimip.Registry
  alias Bimip.Device.Supervisor
  alias Storage.DeviceStorage
  alias Bimip.SubscriberPresence
  alias Storage.DeviceStateChange
  alias Settings.ServerState
  alias Route.SelfFanOut

  require Logger

  @stale_threshold_seconds ServerState.stale_threshold_seconds()

  def start_link(eid) do
    GenServer.start(__MODULE__, eid, name: Registry.via_monitor_registry(eid))
  end

  @impl true
  def init(eid) do
    SubscriberPresence.presence_subscriber(eid)

    awareness =
      case DeviceStorage.fetch_user_awareness(eid) do
        {:ok, level} ->
          level

        {:error, :not_found} ->
          default_awareness = 2
          DeviceStorage.insert_awareness(eid, default_awareness)
          default_awareness

        {:error, reason} ->
          Logger.error("Error fetching awareness for #{eid}: #{inspect(reason)}")
          2
      end

    {:ok,
      %{
        eid: eid,
        awareness: awareness,
        current_timer: nil,
        force_stale: DateTime.utc_now(),
        devices: %{}
      }}
  end

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
      awareness_intention: state.awareness,
      inserted_at: now
    }

    SubscriberPresence.broadcast_awareness(eid, state.awareness, :online)

    case DeviceStorage.register_device_session(device_id, eid, device_payload) do
      {:ok, awareness} ->
        case Storage.DeviceStateChange.track_state_change(eid) do
          {:changed, user_status, _online_devices} ->
            Logger.info("""
            [LOGIN] 2 hdjsdacsdacadgs changed eid=#{eid} device_id=#{device_id} awareness=#{awareness}
            → user_status CHANGED to #{user_status}
            """)

            
            {:noreply, state}

          {:unchanged, user_status, _online_devices} ->
            Logger.debug("""
            [LOGIN] 3 hdjsdacsdacadgs changed eid=#{eid} device_id=#{device_id} awareness=#{awareness}
            → user_status remains #{user_status}
            """)
            {:noreply, state}
        end

      {:error, reason} ->
        Logger.error("""
        [LOGIN-FAILED] eid=#{eid} device_id=#{device_id}
        → failed to save device, reason=#{inspect(reason)}
        """)
        {:noreply, state}
    end
  end

  def handle_cast({:client_send_pong, {eid, device_id, status}}, %{force_stale: force_stale, awareness: awareness} = state) do
    
    IO.inspect({"Terminate ", device_id})
    now = DateTime.utc_now()
    DeviceStorage.update_device_status(device_id, eid, "PONG", status)

    case Storage.DeviceStateChange.track_state_change(eid) do
      {:changed, user_status, _online_devices} ->
        IO.inspect({"state change here is my 3", "changed", device_id})
        SubscriberPresence.broadcast_awareness(eid, awareness, user_status)
        {:noreply, %{state | force_stale: now}}

      {:unchanged, user_status, _online_devices} ->

        IO.inspect({"state change here is my 4", "changed", device_id})
        idle_too_long? = DateTime.diff(now, force_stale) >= @stale_threshold_seconds

        if idle_too_long? do
          SubscriberPresence.broadcast_awareness(eid, awareness, user_status)
          {:noreply, %{state | force_stale: now}}
        else
          {:noreply, state}
        end
    end
  end

  @impl true
  def handle_cast({:send_terminate_signal_to_server, %{device_id: device_id, eid: eid}},
                  %{awareness: awareness, current_timer: current_timer} = state) do

    IO.inspect({"Terminate signal", device_id})
    DeviceStorage.delete_device(device_id, eid)

    case DeviceStateChange.remaining_active_devices?(eid) do
      true ->
        Logger.warning("Active devices remain for #{eid}. Cancelling termination.")
        DeviceStateChange.cancel_termination_if_any_device_are_online(current_timer)
        {:noreply, state}

      false ->
        SubscriberPresence.broadcast_awareness(eid, awareness, :offline)
        DeviceStateChange.schedule_termination_if_all_offline(state)
        {:noreply, state}
    end
  end

  def handle_info(:terminate, %{eid: eid, awareness: awareness, current_timer: current_timer} = state) do
    case DeviceStateChange.remaining_active_devices?(eid) do
      true ->
        Logger.warning("Devices still active for #{eid} #{current_timer}. Not terminating.")
        {:noreply, state}

      false ->
        Logger.warning("No active devices for #{eid}. Process Terminated.")
        {:stop, :normal, state}
    end
  end

  @impl true
  def handle_info({:awareness_update, %Strucs.Awareness{} = awareness}, %{eid: eid} = state) do
    SelfFanOut.awareness(awareness, eid)
    {:noreply, state}
  end

  @impl true
  def handle_info(:fetch_batch, state) do
    {:noreply, state}
  end

  defp schedule_fetch(state) do
    if DeviceStateChange.remaining_active_devices?(state.eid) do
      Process.send_after(self(), :fetch_batch, 100)
    else
      DeviceStateChange.schedule_termination_if_all_offline(state)
    end
  end
end
