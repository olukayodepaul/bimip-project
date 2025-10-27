defmodule Storage.Subscriber do
  @moduledoc """
  Manages subscribers and their statuses in Mnesia.

  Main table (:subscribers)
    - id            : composite key {owner_id, subscriber_id}
    - owner_id      : owner identifier
    - subscriber_id : subscriber identifier
    - status        : :online / :offline
    - blocked       : boolean
    - inserted_at   : timestamp
    - last_seen     : timestamp

  Index table (:subscriber_index)
    - owner_id
    - subscriber_id
  """

  require Logger

  @subscriber_table :subscribers
  @subscriber_index_table :subscriber_index


  # -----------------------------
  # Add subscriber
  # -----------------------------
  def add_subscriber(%{
        owner_id: owner,
        subscriber_id: sub,
        status: status,
        blocked: blocked,
        inserted_at: inserted,
        last_seen: last_seen
      }) do
    id = {owner, sub}

    :mnesia.transaction(fn ->
      :mnesia.write({@subscriber_table, id, owner, sub, status, blocked, inserted, last_seen})
      :mnesia.write({@subscriber_index_table, owner, sub})
    end)
  end

  # -----------------------------
  # Get single subscriber
  # -----------------------------
  def get_subscriber(owner_id, subscriber_id) do
    id = {owner_id, subscriber_id}

    :mnesia.transaction(fn ->
      case :mnesia.read({@subscriber_table, id}) do
        [] -> nil
        [record] -> record
      end
    end)
    |> case do
      {:atomic, result} -> result
      {:aborted, reason} -> {:error, reason}
    end
  end

  # -----------------------------
  # Update subscriber
  # -----------------------------
  def update_subscriber(owner_id, subscriber_id, new_status, blocked \\ false) do
    case get_subscriber(owner_id, subscriber_id) do
      nil ->
        {:error, :not_found}

      {@subscriber_table, {^owner_id, ^subscriber_id} = id, owner, sub, _old_status, _old_blocked, _inserted, _last_seen} ->
        now = DateTime.utc_now()
        record = {@subscriber_table, id, owner, sub, new_status, blocked, now, now}

        :mnesia.transaction(fn ->
          :mnesia.write(record)
        end)
        |> case do
          {:atomic, _} -> {:ok, record}
          {:aborted, reason} -> {:error, reason}
        end
    end
  end

  # -----------------------------
  # Fetch all subscriber IDs for an owner
  # -----------------------------
  def fetch_subscriber_ids(owner_id) do
    match_spec = [{{@subscriber_index_table, owner_id, :"$1"}, [], [:"$1"]}]

    :mnesia.transaction(fn ->
      :mnesia.select(@subscriber_index_table, match_spec)
    end)
    |> case do
      {:atomic, ids} -> ids
      {:aborted, reason} -> {:error, reason}
    end
  end

  # -----------------------------
  # Fetch all subscribers for an owner (full records)
  # -----------------------------
  def fetch_all_subscribers(owner_id) do
    fetch_subscriber_ids(owner_id)
    |> case do
      [] -> []
      ids ->
        Enum.map(ids, fn sub_id ->
          get_subscriber(owner_id, sub_id)
        end)
        |> Enum.reject(&is_nil/1)
    end
  end

  # -----------------------------
  # Fetch all subscriber IDs (legacy function name)
  # -----------------------------
  def fetch_subscriber_ids_by_owner_all_arrays(owner_id) do
    fetch_subscriber_ids(owner_id)
  end

  # -----------------------------
  # Fetch subscribers for an owner (new function)
  # -----------------------------
  def fetch_subscribers_by_owner(owner_id) do
    fetch_all_subscribers(owner_id)
  end


end



# Enum.each(Storage.Subscriber.fetch_subscriber_ids_by_owner("a@domain.com"), fn sub_id ->
#   Phoenix.PubSub.broadcast(MyApp.PubSub, "TOPIC:#{sub_id}", {:message, "Hello!"})
# end)

# Storage.Subscriber.fetch_subscribers_by_owner("a@domain.com")
# Storage.Subscriber.fetch_subscriber_ids_by_owner_all_arrays("a@domain.com")
# Storage.Subscriber.get_subscriber("b@domain.com", "a@domain.com") 
# Storage.Subscriber.get_subscriber("a@domain.com", "b@domain.com") 
# Storage.Subscriber.fetch_all_subscribers("b@domain.com")


# Storage.Subscriber.update_subscriber("a@domain.com", "b@domain.com", "ONLINE")