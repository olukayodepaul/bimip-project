defmodule Storage.SubscriberSeeder do
  alias Storage.Subscriber

  def seed_subscribers do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    subscribers = [
      %{owner_eid: "a@domain.com", subscriber_eid: "b@domain.com", status: :online, blocked: false, inserted_at: now, last_seen: now},
      %{owner_eid: "b@domain.com", subscriber_eid: "a@domain.com", status: :online, blocked: false, inserted_at: now, last_seen: now},
      %{owner_eid: "a@domain.com", subscriber_eid: "c@domain.com", status: :online, blocked: false, inserted_at: now, last_seen: now},
      %{owner_eid: "b@domain.com", subscriber_eid: "c@domain.com", status: :online, blocked: false, inserted_at: now, last_seen: now},
      %{owner_eid: "c@domain.com", subscriber_eid: "a@domain.com", status: :online, blocked: false, inserted_at: now, last_seen: now},
      %{owner_eid: "c@domain.com", subscriber_eid: "b@domain.com", status: :online, blocked: false, inserted_at: now, last_seen: now}
    ]

    Enum.each(subscribers, &Subscriber.add_subscriber/1)
  end

  def test_update do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # Example: update subscriber b@domain.com of owner a@domain.com
    Subscriber.update_subscriber(
      "a@domain.com",
      "b@domain.com",
      %{status: :offline, inserted_at: now, last_seen: now},
      true
    )
  end
end

# c("lib/test/simu.exs")
# Storage.SubscriberSeeder.test_update()