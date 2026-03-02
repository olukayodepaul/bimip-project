defmodule Bimip.Socket do
  # bimip

  @behaviour :cowboy_websocket
  @compose_route_id 4
  @message_route_id 6
  @ping_route_id 3
  @commit_offset_route_id 7
  @wareness_id 2


  alias Bimip.Auth.TokenVerifier
  alias Util.{ConnectionsHelper, TokenRevoked}
  alias Supervisor.Server
  alias Route.Connect
  require Logger

  def init(req, _state) do
    token = :cowboy_req.header("token", req)
    case Bimip.Auth.TokenVerifier.verify_from_header(token) do
      {:ok, claims} ->
        ConnectionsHelper.accept(req, claims)
      {:error, reason} ->
        ConnectionsHelper.reject(req, reason)
      unexpected ->
        ConnectionsHelper.reject(req,"1011 Internal Server Error")
    end
  end

  def websocket_init(%{eid: eid, device_id: device_id, exp: exp, uupid: uupid, subc: subc} = state) do
    state_with_ws = Map.put(state, :ws_pid, self())
    case Horde.Registry.lookup(EidRegistry, eid) do
      [{_pid, _value}] ->
        # pid
        Connect.start_device({device_id, eid, exp, self(), uupid, subc})
      [] ->
        Server.start_mother(state_with_ws)
        Logger.error("Mother process for #{eid} not found in Registry")
        nil
    end
    {:ok, state}
  end

  def websocket_info({:binary, binary}, state) do
    {:reply, {:binary, binary}, state}
  end

  def websocket_info({:binaries, binaries}, state) when is_list(binaries) do
    Logger.info("Sending batch awareness frames to client")
    frames = Enum.map(binaries, fn bin -> {:binary, bin} end)
    {:reply, frames, state}
  end

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

  defp dispatch_map do
    %{
      2 => &handle_awareness/2,
      3 => &handle_ping/2,
      4 => &handle_compose/2,
      6 => &handle_message/2,
      7 => &handle_commit_offset/2,
    }
  end

  defp default_handler(%{eid: eid, device_id: device_id} = state, data) do
    Logger.error("Unknown route received for device #{device_id}, eid #{eid}")
    {:ok, state}
  end

  def websocket_info(:send_ping, state) do
    {:reply, :ping, state}
  end

  def websocket_handle(:pong,  state) do
    IO.inspect(2)
    case Connect.client_server_inbound({:device_id, state.device_id, :pong, DateTime.utc_now()}) do
      :ok ->
        {:ok, state}
      :error ->
        :ok
    end
  end

  defp handle_ping(state, data) do
    case Connect.client_server_inbound({:device_id, state.device_id, :ping, data}) do
      :ok ->
        {:ok, state}
      :error ->
        reason = "Field '' →  Invalid ping 500"
        throws = ThrowProtocolErrorSchema.build(@ping_route_id, reason, Until.UniPosTime.response_time())
        send(self(), {:binary, throws})
    end
  end

  defp handle_message(state, data) do
    case Connect.client_server_inbound({:device_id, state.device_id, :message, data}) do
      :ok ->
        {:ok, state}
      :error ->
        reason = "Field '' → #{} Invalid message 500"
        throws = ThrowProtocolErrorSchema.build( @message_route_id, reason, Until.UniPosTime.response_time())
        send(self(), {:binary, throws})
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

  # defp handle_logout(state, data) do
  #   IO.inspect("log_out_route")
  #   case RegistryHub.route_same_ping(state.eid, state.device_id, data) do
  #     :ok -> {:ok, state}
  #     :error ->

  #     error_msg =
  #     ThrowErrorScheme.error(503, "Service temporarily unavailable", 10)

  #     send(self(), {:binary, error_msg})
  #     {:ok, state}
  #   end
  # end

  def websocket_info(:terminate_socket, state) do
    {:stop, state}
  end

  # -----------------------
  # Only decode the route field for fast dispatch
  # -----------------------
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

  # terminate, send offline message.......
  def terminate(reason, _req, state) do
    Connect.handle_terminate(reason, state)
    :ok
  end
end
