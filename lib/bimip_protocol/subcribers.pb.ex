defmodule BimipSubscribers.Subcribers do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :eid, 2, repeated: true, type: :string
end
