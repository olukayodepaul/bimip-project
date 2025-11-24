# ----------------------
# Proto message definition
# ----------------------
defmodule BimipLog.Proto.MessagePayload do
  use Protobuf, syntax: :proto3

  field :from, 1, type: :string
  field :to, 2, type: :string
  field :payload, 3, type: :string
  field :user_offset, 4, type: :int64
end