defmodule Storage.Registration do
  @moduledoc """
  Handles user registration storage using Mnesia.
  Each user (`eid`) has a single registration row.
  """

  require Logger

  @table :registration


  @doc """
  Insert or update a registration for a user (eid).
  Returns {:ok, registration} or {:error, reason}.
  """
  def upsert_registration(eid, visibility, display_name) do
    timestamp = DateTime.utc_now()
    key = eid

    :mnesia.transaction(fn ->
      case :mnesia.read({@table, key}) do
        [] ->
          :mnesia.write({@table, key, eid, visibility, display_name, timestamp})
          {:ok, %{eid: eid, visibility: visibility, display_name: display_name, timestamp: timestamp}}

        [{@table, ^key, _eid, _old_vis, _old_name, _old_ts}] ->
          :mnesia.write({@table, key, eid, visibility, display_name, timestamp})
          {:ok, %{eid: eid, visibility: visibility, display_name: display_name, timestamp: timestamp}}
      end
    end)
    |> case do
      {:atomic, result} -> result
      {:aborted, reason} -> {:error, reason}
    end
  end


  @doc """
  Fetch the registration for a user by eid.
  Returns {:ok, registration} or {:error, :not_found}.
  """
  def fetch_registration(eid) do
    key = eid

    :mnesia.transaction(fn ->
      case :mnesia.read({@table, key}) do
        [{@table, ^key, _eid, visibility, display_name, timestamp}] ->
          {:ok, %{eid: eid, visibility: visibility, display_name: display_name, timestamp: timestamp}}

        [] ->
          {:error, :not_found}
      end
    end)
    |> case do
      {:atomic, result} -> result
      {:aborted, reason} -> {:error, reason}
    end
  end

end

# Storage.Registration.fetch_registration("a@domain.com")
# Storage.Registration.upsert_registration("a@domain.com", 10, "Alice")
