defmodule BimipServer.ActionType do
  @moduledoc false

  use Protobuf, enum: true, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :ACTION_UNKNOWN, 0
  field :FORWARD, 1
  field :RECEIPT, 2
  field :PRESENCE_UPDATE, 3
end
