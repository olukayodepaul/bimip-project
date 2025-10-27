defmodule Bimip.Identity do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :eid, 1, type: :string

  field :connection_resource_id, 2,
    proto3_optional: true,
    type: :string,
    json_name: "connectionResourceId"
end

defmodule Bimip.Media do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :type, 1, type: :string
  field :url, 2, type: :string
  field :thumbnail, 3, type: :string
  field :size, 4, type: :int64
end

defmodule Bimip.Payload.DataEntry do
  @moduledoc false

  use Protobuf, map: true, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Bimip.Payload do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :data, 1, repeated: true, type: Bimip.Payload.DataEntry, map: true
  field :media, 2, repeated: true, type: Bimip.Media
end

defmodule Bimip.Metadata do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :encrypted, 1, type: :string
  field :signature, 2, type: :string
end

defmodule Bimip.Ack do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :status, 1, repeated: true, type: :int32
end

defmodule Bimip.Awareness do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :id, 1, type: :string
  field :from, 2, type: Bimip.Identity
  field :to, 3, type: Bimip.Identity
  field :type, 4, type: :int32
  field :status, 5, type: :int32
  field :location_sharing, 6, type: :int32, json_name: "locationSharing"
  field :latitude, 7, type: :double
  field :longitude, 8, type: :double
  field :ttl, 9, type: :int32
  field :details, 10, type: :string
  field :timestamp, 11, type: :int64
  field :node, 12, type: :int64
end

defmodule Bimip.Message do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :id, 1, type: :string
  field :from, 2, type: :string
  field :to, 3, type: :string
  field :type, 4, type: :string
  field :timestamp, 5, type: :int64
  field :payload, 6, type: Bimip.Payload
  field :ack, 7, type: Bimip.Ack
  field :metadata, 8, type: Bimip.Metadata
end

defmodule Bimip.ErrorMessage do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :code, 1, type: :int32
  field :error_origin, 2, type: :int32, json_name: "errorOrigin"
  field :details, 3, type: :string
  field :timestamp, 4, type: :int64
end

defmodule Bimip.PingPong do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :id, 1, type: :string
  field :to, 2, type: Bimip.Identity
  field :type, 3, type: :int32
  field :timestamp, 4, type: :int64
  field :details, 5, type: :string
end

defmodule Bimip.TokenRevoke do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :to, 1, type: Bimip.Identity
  field :token, 2, type: :string
  field :type, 3, type: :int32
  field :timestamp, 4, type: :int64
  field :details, 5, type: :string
end

defmodule Bimip.TokenRefresh do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :to, 1, type: Bimip.Identity
  field :refresh_token, 2, type: :string, json_name: "refreshToken"
  field :type, 3, type: :int32
  field :timestamp, 4, type: :int64
  field :details, 5, type: :string
end

defmodule Bimip.AwarenessSubscribe do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :from, 1, type: Bimip.Identity
  field :to, 2, type: Bimip.Identity
  field :tracking_id, 3, type: :string, json_name: "trackingId"
  field :one_way, 4, type: :bool, json_name: "oneWay"
  field :type, 5, type: :int32
  field :timestamp, 6, type: :int64
  field :details, 7, type: :string
end

defmodule Bimip.AwarenessUnsubscribe do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :from, 1, type: Bimip.Identity
  field :to, 2, type: Bimip.Identity
  field :tracking_id, 3, type: :string, json_name: "trackingId"
  field :type, 4, type: :int32
  field :timestamp, 5, type: :int64
  field :details, 6, type: :string
end

defmodule Bimip.Logout do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :to, 1, type: Bimip.Identity
  field :type, 2, type: :int32
  field :status, 3, type: :int32
  field :timestamp, 4, type: :int64
  field :details, 5, type: :string
end

defmodule Bimip.Body do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :route, 1, type: :int64
  field :awareness_list, 2, repeated: true, type: Bimip.Awareness, json_name: "awarenessList"
  field :timestamp, 3, type: :int64
end

defmodule Bimip.MessageScheme do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  oneof :payload, 0

  field :route, 1, type: :int64
  field :awareness, 2, type: Bimip.Awareness, oneof: 0
  field :ping_pong, 3, type: Bimip.PingPong, json_name: "pingPong", oneof: 0
  field :token_revoke, 4, type: Bimip.TokenRevoke, json_name: "tokenRevoke", oneof: 0
  field :token_refresh, 5, type: Bimip.TokenRefresh, json_name: "tokenRefresh", oneof: 0

  field :awareness_subscribe, 6,
    type: Bimip.AwarenessSubscribe,
    json_name: "awarenessSubscribe",
    oneof: 0

  field :awareness_unsubscribe, 7,
    type: Bimip.AwarenessUnsubscribe,
    json_name: "awarenessUnsubscribe",
    oneof: 0

  field :logout, 8, type: Bimip.Logout, oneof: 0
  field :error, 9, type: Bimip.ErrorMessage, oneof: 0
  field :body, 10, type: Bimip.Body, oneof: 0
  field :chat_message, 11, type: Bimip.Message, json_name: "chatMessage", oneof: 0
end
