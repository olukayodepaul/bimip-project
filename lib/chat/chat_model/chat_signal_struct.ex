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
    :ack_action,
    to: [],
    from: [],
  ]
end
