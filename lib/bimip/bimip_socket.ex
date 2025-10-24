defmodule Bimip.Socket do
    #bimip

  @behaviour :cowboy_websocket
  alias Bimip.Auth.TokenVerifier
  alias Util.{ConnectionsHelper, TokenRevoked}
  alias Bimip.Supervisor.Orchestrator
  alias App.RegistryHub
  alias Bimip.Service.Master
  alias Util.Network.AdaptivePingPong
  alias ThrowErrorScheme
  require Logger

  def init(req, _state) do
      case TokenVerifier.extract_token(:cowboy_req.header("token", req)) do
      {:ok, token} ->  
        case TokenVerifier.verify_token(token) do
          {:error, :token_invoked} -> ConnectionsHelper.reject(req, :token_invoked)
          {:reason, :invalid_token} -> ConnectionsHelper.reject(req, :invalid_token)
          {:ok, claims} -> 
            case TokenRevoked.revoked?(claims["jti"]) do
              false -> 
                ConnectionsHelper.accept(req, claims)
              true ->
                ConnectionsHelper.reject(req,"Token revoked")
            end 
        end
      {:error, :invalid_token} ->  ConnectionsHelper.reject(req, :invalid_token)
      end
    end

    def websocket_init(%{eid: eid, device_id: device_id, exp: exp} = state) do
      state_with_ws = Map.put(state, :ws_pid, self())

        case Horde.Registry.lookup(EidRegistry, eid) do
          [{pid, _value}] -> pid
              RegistryHub.register_device_in_server({device_id, eid, exp, self()})
          [] ->
            Orchestrator.start_mother(state_with_ws)
            Logger.error("Mother process for #{eid} not found in Registry")
            nil
          end

      {:ok, state}
    end


    def websocket_info(:send_ping, state) do
      {:reply, :ping, state}
    end

    # client receiving awareness status from server
    # create route binary dont
    # send sunscriber request and subscriber reponse (Modify online queue) No file system yet only version two
    
    def websocket_info({:binary, binary}, state) do
      {:reply, {:binary, binary}, state}
    end

    def websocket_info({:binaries, binaries}, state) when is_list(binaries) do
      #send(self(), {:binaries, [bin1, bin2, bin3]})
      Logger.info("Sending batch awareness frames to client")
      frames = Enum.map(binaries, fn bin -> {:binary, bin} end)
      {:reply, frames, state}
    end

    def websocket_handle({:binary, data},  state) do

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
        3 => &handle_ping_pong/2,
        14 => &handle_logout/2
      }
    end

    def websocket_handle(:pong, %{ eid: _eid, device_id: device_id} = state) do
      AdaptivePingPong.handle_pong_from_network(device_id, DateTime.utc_now())
      {:ok, state}
    end

    defp default_handler(%{ eid: eid, device_id: device_id} = state, data) do
      Logger.error("Unknown route received for device #{device_id}, eid #{eid}")
      {:ok, state}
    end

    defp handle_awareness(state, data) do
      case RegistryHub.route_awareness_to_client(state.eid, state.device_id, data) do
        :ok -> 
          {:ok, state}
        :error ->
          error_msg =
          ThrowErrorScheme.error(503, "Service temporarily unavailable", 2)
          send(self(), {:binary, error_msg})
          {:ok, state}
      end
    end

    defp handle_ping_pong(state, data) do
      case RegistryHub.route_others_ping(state.eid, state.device_id, data) do
        :ok -> {:ok, state}
        :error ->
        
        error_msg =
        ThrowErrorScheme.error(503, "Service temporarily unavailable", 10)

        send(self(), {:binary, error_msg})
        {:ok, state}
      end
    end

    defp handle_logout(state, data) do
      IO.inspect("log_out_route")
      case RegistryHub.route_same_ping(state.eid, state.device_id, data) do
        :ok -> {:ok, state}
        :error ->
        
        error_msg =
        ThrowErrorScheme.error(503, "Service temporarily unavailable", 10)

        send(self(), {:binary, error_msg})
        {:ok, state}
      end
    end

    def websocket_info(:terminate_socket, state) do
      {:stop, state}
    end

    # -----------------------
    # Only decode the route field for fast dispatch
    # -----------------------
    defp safe_decode_route(data) do
      try do
        with %Bimip.MessageScheme{route: route} <- Bimip.MessageScheme.decode(data) do
          {:ok, route}
        else
          _ -> {:error, :invalid_route}
        end
      rescue
        e -> {:error, e}
      end
    end

    #terminate, send offline message.......
    def terminate(reason, _req, state) do
      RegistryHub.handle_terminate(reason, state)
      :ok
    end


end