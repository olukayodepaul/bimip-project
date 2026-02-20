defmodule Chat.MessageStruct do
  @moduledoc """
  Struct for chat messages supporting multiple from/to entries.
  """

  defstruct [
    :peer_uid,
    :timestamp,
    :payload,
    :payload_context,
    :encryption_type,
    :encrypted,
    :signature,
    :device_id,
    :uupid,
    :eid,
    from: [],
    to: []
  ]
end
