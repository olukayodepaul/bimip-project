defmodule App.RegistryHub do

  require Logger

  def send_pong_to_bimip_server_master(device_id, eid, status \\ "ONLINE") do
    case Horde.Registry.lookup(EidRegistry, eid) do
      [{pid, _}] ->
        GenServer.cast(pid, {:client_send_pong, {eid, device_id, status}})
        :ok
      [] ->
        :error
    end
  end

  def schedule_ping_registry(device_id, interval) do
    Process.send_after(self(), {:send_ping, interval}, interval)
  end

  def handle_pong_registry(device_id, sent_time) do
    case Horde.Registry.lookup(DeviceIdRegistry, device_id) do
      [{pid, _}] ->
        GenServer.cast(pid, {:received_pong, {device_id, sent_time}})
      [] ->
        :error
    end
  end

  def register_device_in_server({device_id, eid, ws_pid}) do
    case Horde.Registry.lookup(EidRegistry, eid) do
      [{pid, _}] ->
        GenServer.cast(pid, {:persist_device_state, %{device_id: device_id, eid: eid, ws_pid: ws_pid}})
        :ok
      []->
        Logger.warning("5 No registry entry for #{device_id}, cannot maybe_start_mother")
        {:error}
    end
  end


end