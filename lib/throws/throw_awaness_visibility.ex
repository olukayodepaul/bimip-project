defmodule ThrowAwarenessVisibilitySchema do
  @moduledoc """
  Builds AwarenessVisibility stanzas for both success and error responses.

  message AwarenessVisibility {
      string id = 1;             // Unique request identifier (used to reconcile request/response)
      Identity from = 2;         // The user toggling their visibility
      int32 type = 3;            // 1 = ENABLED, 2 = DISABLED, 3 = ERROR
      int64 timestamp = 4;       // Unix UTC timestamp (ms)
      string details = 5;        // Optional message or reason
  }

  Behavior:
    - The `id` from the original request must always be echoed back in the response
      (whether success or error) to allow the client to correlate both messages.
  """

  alias Bimip.{AwarenessVisibility, Identity, MessageScheme}

  @route 4   # <--- IMPORTANT: use actual route ID for Awareness messages

  # ---------------- SUCCESS ----------------
  @doc """
  Builds a success response for an AwarenessVisibility update.

  Parameters:
    - id: Request ID to echo back for reconciliation
    - from_eid: User's EID
    - from_device_id: Device connection resource ID
    - type: 1 = ENABLED, 2 = DISABLED
    - details: Optional status description
  """
  def success(id, from_eid, from_device_id, type, details \\ "") when type in [1, 2] do
    msg = %AwarenessVisibility{
      id: id,
      from: %Identity{eid: from_eid, connection_resource_id: from_device_id},
      type: type,
      timestamp: System.system_time(:millisecond),
      details: details || ""
    }

    %MessageScheme{
      route: @route,
      payload: {:awareness_visibility, msg}
    }
    |> MessageScheme.encode()
  end

  # ---------------- ERROR ----------------
  @doc """
  Builds an error response for a failed AwarenessVisibility update.

  Parameters:
    - id: Request ID to echo back for reconciliation
    - from_eid: User's EID
    - from_device_id: Device connection resource ID
    - description: Error description
  """
  def error(id, from_eid, from_device_id, description) do
    msg = %AwarenessVisibility{
      id: id,
      from: %Identity{eid: from_eid, connection_resource_id: from_device_id},
      type: 3, # ERROR
      timestamp: System.system_time(:millisecond),
      details: description
    }

    %MessageScheme{
      route: @route,
      payload: {:awareness_visibility, msg}
    }
    |> MessageScheme.encode()
  end
end
