defmodule Bimip.Socket do
  # bimip

  @behaviour :cowboy_websocket
  @compose_route_id 4
  @message_route_id 6
  @ping_route_id 3
  @commit_offset_route_id 7


  alias Bimip.Auth.TokenVerifier
  alias Util.{ConnectionsHelper, TokenRevoked}
  alias Supervisor.Server
  alias Route.Connect
  alias Util.Network.AdaptivePingPong
  alias ThrowErrorScheme
  require Logger

  def init(req, _state) do
    case TokenVerifier.extract_token(:cowboy_req.header("token", req)) do
      {:ok, token} ->
        case TokenVerifier.verify_token(token) do
          {:error, :token_invoked} ->
            ConnectionsHelper.reject(req, :token_invoked)

          {:reason, :invalid_token} ->
            ConnectionsHelper.reject(req, :invalid_token)

          {:ok, claims} ->
            case TokenRevoked.revoked?(claims["jti"]) do
              false ->
                ConnectionsHelper.accept(req, claims)

              true ->
                ConnectionsHelper.reject(req, "Token revoked")
            end
        end

      {:error, :invalid_token} ->
        ConnectionsHelper.reject(req, :invalid_token)
    end
  end

  def websocket_init(%{eid: eid, device_id: device_id, exp: exp, uupid: uupid} = state) do
    state_with_ws = Map.put(state, :ws_pid, self())

    case Horde.Registry.lookup(EidRegistry, eid) do
      [{_pid, _value}] ->
        # pid
        Connect.start_device({device_id, eid, exp, self(), uupid})
      [] ->
        Server.start_mother(state_with_ws)
        Logger.error("Mother process for #{eid} not found in Registry")
        nil
    end
    {:ok, state}
  end


  # client receiving awareness status from server
  # create route binary dont
  # send sunscriber request and subscriber reponse (Modify online queue) No file system yet only version two

  def websocket_info({:binary, binary}, state) do
    {:reply, {:binary, binary}, state}
  end

  def websocket_info({:binaries, binaries}, state) when is_list(binaries) do
    # send(self(), {:binaries, [bin1, bin2, bin3]})
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



  defp handle_awareness(state, data) do
    case Connect.route_awareness_to_client(state.eid, state.device_id, data) do
      :ok ->
        {:ok, state}

      :error ->
        error_msg =
          ThrowErrorScheme.error(503, "Service temporarily unavailable", 2)

        send(self(), {:binary, error_msg})
        {:ok, state}
    end
  end











  def websocket_info(:send_ping, state) do
    {:reply, :ping, state}
  end

  def websocket_handle(:pong,  state) do
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
