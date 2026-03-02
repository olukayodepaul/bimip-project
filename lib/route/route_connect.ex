defmodule Route.Connect do

  require Logger
  @deviceid_registry DeviceIdRegistry
  @eid_registry EidRegistry


  @doc """
  Handles cleanup and logging when a WebSocket terminates.
  """
  def handle_terminate(reason, %{eid: eid, device_id: device_id}) do
    Logger.info("WebSocket terminated for #{device_id}, reason: #{inspect(reason)}")
    case Horde.Registry.lookup(DeviceIdRegistry, device_id) do
      [{pid, _}] ->
        GenServer.cast(pid, {:send_terminate_signal_to_client, {device_id, eid}})
      [] ->
        Logger.warning("No registry entry for #{device_id}, cannot maybe_start_mother")
    end
    Logger.warning("No Application.Processor found for #{device_id} during websocket terminate")
    log_reason(reason, device_id)
    :ok
  end


  def handle_terminate(reason, state) do
    IO.inspect("GenServer Terminated Pass 2B")
    Logger.info("WebSocket terminated with reason: #{inspect(reason)}")
    log_reason(reason, extract_registry_id(state))
    :ok
  end

  ## --- Private helpers ---

  defp log_reason(:normal, device_id) do
    Logger.info("Clean WebSocket close for #{inspect(device_id)}")
  end

  defp log_reason({:remote, :closed}, device_id) do
    Logger.warning("Remote peer closed TCP connection for #{inspect(device_id)}")
  end

  defp log_reason({:shutdown, _} = shutdown_reason, device_id) do
    Logger.warning("WebSocket shutdown for #{inspect(device_id)}: #{inspect(shutdown_reason)}")
  end

  defp log_reason({:tcp_closed, _} = tcp_close_reason, device_id) do
    Logger.warning("TCP connection closed for #{inspect(device_id)}: #{inspect(tcp_close_reason)}")
  end

  defp log_reason(other, device_id) do
    Logger.error("Unexpected terminate reason for #{inspect(device_id)}: #{inspect(other)}")
  end

  defp extract_registry_id({:new, {device_id, _, _, _}}), do: device_id
  defp extract_registry_id(_), do: :unknown

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
