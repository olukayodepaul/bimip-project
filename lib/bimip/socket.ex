defmodule Bimip.Socket do
    #bimip

  @behaviour :cowboy_websocket
  alias Bimip.Auth.TokenVerifier
  alias Util.{ConnectionsHelper, TokenRevoked}
  alias Bimip.Supervisor.Orchestrator
  alias Bimip.Service.Master
  alias Util.Network.AdaptivePingPong
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

    def websocket_init(%{ eid: eid, device_id: device_id} = state) do
      Orchestrator.start_mother(eid)
      Master.start_device(eid, {eid, device_id, self()})
      {:ok, state}
    end

    def websocket_info(:send_ping, state) do
      {:reply, :ping, state}
    end

    def websocket_handle(:pong, %{ eid: _eid, device_id: device_id} = state) do
      AdaptivePingPong.handle_pong_from_network(device_id, DateTime.utc_now())
      {:ok, state}
    end

    #terminate, send offline message.......
    def terminate(_reason, _req, _state) do
      :ok
    end


end