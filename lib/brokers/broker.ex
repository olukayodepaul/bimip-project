defmodule Bimip.Broker do
  @moduledoc """
  Handles user presence and awareness.
  Fetches subscriber/friend list dynamically from `Storage.Subscriber`.
  Broadcasts status to all subscribers via PubSub.
  """

  alias Phoenix.PubSub
  alias Util.StatusMapper
  require Logger

  @pubsub Bimip.PubSub

  # ----------------------------------------------------
  # Subscribe the current owner to all friends' topics
  # ---------------------------------------------------
  def presence_subscriber(owner_eid) do
    # Each owner always listens to their own SINGLE channel
    owner_topic = "SINGLE:#{owner_eid}"
    :ok = PubSub.subscribe(@pubsub, owner_topic)

    friends = fetch_friends(owner_eid)

    Enum.each(friends, fn friend_eid ->
      topic = "GENERAL:#{friend_eid}"

      case PubSub.subscribe(@pubsub, topic) do
        :ok ->
          Logger.debug("[Awareness] owner=#{owner_eid} subscribed to #{topic}")

        {:error, {:already_subscribed, ^topic}} ->
          Logger.debug("[Awareness] owner=#{owner_eid} already subscribed to #{topic}")

        other ->
          Logger.warning(
            "[Awareness] owner=#{owner_eid} unexpected result subscribing to #{topic}: #{inspect(other)}"
          )
      end
    end)

    Logger.info("[Awareness] owner=#{owner_eid} subscribed to #{length(friends)} friend topics")

    :ok
  end

  def group(from_eid, awareness_msg, intention \\ 2) do
    IO.inspect("bshb SD HSBCJAs cb hadsjcdhsbc hdsacudsacbvdyicahos dsjia dsyao xxxxxx")
    owner_eid = from_eid
    topic = "GENERAL:#{owner_eid}"

    Logger.info(
      "[Awareness] Broadcasting owner=#{owner_eid}  to topic=#{topic}"
    )
    Phoenix.PubSub.broadcast(@pubsub, topic, {:awareness_update, awareness_msg})
  end

  def peer(from_eid, awareness_msg, intention \\ 2) do
    owner_eid = from_eid
    topic = "SINGLE:#{owner_eid}"

    Logger.info(
      "[Awareness] Broadcasting owner=#{owner_eid}  to topic=#{topic}"
    )
    IO.inspect({from_eid, awareness_msg, intention})
    Phoenix.PubSub.broadcast(@pubsub, topic, {:awareness_update, awareness_msg})
  end

  # ------------------------------
  # Fetch friends/subscribers directly from Storage.Subscriber
  # ------------------------------
  def fetch_friends(owner_eid) do
    Storage.Subscriber.fetch_subscriber_ids_by_owner_all_arrays(owner_eid)
  end
end



