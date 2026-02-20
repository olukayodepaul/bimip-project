defmodule Queue.UserServer do
  use GenServer, restart: :temporary # Don't restart automatically; spawn on demand

  # --- Client API ---

  def add_subscriber(user_id, sub_id) do
    GenServer.cast(via_tuple(user_id), {:add_subscriber, sub_id})
  end

  def get_all_subscribers(user_id) do
    # 5 second timeout is plenty for 20k records
    GenServer.call(via_tuple(user_id), :get_all)
  end

  defp via_tuple(user_id), do: {:via, Registry, {Queue.UserRegistry, user_id}}

  # --- Callbacks ---

  def init(user_id) do
    # 2026 Recovery: Pulling the "Two-line manifest" style logic
    # We only load this specific user's subs from disk/DB
    case Queue.QueueLogImpl.get_subscribers_for_user(user_id) do
      subs when is_list(subs) ->
        state = %{user_id: user_id, subs: MapSet.new(subs)}
        # Hibernate immediately to save RAM until a message arrives
        {:ok, state, :hibernate}
      _ ->
        {:stop, :recovery_failed}
    end
  end

  # SAVE: Adding a subscriber
  def handle_cast({:add_subscriber, sub_id}, state) do
    new_set = MapSet.put(state.subs, sub_id)

    # 2026 Focus: Natural continuity requires persisting this write
    Queue.QueueLogImpl.persist_subscription(state.user_id, sub_id)

    {:noreply, %{state | subs: new_set}}
  end

  # PULL: Getting the full list
  def handle_call(:get_all, _from, state) do
    # MapSet.to_list is very fast for 20,000 items
    {:reply, MapSet.to_list(state.subs), state}
  end

  # OPTIONAL: Auto-shutdown after 30 mins of silence to free RAM
  def handle_info(:timeout, state) do
    {:stop, :normal, state}
  end
end


# data structure
# Example of the list you'd pull from your log/DB
# subscriber_ids = [102, 5004, 9923, 12003, 88]

# # Passing it to the MapSet in your state
# state = %{
#   user_id: 1,
#   subscribers: MapSet.new(subscriber_ids)
# }
