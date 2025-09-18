defmodule Strucs.Awareness do
  @moduledoc """
  Per-device awareness for global broadcast: online/offline/away/dnd
  """
  defstruct [
    :owner_eid,
    :friends,    # List of friend EIDs
    :status,     # AwarenessStatus (ONLINE, AWAY, DND, OFFLINE)
    :last_seen,  # Unix timestamp
    :latitude,   # optional
    :longitude,   # optional
    :awareness_intention
  ]
end