defmodule Bimip.Identity do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :eid, 1, type: :string

  field :connection_resource_id, 2,
    proto3_optional: true,
    type: :string,
    json_name: "connectionResourceId"

  field :node, 3, proto3_optional: true, type: :string
end

defmodule Bimip.PushNotification do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :id, 1, type: :string
  field :from, 2, type: Bimip.Identity
  field :to, 3, type: Bimip.Identity
  field :type, 4, type: :string
  field :timestamp, 5, type: :int64
  field :payload, 6, type: :bytes
end

defmodule Bimip.TokenAuthority do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :to, 1, type: Bimip.Identity
  field :token, 2, type: :string
  field :type, 3, type: :int32
  field :task, 4, type: :int32
  field :timestamp, 5, type: :int64
  field :details, 6, type: :string
end

defmodule Bimip.LocationStream do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :id, 1, type: :string
  field :from, 2, type: Bimip.Identity
  field :to, 3, type: Bimip.Identity
  field :latitude, 4, type: :double
  field :longitude, 5, type: :double
  field :altitude, 6, proto3_optional: true, type: :double
  field :timestamp, 7, type: :int64
end

defmodule Bimip.Logout do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :from, 1, type: Bimip.Identity
  field :timestamp, 4, type: :int64
end

defmodule Bimip.Body do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :route_id, 1, type: :int32, json_name: "routeId"
  field :messages, 2, repeated: true, type: Bimip.Message
  field :timestamp, 3, type: :int64
end

defmodule Bimip.Ping do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :id, 1, type: :string
  field :from, 2, type: Bimip.Identity
  field :type, 3, type: :int32
  field :timestamp, 4, type: :int64
end

defmodule Bimip.OffsetCommit do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :from, 1, type: Bimip.Identity
  field :type, 2, type: :int32
  field :offset, 3, type: :int64
  field :timestamp, 4, type: :int64
end

defmodule Bimip.ProtocolError do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :route_id, 1, type: :int32, json_name: "routeId"
  field :details, 2, type: :string
  field :timestamp, 3, type: :int64
end

defmodule Bimip.MessageDeliveryReceipts do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :id, 1, type: :string
  field :from, 2, type: Bimip.Identity
  field :to, 3, type: Bimip.Identity
  field :offset, 4, type: :int64
  field :timestamp, 5, type: :int64
end

defmodule Bimip.Message do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :id, 1, type: :string
  field :from, 2, type: Bimip.Identity
  field :to, 3, type: Bimip.Identity
  field :offset, 4, proto3_optional: true, type: :int64
  field :timestamp, 5, type: :int64
  field :payload, 6, type: :bytes
  field :delivery_type, 7, proto3_optional: true, type: :int32, json_name: "deliveryType"
  field :participant_role, 8, type: :int32, json_name: "participantRole"
  field :content_type, 9, type: :int32, json_name: "contentType"
  field :ephemeral_public_key, 10, type: :bytes, json_name: "ephemeralPublicKey"
  field :mac, 11, type: :bytes
  field :message_type, 12, type: :int32, json_name: "messageType"
end

defmodule Bimip.Compose do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :to, 1, type: Bimip.Identity
  field :from, 2, type: Bimip.Identity
  field :type, 3, type: :int32
  field :timestamp, 4, type: :int64
end

defmodule Bimip.Awareness do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :from, 1, type: Bimip.Identity
  field :presence, 2, type: :int32
  field :offset, 3, type: :int64
  field :broadcast, 4, type: :int32
  field :timestamp, 5, type: :int64
end

defmodule Bimip.MessageScheme do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  oneof :payload, 0

  field :route_id, 1, type: :int64, json_name: "routeId"
  field :awareness, 2, type: Bimip.Awareness, oneof: 0
  field :ping, 3, type: Bimip.Ping, oneof: 0
  field :compose, 4, type: Bimip.Compose, oneof: 0
  field :token_authority, 5, type: Bimip.TokenAuthority, json_name: "tokenAuthority", oneof: 0
  field :message, 6, type: Bimip.Message, oneof: 0
  field :offset_commit, 7, type: Bimip.OffsetCommit, json_name: "offsetCommit", oneof: 0

  field :push_notification, 8,
    type: Bimip.PushNotification,
    json_name: "pushNotification",
    oneof: 0

  field :location_stream, 9, type: Bimip.LocationStream, json_name: "locationStream", oneof: 0
  field :body, 10, type: Bimip.Body, oneof: 0
  field :protocol_error, 11, type: Bimip.ProtocolError, json_name: "protocolError", oneof: 0
  field :logout, 12, type: Bimip.Logout, oneof: 0

  field :message_delivery_receipts, 13,
    type: Bimip.MessageDeliveryReceipts,
    json_name: "messageDeliveryReceipts",
    oneof: 0
end
