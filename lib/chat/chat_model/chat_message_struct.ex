defmodule Chat.MessageStruct do
  @moduledoc """
  Struct for chat messages supporting multiple from/to entries.
  """

  defstruct [
    :peer_uid,
    :timestamp,
    :payload,
    :encryption_type,
    :encrypted,
    :signature,
    :device_id,
    :eid,
    from: [],
    to: []
  ]
end
