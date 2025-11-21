defmodule Chat.SignalStruct do
  defstruct [
    :id,
    :status,
    :to,
    :from,
    :type,
    :eid,
    :device,
    :signal_offset,
    :user_offset,
    :signal_type,
    :signal_lifecycle_state,
  ]
end
