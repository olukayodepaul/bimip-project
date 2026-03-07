defmodule Route.Connect do

  require Logger
  @deviceid_registry DeviceIdRegistry
  @eid_registry EidRegistry


  def client_server_inbound({identifier, registry_id, resouce_finder, payload}) do
    case identifier do
      :eid ->
        consolidated_route({@eid_registry, registry_id, resouce_finder, payload})
      :device_id ->
        consolidated_route({@deviceid_registry, registry_id, resouce_finder, payload})
    end
  end

  defp consolidated_route({lookup_via_registry, registry_id, resouce_finder, payload}) do
    case Horde.Registry.lookup(lookup_via_registry, registry_id) do
      [{pid, _}] ->
        GenServer.cast(pid, {resouce_finder, payload})
        :ok
      [] ->
        Logger.warning("No registry entry for, cannot maybe_start_mother")
        :error
    end
  end

  def start_device({device_id, eid, exp, ws_pid, uupid, subc}) do
    case Horde.Registry.lookup(EidRegistry, eid) do
      [{pid, _}] ->
        GenServer.cast(pid, {:start_device, {eid, device_id, exp, ws_pid, uupid, subc}})
        :ok
      []->
        Logger.warning("No registry entry for #{device_id}, cannot maybe_start_mother")
        {:error}
    end
  end

  def outbouce(device_id, binary) do
    case Horde.Registry.lookup(@deviceid_registry, device_id) do
      [{pid, _}] ->
        GenServer.cast(pid, {:outbouce,  binary})
        :ok
      [] ->
        :error
    end
  end

  def schedule_ping_registry(_device_id, interval) do
    Process.send_after(self(), {:send_ping, interval}, interval)
  end


end
