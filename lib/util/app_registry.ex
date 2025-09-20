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

  def schedule_ping_registry(_device_id, interval) do
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

  def send_terminate_signal_to_server({device_id, eid}) do
    case Horde.Registry.lookup(EidRegistry, eid) do
    [{pid, _}] ->
      GenServer.cast(pid, {:send_terminate_signal_to_server, %{device_id: device_id, eid: eid}})
      :ok
    [] ->
      Logger.warning("2 No registry entry for #{device_id}, cannot maybe_start_mother")
      :error
    end
  end

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


end