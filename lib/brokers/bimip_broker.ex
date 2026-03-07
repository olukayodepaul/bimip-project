defmodule Bimip.Broker.Server do

  @pubsub_server Bimip.PubSub

  @doc """
  Create a topic for a user.
  """
  def user_topic(eid) when is_binary(eid), do: "user:" <> eid

  @doc """
  Subscribe the calling process to a list of users' topics.
  """
  def subscribe_to_users(eid_list) when is_list(eid_list) do
    Enum.each(eid_list, fn eid ->
      Phoenix.PubSub.subscribe(@pubsub_server, user_topic(eid))
    end)
  end

  @doc """
  Broadcast a message to a user's topic.
  """
  def broadcast_to_user(eid, message) when is_binary(eid) do
    Phoenix.PubSub.broadcast(@pubsub_server, user_topic(eid), message)
  end
end
