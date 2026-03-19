defmodule Bimip.ServerClient do
  @moduledoc """
  Client for interacting with the bimIPs Central Server on DigitalOcean.
  """
  require Logger

  def fetch_roster_page(eid, offset, _limit) do
    Logger.debug("Fetching roster for #{eid} at offset #{offset}...")

    subscribers =
      cond do
        eid == "a@domain.com" ->
          [
            %{eid: "b@domain.com", d_tok: "mock_1", plat: "android", app_id: "com.bimips.app", node: 1, last_seen: System.system_time(:second)},
            %{eid: "c@domain.com", d_tok: "mock_2", plat: "android", app_id: "com.bimips.app", node: 2, last_seen: System.system_time(:second)}
          ]

        eid == "b@domain.com" ->
          [
            %{eid: "a@domain.com", d_tok: "mock_3", plat: "android", app_id: "com.bimips.app", node: 1, last_seen: System.system_time(:second)},
            %{eid: "c@domain.com", d_tok: "mock_4", plat: "android", app_id: "com.bimips.app", node: 2, last_seen: System.system_time(:second)}
          ]

        true -> # This acts as your final "else"
          [
            %{eid: "a@domain.com", d_tok: "mock_5", plat: "android", app_id: "com.bimips.app", node: 1, last_seen: System.system_time(:second)},
            %{eid: "b@domain.com", d_tok: "mock_6", plat: "android", app_id: "com.bimips.app", node: 2, last_seen: System.system_time(:second)}
          ]
      end

    {:ok, %{
      subscribers: subscribers,
      count: Enum.count(subscribers), # Corrected: must be 2, not 1
      completed: true
    }}
  end
end
