defmodule Bimip.Validators.PingPongValidator do
  alias Bimip.PingPong

  def validate_pingpong(%PingPong{} = msg) do
    cond do
      msg.from == nil or msg.from.eid in [nil, ""] ->
        {:error, error_detail(100, "Invalid 'from' identity", "from.eid")}

      msg.from.connection_resource_id in [nil, ""] ->
        {:error, error_detail(100, "Missing 'from.connection_resource_id'", "from.connection_resource_id")}

      msg.to == nil or msg.to.eid in [nil, ""] ->
        {:error, error_detail(100, "Invalid 'to' identity", "to.eid")}

      msg.to.connection_resource_id in [nil, ""] ->
        {:error, error_detail(100, "Missing 'to.connection_resource_id'", "to.connection_resource_id")}

      msg.resource not in [1, 2] ->
        {:error, error_detail(100, "Invalid 'resource' value (must be 1 or 2)", "resource")}

      msg.type not in [1, 2] ->
        {:error, error_detail(100, "Invalid 'type' value (must be 1=PING, 2=PONG)", "type")}

      msg.ping_time in [nil, 0] ->
        {:error, error_detail(100, "Missing or invalid 'ping_time'", "ping_time")}

      # msg.type == 2 and (msg.pong_time in [nil, 0]) ->
      #   {:error, error_detail(100, "Missing 'pong_time' for PONG message", "pong_time")}

      # msg.type == 2 and msg.pong_time < msg.ping_time ->
      #   {:error, error_detail(100, "Invalid timestamps: pong_time < ping_time", "pong_time")}

      true ->
        {:ok, normalize_pingpong(msg)}
    end
  end

  defp normalize_pingpong(%PingPong{type: 2, pong_time: 0} = msg),
    do: %{msg | pong_time: System.os_time(:millisecond)}

  defp normalize_pingpong(%PingPong{type: 1} = msg),
    do: %{msg | pong_time: 0}

  defp error_detail(code, message, field),
    do: %{code: code, description: message, field: field}
end
