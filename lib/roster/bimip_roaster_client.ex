defmodule Bimip.ServerClient do
  @moduledoc """
  Client for interacting with the bimIPs Central Server on DigitalOcean.
  """
  require Logger


  def fetch_roster_page(eid, _offset, _limit) do

    subscribers =
      cond do
        eid == "bim1@bimip.com" ->
          [
            %{eid: "bim2@bimip.com", d_tok: "mock_1", plat: "android", app_id: "com.bimips.app", node: 1, last_seen: System.system_time(:second), presence: 2},
            %{eid: "bim3@bimip.com", d_tok: "mock_3", plat: "android", app_id: "com.bimips.app", node: 1, last_seen: System.system_time(:second), presence: 2}
          ]

        eid == "bim2@bimip.com" ->
          [
            %{eid: "bim1@bimip.com", d_tok: "mock_3", plat: "android", app_id: "com.bimips.app", node: 1, last_seen: System.system_time(:second), presence: 2},
            %{eid: "bim3@bimip.com", d_tok: "mock_3", plat: "android", app_id: "com.bimips.app", node: 1, last_seen: System.system_time(:second), presence: 2}
          ]

        eid == "bim3@bimip.com" ->
          [
            %{eid: "bim1@bimip.com", d_tok: "mock_3", plat: "android", app_id: "com.bimips.app", node: 1, last_seen: System.system_time(:second), presence: 2}
          ]

        true -> # This acts as your final "else"
          [
            %{eid: "bim1@bimip.com", d_tok: "mock_5", plat: "android", app_id: "com.bimips.app", node: 1, last_seen: System.system_time(:second), presence: 2},
            %{eid: "bim2@bimip.com", d_tok: "mock_6", plat: "android", app_id: "com.bimips.app", node: 2, last_seen: System.system_time(:second), presence: 2}
          ]
      end

    {:ok, %{
      subscribers: subscribers,
      count: Enum.count(subscribers), # Corrected: must be 2, not 1
      completed: true
    }}
  end
end
