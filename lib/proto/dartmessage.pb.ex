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

defmodule Bimip.Media do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :type, 1, type: :string
  field :url, 2, type: :string
  field :thumbnail, 3, type: :string
  field :size, 4, type: :int64
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
  field :visibility, 12, type: :int32
end

defmodule Bimip.Message do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :id, 1, type: :string
  field :signal_offset, 2, type: :string, json_name: "signalOffset"
  field :user_offset, 3, type: :string, json_name: "userOffset"
  field :from, 4, type: Bimip.Identity
  field :to, 5, type: Bimip.Identity
  field :type, 6, type: :int32
  field :timestamp, 7, type: :int64
  field :payload, 8, type: :bytes
  field :encryption_type, 9, type: :string, json_name: "encryptionType"
  field :encrypted, 10, type: :string
  field :signature, 11, type: :string
  field :status, 12, type: :int32
end

defmodule Bimip.Signal do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :id, 1, type: :string
  field :signal_offset, 2, type: :string, json_name: "signalOffset"
  field :user_offset, 3, type: :string, json_name: "userOffset"
  field :status, 4, type: :int32
  field :timestamp, 5, type: :int64
  field :from, 6, type: Bimip.Identity
  field :to, 7, type: Bimip.Identity
  field :type, 8, type: :int32
  field :error, 9, proto3_optional: true, type: :string
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
  field :from, 2, type: Bimip.Identity
  field :type, 3, type: :int32
  field :timestamp, 4, type: :int64
  field :details, 5, type: :string
end

defmodule Bimip.Contact do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :from, 1, type: Bimip.Identity
  field :to, 2, type: Bimip.Identity
  field :tracking_id, 3, type: :string, json_name: "trackingId"
  field :relationship, 4, type: :int32
  field :action, 5, type: :int32
  field :timestamp, 6, type: :int64
  field :details, 7, type: :string
end

defmodule Bimip.AwarenessVisibility do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto3

  field :id, 1, type: :string
  field :from, 2, type: Bimip.Identity
  field :type, 3, type: :int32
  field :timestamp, 4, type: :int64
  field :details, 5, type: :string
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

  field :awareness_visibility, 4,
    type: Bimip.AwarenessVisibility,
    json_name: "awarenessVisibility",
    oneof: 0

  field :token_authority, 5, type: Bimip.TokenAuthority, json_name: "tokenAuthority", oneof: 0
  field :message, 6, type: Bimip.Message, oneof: 0
  field :signal, 7, type: Bimip.Signal, oneof: 0

  field :push_notification, 8,
    type: Bimip.PushNotification,
    json_name: "pushNotification",
    oneof: 0

  field :location_stream, 9, type: Bimip.LocationStream, json_name: "locationStream", oneof: 0
  field :body, 10, type: Bimip.Body, oneof: 0
  field :error, 11, type: Bimip.ErrorMessage, oneof: 0
  field :logout, 12, type: Bimip.Logout, oneof: 0
end
