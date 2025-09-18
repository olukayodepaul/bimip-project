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
  def subscribe_to_friends(owner_eid) do
    friends = fetch_friends(owner_eid)

    Enum.each(friends, fn friend_eid ->
      topic = "TOPIC:#{friend_eid}"
      :ok = PubSub.subscribe(@pubsub, topic)
    end)

    Logger.debug(
      "[Awareness] owner=#{owner_eid} subscribed to #{length(friends)} friends: #{inspect(friends)}"
    )
  end

  def user_level_subscribtion(eid) do
    topic = "user_level_communication#{eid}"
    PubSub.subscribe(@pubsub, topic)
  end

  def user_level_broadcast(eid, pid, message) do
    topic = "user_level_communication#{eid}"
    Phoenix.PubSub.broadcast(@pubsub, topic, {:direct_communication, message})
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

    topic = "TOPIC:#{owner_eid}"

    Logger.info(
      "[Awareness] Broadcasting owner=#{owner_eid} status=#{awareness.status} to topic=#{topic}"
    )

    Phoenix.PubSub.broadcast(@pubsub, topic, {:awareness_update, awareness})
  end


  # ------------------------------
  # Fetch friends/subscribers directly from Storage.Subscriber
  # ------------------------------
  defp fetch_friends(owner_eid) do
    case Storage.Subscriber.fetch_subscribers_by_owner(owner_eid) do
      {:ok, subscribers} ->
        subscribers
        |> Enum.filter(fn s -> s.status == :online and not s.blocked end)
        |> Enum.map(& &1.subscriber_eid)

      _ -> []
    end
  end

end

#   # # ------------------------------
#   # # Fan out awareness to all online child GenServers
#   # # ------------------------------
#   # # leave these untouched
#   # def fan_out_to_children(owner_eid, %Strucs.Awareness{} = awareness) do
#   #   PgDeviceCache.all(owner_eid)
#   #   |> Enum.filter(fn d -> d.status == "ONLINE" and not is_nil(d.eid) end)
#   #   |> Task.async_stream(
#   #     fn device -> send_to_child(device.device_id, device.eid, awareness) end,
#   #     max_concurrency: 50,
#   #     timeout: 5_000
#   #   )
#   #   |> Stream.run()
#   # end

#   # defp send_to_child(device_id, eid, %Strucs.Awareness{} = awareness) do
#   #   AllRegistry.fan_out_to_children(device_id, eid, awareness)
#   # end
# end
