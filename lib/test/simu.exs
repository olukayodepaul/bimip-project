defmodule Storage.SubscriberSeeder do
  alias Storage.Subscriber

  def seed_subscribers do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    subscribers = [
      %{owner_id: "a@domain.com", subscriber_id: "b@domain.com", status: :online, blocked: false, inserted_at: now, last_seen: now},
      %{owner_id: "b@domain.com", subscriber_id: "a@domain.com", status: :online, blocked: false, inserted_at: now, last_seen: now},
      %{owner_id: "a@domain.com", subscriber_id: "c@domain.com", status: :online, blocked: false, inserted_at: now, last_seen: now},
      %{owner_id: "b@domain.com", subscriber_id: "c@domain.com", status: :online, blocked: false, inserted_at: now, last_seen: now},
      %{owner_id: "c@domain.com", subscriber_id: "a@domain.com", status: :online, blocked: false, inserted_at: now, last_seen: now},
      %{owner_id: "c@domain.com", subscriber_id: "b@domain.com", status: :online, blocked: false, inserted_at: now, last_seen: now}
    ]

    Enum.each(subscribers, &Subscriber.add_subscriber/1)
  end

  def test_update do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # Update subscriber b@domain.com of owner a@domain.com
    case Subscriber.update_subscriber("a@domain.com", "b@domain.com", :offline, true) do
      {:ok, updated_record} ->
        IO.inspect(updated_record, label: "Updated Subscriber")

      {:error, reason} ->
        IO.puts("Failed to update subscriber: #{inspect(reason)}")
    end
  end


end


#  {:attributes, [:key, :owner_eid, :subscriber_eid, :status, :blocked, :inserted_at, :last_seen]},
# [
#   {:subscriber, {"a@domain.com", "b@domain.com"}, "a@domain.com","b@domain.com", :online, false, ~U[2025-10-10 13:14:53Z], ~U[2025-10-10 13:14:53Z]},
# ]

# c("lib/test/simu.exs")
# Storage.SubscriberSeeder.seed_subscribers()