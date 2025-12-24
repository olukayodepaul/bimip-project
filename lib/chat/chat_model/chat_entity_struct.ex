defmodule Chat.EntityStruct do
  @moduledoc """
  Represents a single 'from' or 'to' entry in a chat message.
  """

  defstruct [
    :eid,
    :connection_resource_id
  ]
end
