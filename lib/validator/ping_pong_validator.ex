defmodule Bimip.Validators.PingPongValidator do
  @moduledoc """
  Validates PingPong messages according to the new schema:

  message PingPong {
      string id = 1;
      Identity from = 2;
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

      msg.from == nil or msg.from.eid in [nil, ""] ->
        {:error, error_detail(100, "Invalid 'from' identity", "from.eid")}

      msg.from.connection_resource_id in [nil, ""] ->
        {:error, error_detail(100, "Missing 'from.connection_resource_id'", "from.connection_resource_id")}

      msg.type not in @allowed_types ->
        {:error, error_detail(100, "Invalid 'type' (must be 1, 2, or 3)", "type")}

      msg.type != 1 ->
        {:error, error_detail(100, "Client may only send type=1 (PING)", "type")}

      msg.timestamp in [nil, 0] ->
        {:error, error_detail(100, "Missing or invalid 'timestamp'", "timestamp")}

      msg.from.eid != eid or msg.from.connection_resource_id != device_id ->
        {:error, error_detail(401, "EID or device_id mismatch — unauthorized sender", "from")}

      true ->
        :ok
    end
  end

  defp error_detail(code, description, field),
    do: %{code: code, description: description, field: field}
end
