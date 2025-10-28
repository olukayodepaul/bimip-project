defmodule ThrowAwarenessVisibilitySchema do
  @moduledoc """
  Builds AwarenessVisibility stanzas for both success and error responses.

  message AwarenessVisibility {
      Identity from = 1;        // The user toggling their visibility
      int32 type = 2;           // 1 = ENABLED, 2 = DISABLED, 3 = ERROR
      int64 timestamp = 3;      // Unix UTC timestamp (ms)
      string details = 4;       // Optional message or reason
  }
  """

  alias Bimip.{AwarenessVisibility, Identity, MessageScheme}

  @route 5   # <--- IMPORTANT: update to the actual route used for Awareness messages

  # ---------------- SUCCESS ----------------
  @doc """
  Send a visibility update for the user's own status.

  type:
    1 = ENABLED (visible)
    2 = DISABLED (hidden)
  """
  def success(from_eid, from_device_id, type, details \\ "") when type in [1, 2] do
    msg = %AwarenessVisibility{
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
  Return an error result for failed visibility toggle.
  Type is always 3 = ERROR
  """
  def error(from_eid, from_device_id, description) do
    msg = %AwarenessVisibility{
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
