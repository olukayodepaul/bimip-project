defmodule Storage.Subscriber do
  @moduledoc """
  Manage subscribers and their statuses in Mnesia.

  Subscriber table structure:
    - key
    - owner_eid
    - subscriber_eid
    - status (:online / :offline)
    - blocked (true / false)
    - inserted_at (timestamp)
    - last_seen (timestamp)

  Secondary index table:
    - owner_eid
    - subscriber_eid
  """

  require Logger

  @subscriber_table :subscriber
  @subscriber_index_table :subscriber_index

  # -----------------------------
  # Insert subscriber
  # -----------------------------
  def add_subscriber(%{
        owner_eid: owner,
        subscriber_eid: sub,
        status: status,
        blocked: blocked,
        inserted_at: inserted,
        last_seen: last_seen
      }) do
    key = {owner, sub}  # composite key

    :mnesia.transaction(fn ->
      :mnesia.write({@subscriber_table, key, owner, sub, status, blocked, inserted, last_seen})
      :mnesia.write({@subscriber_index_table, owner, sub})
    end)
  end

  # -----------------------------
  # Get subscriber by composite key
  # -----------------------------
  def get_subscriber(owner_eid, subscriber_eid) do
    key = {owner_eid, subscriber_eid}

    :mnesia.transaction(fn ->
      case :mnesia.read({@subscriber_table, key}) do
        [] -> nil
        [record] -> record
      end
    end)
    |> case do
      {:atomic, result} -> result
      {:aborted, reason} -> {:error, reason}
    end
  end


  def update_subscriber(owner_eid, subscriber_eid, updates, blocked \\ false) do
    key = {owner_eid, subscriber_eid}

    :mnesia.transaction(fn ->
      case :mnesia.read({@subscriber_table, key}) do
        [] ->
          {:error, :not_found}

        [{@subscriber_table, ^key, owner, sub, status, _blocked, inserted_at, last_seen}] ->
          new_status     = Map.get(updates, :status, status)
          new_inserted   = Map.get(updates, :inserted_at, inserted_at)
          new_last_seen  = Map.get(updates, :last_seen, last_seen)

          record = {@subscriber_table, key, owner, sub, new_status, blocked, new_inserted, new_last_seen}
          :mnesia.write(record)
          {:ok, record}
      end
    end)
    |> case do
      {:atomic, result} -> result
      {:aborted, reason} -> {:error, reason}
    end
  end


  @doc """
  Fetch all subscriber records for a given owner_eid.
  Uses the subscriber_index table to find all subscriber_eids,
  then retrieves the full subscriber record from the subscriber table.
  """
  def fetch_subscribers_by_owner(owner_eid) do
    :mnesia.transaction(fn ->
      # Step 1: Get all subscriber_eid values for this owner
      :mnesia.match_object({@subscriber_index_table, owner_eid, :_})
    end)
    |> case do
      {:atomic, []} ->
        []

      {:atomic, index_records} ->
        # index_records = [{:subscriber_index, owner_eid, subscriber_eid}, ...]
        index_records
        |> Enum.map(fn {@subscriber_index_table, ^owner_eid, subscriber_eid} ->
          get_subscriber(owner_eid, subscriber_eid)
        end)
        |> Enum.reject(&is_nil/1)

      {:aborted, reason} ->
        {:error, reason}
    end
  end

  def fetch_subscriber_ids_by_owner_all_arrays(owner_eid) do
    :mnesia.transaction(fn ->
      # Fetch all subscriber_eid values directly from the index
      :mnesia.match_object({@subscriber_index_table, owner_eid, :_})
    end)
    |> case do
      {:atomic, []} ->
        []

      {:atomic, index_records} ->
        # Extract subscriber_eid only
        Enum.map(index_records, fn {@subscriber_index_table, ^owner_eid, subscriber_eid} ->
          subscriber_eid
        end)

      {:aborted, reason} ->
        {:error, reason}
    end
  end

end


# Enum.each(Storage.Subscriber.fetch_subscriber_ids_by_owner("a@domain.com"), fn sub_id ->
#   Phoenix.PubSub.broadcast(MyApp.PubSub, "TOPIC:#{sub_id}", {:message, "Hello!"})
# end)



# Storage.Subscriber.fetch_subscriber_ids_by_owner_all_arrays("@domain.com")
# Storage.Subscriber.get_subscriber("a@domain.com", "b@domain.com") 
