defmodule Bimip.Validators.PingPongValidator do
  @moduledoc """
  Validates PingPong messages according to the new schema:

  message PingPong {
      string id = 1;
      Identity to = 2;
      int32 type = 3;        // 1 = PING, 2 = PONG, 3 = ERROR
      int64 timestamp = 4;
      string details = 5;
  }
  """

  alias Bimip.PingPong

  @allowed_types [1, 2, 3]

  def validate_pingpong(%PingPong{} = msg, eid, device_id) do
    cond do
      msg.id in [nil, ""] ->
        {:error, error_detail(100, "Missing or invalid 'id'", "id")}

      msg.to == nil or msg.to.eid in [nil, ""] ->
        {:error, error_detail(100, "Invalid 'to' identity", "to.eid")}

      msg.to.connection_resource_id in [nil, ""] ->
        {:error, error_detail(100, "Missing 'to.connection_resource_id'", "to.connection_resource_id")}

      msg.type not in @allowed_types ->
        {:error, error_detail(100, "Invalid 'type' (must be 1, 2, or 3)", "type")}

      msg.type != 1 ->
        {:error, error_detail(100, "Client may only send type=1 (PING)", "type")}

      msg.timestamp in [nil, 0] ->
        {:error, error_detail(100, "Missing or invalid 'timestamp'", "timestamp")}

      msg.to.eid != eid or msg.to.connection_resource_id != device_id ->
        {:error, error_detail(401, "EID or device_id mismatch — unauthorized sender", "to")}

      true ->
        :ok
    end
  end

  defp error_detail(code, description, field),
    do: %{code: code, description: description, field: field}
end
