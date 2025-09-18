defmodule Util.ConnectionsHelper do
    #util

  require Logger
  alias Settings.Connections

  def reject(req, reason) do
    res = :cowboy_req.reply(401, response_header(req, 400, "dis_connected", reason), <<>>, req)
    {:ok, res, nil}
  end

  def accept(req, claims) do
    opts = %{idle_timeout: Connections.idle_timeout()}
    state = %{ eid: claims["eid"], device_id: claims["device_id"]}
    # state = {:new,{claims["eid"], claims["device_id"]}}
    {:cowboy_websocket, :cowboy_req.set_resp_headers(response_header(req, 101, "connected", "Successful"), req) , state ,opts}
  end

  defp response_header(req, tcp_level_status, connection, msg) do
    
    {{ip1, ip2, ip3, ip4}, port} = :cowboy_req.peer(req)
    conn_time = :erlang.system_time(:millisecond)
    user_agent = :cowboy_req.header("user-agent", req)
    host = :cowboy_req.host(req)

    %{
      "x-ip" => "#{ip1}.#{ip2}.#{ip3}.#{ip4}", 
      "x-port" => "#{port}", 
      "x-connection_time" => "#{conn_time}", 
      "x-user_agent" => "#{user_agent}", 
      "x-host" => "#{host}", 
      "x-connection" => connection,
      "x-status" => Integer.to_string(tcp_level_status),
      "x-message" => "#{msg}",
      "content-type" => "application/json"
    }

  end

end