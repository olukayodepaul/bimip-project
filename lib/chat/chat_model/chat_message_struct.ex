defmodule Chat.MessageStruct do
  @moduledoc """
  Struct for chat messages supporting multiple from/to entries.
  """

  defstruct [
    :id,
    :timestamp,
    :payload,
    :encryption_type,
    :encrypted,
    :signature,
    :device_id,
    from: [],
    to: []
  ]
end
