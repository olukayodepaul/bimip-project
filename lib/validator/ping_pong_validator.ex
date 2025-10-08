defmodule Bimip.Validators.PingPongValidator do
  alias Bimip.PingPong

  def validate_pingpong(%PingPong{} = msg, eid, device_id) do
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

      msg.type != 1 ->
        {:error, error_detail(100, "Invalid 'type' (client may only send type=1 PING)", "type")}

      msg.ping_time in [nil, 0] ->
        {:error, error_detail(100, "Missing or invalid 'ping_time'", "ping_time")}

      msg.from.eid != eid or msg.from.connection_resource_id != device_id ->
        {:error, error_detail(401, "EID or device_id mismatch — unauthorized sender", "from")}

      true ->
        :ok
    end
  end

  defp error_detail(code, description, field),
    do: %{code: code, description: description, field: field}
end
