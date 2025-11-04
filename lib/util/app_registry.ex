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

  def route_same_ping(eid, device_id, data) do
    case Horde.Registry.lookup(DeviceIdRegistry, device_id) do
      [{pid, _}] ->
        GenServer.cast(pid, {:logout, eid, device_id, data})
        :ok
      [] ->
        :error
    end
  end

  def route_others_ping(eid, device_id, data) do
    case Horde.Registry.lookup(DeviceIdRegistry, device_id) do
      [{pid, _}] ->
        GenServer.cast(pid, {:ping_pong, eid, device_id, data})
        :ok
      [] ->
        :error
    end
  end

  def route_awareness_visibility_to_client(eid, device_id, data) do
    case Horde.Registry.lookup(DeviceIdRegistry, device_id) do
      [{pid, _}] ->
        GenServer.cast(pid, {:client_awareness_visibility, eid, device_id, data})
        :ok
      [] ->
        :error
    end
  end

  def route_message_to_client(eid, device_id, data) do
    case Horde.Registry.lookup(DeviceIdRegistry, device_id) do
      [{pid, _}] ->
        GenServer.cast(pid, {:client_message, eid, device_id, data})
        :ok
      [] ->
        :error
    end
  end

  def route_message_to_server(%{from: %{eid: eid, connection_resource_id: device_id}} = post) do
    case Horde.Registry.lookup(EidRegistry, eid) do
      [{pid, _}] -> 
        GenServer.cast(pid, {:route_message, eid, device_id, post})
      [] -> 
        :error
    end
  end

  def route_ping_pong_to_server(eid, device_id) do
    case Horde.Registry.lookup(EidRegistry, eid) do
      [{pid, _}] -> 
        GenServer.cast(pid, {:route_ping_pong, eid, device_id})
      [] -> :error
    end
  end

  # Stick to this
  @spec route_awareness_visibility_to_server(map()) :: :ok | :error
  def route_awareness_visibility_to_server(%{eid: eid} = visibility) when is_binary(eid) do
    case Horde.Registry.lookup(EidRegistry, eid) do
      [{pid, _value}] when is_pid(pid) ->
        GenServer.cast(pid, {:route_awareness_visibility, visibility})
        :ok
      [] ->
        IO.warn("No registered server found for eid #{eid}")
        :error
    end
  end

  def receive_awareness_from_server(device_id, eid, binary) do
    case Horde.Registry.lookup(DeviceIdRegistry, device_id) do
      [{pid, _}] ->
        GenServer.cast(pid, {:receive_awareness_from_server, {eid, device_id, binary}})
        :ok
      [] ->
        :error
    end
  end

  def route_awareness_to_client(eid, device_id, data) do
    case Horde.Registry.lookup(DeviceIdRegistry, device_id) do
      [{pid, _}] ->
        GenServer.cast(pid, {:route_awareness, eid, device_id, data})
        :ok
      [] ->
        :error
    end
  end

  def route_awareness_to_server(from_eid, from_device_id, to_eid, to_device_id, type, data) do
    case Horde.Registry.lookup(EidRegistry, from_eid) do
      [{pid, _}] ->
        GenServer.cast(pid, {:route_awareness, from_eid, from_device_id, to_eid, to_device_id, type, data})
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

  def register_device_in_server({device_id, eid, exp, ws_pid}) do
    case Horde.Registry.lookup(EidRegistry, eid) do
      [{pid, _}] ->
        GenServer.cast(pid, {:start_device, {eid, device_id, exp, ws_pid}})
        :ok
      []->
        Logger.warning("No registry entry for #{device_id}, cannot maybe_start_mother")
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