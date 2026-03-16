defmodule Bimip.Socket do
  # bimip

  @behaviour :cowboy_websocket
  @compose_route_id 4
  @message_route_id 6
  @ping_route_id 3
  @commit_offset_route_id 7
  @wareness_id 2
  @location_stream 9

  alias Bimip.Auth.TokenVerifier
  alias Util.{ConnectionsHelper, TokenRevoked}
  alias Supervisor.Server
  alias Route.Connect
  require Logger

  # ----------------------------------------------------------------------------
  # Cowboy Lifecycle: Init
  # ----------------------------------------------------------------------------

  def init(req, _state) do
    token = :cowboy_req.header("token", req)
    case Bimip.Auth.TokenVerifier.verify_from_header(token) do
      {:ok, claims} ->
        ConnectionsHelper.accept(req, claims)
      {:error, reason} ->
        ConnectionsHelper.reject(req, reason)
      _unexpected ->
        ConnectionsHelper.reject(req,"1011 Internal Server Error")
    end
  end

  def websocket_init(%{eid: eid, device_id: device_id, exp: exp, uupid: uupid, subc: subc} = state) do
    state_with_ws = Map.put(state, :ws_pid, self())
    case Horde.Registry.lookup(EidRegistry, eid) do
      [{_pid, _value}] ->
        Connect.start_device({device_id, eid, exp, self(), uupid, subc})
      [] ->
        Server.start_mother(state_with_ws)
        Logger.error("Mother process for #{eid} not found in Registry")
        nil
    end
    {:ok, state}
  end

  # ----------------------------------------------------------------------------
  # Cowboy Lifecycle: websocket_handle (Grouped)
  # ----------------------------------------------------------------------------

  def websocket_handle({:binary, data}, state) do
    if data == <<>> do
      Logger.error("Received empty binary")
      {:ok, state}
    else
      case safe_decode_route(data) do
        {:ok, route} ->
          dispatch_map()
          |> Map.get(route, &default_handler/2)
          |> then(fn handler -> handler.(state, data) end)

        {:error, reason} ->
          Logger.error("Failed to decode route: #{inspect(reason)}")
          {:ok, state}
      end
    end
  end

  def websocket_handle(:pong,  state) do
    case Connect.client_server_inbound({:device_id, state.device_id, :pong, DateTime.utc_now()}) do
      :ok ->
        {:ok, state}
      :error ->
        {:ok, state}
    end
  end

  def websocket_handle({:text, ""}, state), do: {:ok, state}
  def websocket_handle({:text, _message}, state), do: {:ok, state}
  def websocket_handle(_frame, state), do: {:ok, state}

  # ----------------------------------------------------------------------------
  # Cowboy Lifecycle: websocket_info (Grouped)
  # ----------------------------------------------------------------------------

  def websocket_info({:binary, binary}, state) do
    {:reply, {:binary, binary}, state}
  end

  def websocket_info({:binaries, binaries}, state) when is_list(binaries) do
    Logger.info("Sending batch awareness frames to client")
    frames = Enum.map(binaries, fn bin -> {:binary, bin} end)
    {:reply, frames, state}
  end

  def websocket_info(:send_ping, state) do
    {:reply, :ping, state}
  end

  def websocket_info(:terminate_socket, state) do
    {:stop, state}
  end

  # ----------------------------------------------------------------------------
  # Internal Logic & Handlers
  # ----------------------------------------------------------------------------

  defp dispatch_map do
    %{
      2 => &handle_awareness/2,
      3 => &handle_ping/2,
      4 => &handle_compose/2,
      6 => &handle_message/2,
      7 => &handle_commit_offset/2,
      9 => &handle_location_stream/2
    }
  end

  defp default_handler(%{eid: eid, device_id: device_id} = state, _data) do
    Logger.error("Unknown route received for device #{device_id}, eid #{eid}")
    {:ok, state}
  end

  defp handle_ping(state, data) do
    case Connect.client_server_inbound({:device_id, state.device_id, :ping, data}) do
      :ok ->
        {:ok, state}
      :error ->
        reason = "Field '' →  Invalid ping 500"
        throws = ThrowProtocolErrorSchema.build(@ping_route_id, reason, Until.UniPosTime.response_time())
        send(self(), {:binary, throws})
        {:ok, state}
    end
  end

  defp handle_message(state, data) do
    case Connect.client_server_inbound({:device_id, state.device_id, :message, data}) do
      :ok ->
        {:ok, state}
      :error ->
        reason = "Field '' →  Invalid message 500"
        throws = ThrowProtocolErrorSchema.build( @message_route_id, reason, Until.UniPosTime.response_time())
        send(self(), {:binary, throws})
        {:ok, state}
    end
  end

  defp handle_compose(state, data) do
    case Connect.client_server_inbound({:device_id, state.device_id, :compose, data}) do
      :ok ->
        {:ok, state}
      :error ->
        {:ok, state}
    end
  end

  defp handle_commit_offset(state, data) do
    case Connect.client_server_inbound({:device_id, state.device_id, :offset_commit, data}) do
      :ok ->
        {:ok, state}
      :error ->
        reason = "Field '' → Invalid commmit offset 500"
        throws = ThrowProtocolErrorSchema.build(@commit_offset_route_id, reason, Until.UniPosTime.response_time())
        send(self(), {:binary, throws})
        {:ok, state}
    end
  end

  defp handle_location_stream(state, data) do
    case Connect.client_server_inbound({:device_id, state.device_id, :location_stream, data}) do
      :ok ->
        {:ok, state}
      :error ->
        reason = "Field '' → Invalid location stream 500"
        throws = ThrowProtocolErrorSchema.build(@location_stream, reason, Until.UniPosTime.response_time())
        send(self(), {:binary, throws})
        {:ok, state}
    end
  end

  defp handle_awareness(state, data) do
    case Connect.client_server_inbound({:device_id, state.device_id, :awareness, data}) do
      :ok ->
        {:ok, state}
      :error ->
        reason = "Field '' → Invalid awareness 500"
        throws = ThrowProtocolErrorSchema.build(@wareness_id, reason, Until.UniPosTime.response_time())
        send(self(), {:binary, throws})
        {:ok, state}
    end
  end

  defp safe_decode_route(data) do
    try do
      with %Bimip.MessageScheme{route_id: route} <- Bimip.MessageScheme.decode(data) do
        {:ok, route}
      else
        _ -> {:error, :invalid_route}
      end
    rescue
      e -> {:error, e}
    end
  end

  # ----------------------------------------------------------------------------
  # Cowboy Lifecycle: Terminate
  # ----------------------------------------------------------------------------

  def terminate(reason, _req, state) do
    case reason do
      r when r in [:stop, :normal] ->
        Logger.info("[PingPong] SESSION EXPIRED: Device #{state.device_id} reached idle limit.")

      {:remote, 1000, _} ->
        Logger.info("[PingPong] DISCONNECT: Device #{state.device_id} closed the connection (Postman/Client).")

      {:shutdown, :closed} ->
        Logger.info("[PingPong] TCP CLOSED: Connection lost for device #{state.device_id}.")

      other_reason ->
        Logger.error("[PingPong] REAL CRASH: Device #{state.device_id} died unexpectedly. Reason: #{inspect(other_reason)}")
    end
    :ok
  end
end
