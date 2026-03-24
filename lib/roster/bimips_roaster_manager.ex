defmodule Bimip.Signal.RosterManager do
  @moduledoc """
  Independent service for fetching subscriber metadata in chunks for the SignalServer.

  ## Data Contract (The :roster payload)
  Each chunk sent back to the SignalServer contains a list of maps.
  The SignalServer then transforms this into a Map-of-Maps:

  ### Expected Data Format:
  %{
    "paul@bimips.com" => %{
      eid: "paul@bimips.com",
      d_tok: "fcm_token_123...",
      plat: "android",
      app_id: "com.bimips.app",
      device_id: "uuid-9988-7766",
      last_seen: 1710695524
    },
    "sola@bimips.com" => %{
      eid: "sola@bimips.com",
      d_tok: "fcm_token_456...",
      plat: "ios",
      app_id: "com.bimips.app",
      device_id: "uuid-1122-3344",
      last_seen: 1710695600
    }
  }
  """
  require Logger

  @chunk_size 500

  @doc """
  Starts the async fetching process.
  Uses offset-based pagination to sync 5,000+ records in chunks of 500.
  """
  def start_link(eid, parent_pid) do
    Task.start(fn ->
      fetch_loop(eid, parent_pid, 0)
    end)
  end

  defp fetch_loop(eid, parent_pid, offset) do
    # Call the bimIPs Server (DigitalOcean Droplet)
    case Bimip.ServerClient.fetch_roster_page(eid, offset, @chunk_size) do
      {:ok, %{subscribers: list, count: received_count, completed: is_done}} ->
        # Send the list to the SignalServer
        send(parent_pid, {:roster, list})

        if is_done do
          Logger.info("RosterManager: Finished sync for #{eid}. Total: #{offset + received_count}")
          send(parent_pid, :roster_sync_complete)
        else
          # Recursive call for the next 500 records
          fetch_loop(eid, parent_pid, offset + received_count)
        end

      {:error, reason} ->
        Logger.error("RosterManager: Fetch failed for #{eid} at offset #{offset}: #{inspect(reason)}")
    end
  end
end
