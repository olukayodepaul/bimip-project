defmodule Bimip.Service.Master do
    #bimip

  use GenServer
  alias Bimip.Registry
  alias Bimip.Device.Supervisor
  alias Storage.DeviceStorage
  require Logger

  def start_link(eid) do
    GenServer.start(__MODULE__, eid, name: Registry.via_monitor_registry(eid))
  end

  @impl true
  def init(eid) do
    {:ok, %{eid: eid, current_timer: nil, force_stale: DateTime.utc_now(),  devices: %{}}}
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
        inserted_at: now
    }
    DeviceStorage.save(device_id, eid, device_payload)

    case Storage.DeviceStateChange.track_state_change(eid) do
    {:changed, user_status, _online_devices} ->
      Logger.warning(":changed Reach by server login 2 #{device_id} - user_status: #{user_status}")

    {:unchanged, user_status, _online_devices} ->
      Logger.warning(":unchanged Reach by server login 3 #{device_id} - user_status: #{user_status}")
    end

    {:noreply, state}
  end

  # @impl true
  def handle_cast({:client_send_pong, {eid, device_id, status}},  state) do
    {:noreply, state}
  end


end