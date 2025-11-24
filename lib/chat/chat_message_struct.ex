defmodule Chat.EntityStruct do
  @moduledoc """
  Represents a single 'from' or 'to' entry in a chat message.
  """

  defstruct [
    :eid,
    :connection_resource_id
  ]
end

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
