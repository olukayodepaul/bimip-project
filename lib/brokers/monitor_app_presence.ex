defmodule Bimip.SubscriberPresence do
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

  # ------------------------------
  # Direct user-level message broadcast
  # ------------------------------
  def user_level_broadcast(eid, _pid, message) do
    topic = "user_level_communication#{eid}"
    Phoenix.PubSub.broadcast(@pubsub, topic, {:direct_communication, message})

    Logger.debug("[Awareness] user_level_broadcast → eid=#{eid} topic=#{topic}")
  end

  # ------------------------------
  # Broadcast the owner's awareness to all subscribers/friends
  # ------------------------------
  def broadcast_awareness(owner_eid, awareness_intention \\ 2, status \\ :online, latitude \\ 0.0, longitude \\ 0.0) do
    state_change_status = StatusMapper.to_int(status)
    friends = fetch_friends(owner_eid)

    awareness = %Strucs.Awareness{
      owner_eid: owner_eid,
      friends: friends,
      status: state_change_status,
      last_seen: DateTime.utc_now() |> DateTime.truncate(:second),
      latitude: latitude,
      longitude: longitude,
      awareness_intention: awareness_intention
    }

    topic = "GENERAL:#{owner_eid}"

    Logger.info(
      "[Awareness] Broadcasting owner=#{owner_eid} status=#{state_change_status} to topic=#{topic} → #{length(friends)} friends"
    )

    Phoenix.PubSub.broadcast(@pubsub, topic, {:awareness_update, awareness})
  end

  # ------------------------------
  # Fetch friends/subscribers directly from Storage.Subscriber
  # ------------------------------
  def fetch_friends(owner_eid) do
    Storage.Subscriber.fetch_subscriber_ids_by_owner_all_arrays(owner_eid)
  end
end
