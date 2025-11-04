defmodule PersistMessage do
  @moduledoc """
  Handles message persistence and encoding.
  Replaces `signal_offset` with the log offset
  and returns the encoded message payload for writing.
  """

  alias ThrowMessageSchema

  @spec build(map(), integer(), integer() | nil) :: binary()
  def build(%{from: from, to: to, payload: payload} = attrs, signal_offset, user_offset \\ nil) do
    # If user_offset not provided, use signal_offset by default
    per_user_offset = user_offset || signal_offset
  
    ThrowMessageSchema.success(
      from[:eid],                   # from_eid
      from[:connection_resource_id], # from_device_id
      to[:eid],                     # to_eid
      to[:connection_resource_id],  # to_device_id
      attrs[:type] || 1,            # type
      payload,                      # payload
      attrs[:encryption_type] || "none",
      attrs[:encrypted] || "",
      attrs[:signature] || "",
      attrs[:status] || 1,          # status
      attrs[:id] || "",             # id
      "#{signal_offset}",           # signal_offset (global)
      "#{per_user_offset}"          # user_offset (per-user)
    )
  end
end
