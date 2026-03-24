defmodule Route.Connect do

  require Logger
  @deviceid_registry DeviceIdRegistry
  @eid_registry EidRegistry


  def client_server_inbound({identifier, registry_id, resouce_finder, payload}, roster \\ %{}) do
    case identifier do
      :eid ->
        consolidated_route({@eid_registry, registry_id, resouce_finder, payload}, roster)
      :device_id ->
        consolidated_route({@deviceid_registry, registry_id, resouce_finder, payload}, roster)
    end
  end

  defp consolidated_route({lookup_via_registry, registry_id, resouce_finder, payload}, roster \\ %{}) do
    case Horde.Registry.lookup(lookup_via_registry, registry_id) do
      [{pid, _}] ->
        GenServer.cast(pid, {resouce_finder, payload})
        :ok
      [] ->

        # if resouce_finder == :message_transmiter do
        #   [{eid_domain, roster_details}] = Map.to_list(roster)
        #   Bimip.Push.Dispatcher.send_wake_signal(roster_details, eid_domain)
        # end

        :error
    end
  end

  # version two
  # def client_server_inbound({identifier, registry_id, resource_finder, payload}, eid \\ nil) do
  #   group_name = case identifier do
  #     # Pattern 1: Uses registry_id (which is the EID)
  #     :eid ->
  #       "eid_#{registry_id}"

  #     # Pattern 2: Uses registry_id (device_id) + the provided EID
  #     :device_id ->
  #       "device_#{registry_id}_#{eid}"
  #   end

  #   # Perform O(1) cluster-wide lookup and forward
  #   case :pg.get_members(@pg_scope, group_name) do
  #     [pid | _] ->
  #       # The BEAM handles the 'Forward' hop across machines via the PID
  #       GenServer.cast(pid, {resource_finder, payload})
  #       :ok
  #     [] ->
  #       Logger.warning("No :pg member found for #{group_name}. Signal dropped.")
  #       :error
  #   end
  # end

  def start_device({device_id, eid, exp, ws_pid, uupid}) do
    case Horde.Registry.lookup(EidRegistry, eid) do
      [{pid, _}] ->
        GenServer.cast(pid, {:start_device, {eid, device_id, exp, ws_pid, uupid}})
        :ok
      []->
        Logger.warning("No registry entry for #{device_id}, cannot maybe_start_mother")
        {:error}
    end
  end

  def schedule_ping_registry(_device_id, interval) do
    Process.send_after(self(), {:send_ping, interval}, interval)
  end


end
