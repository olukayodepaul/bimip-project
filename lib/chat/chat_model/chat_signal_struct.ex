defmodule Chat.SignalStruct do
  defstruct [
    :id,
    :status,
    :type,
    :eid,
    :device,
    :signal_offset,
    :user_offset,
    :signal_type,
    :signal_lifecycle_state,
    :ack_action,
    to: [],
    from: [],
  ]
end
