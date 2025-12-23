defmodule Queue.QueueLog do
  alias Queue.{QueueLogImpl}
  @moduledoc """
  Macro wrapper for QueueLogImpl — append-only per-user/device log with per-device pending ACKs.

  Usage:

      use QueueLog
  """

  defmacro __using__(_opts) do
    quote do
      require Logger

      # Public API: Delegates everything to QueueLogImpl
      def store_message(user, partition_id, from, to, payload, id, sender_offset \\ nil) do
        QueueLogImpl.write(user, partition_id, from, to, payload, id, sender_offset)
      end

      def fetch_messages(user, device_id, partition_id, limit \\ 1) when limit > 0 do
        QueueLogImpl.fetch(user, device_id, partition_id, limit)
      end

      def  advance_offset(user, device, partition, offset),
        do: QueueLogImpl.ack_message(user, device, partition, offset)

      def confirm_advance_offset(user, device, partition, offset),
        do: QueueLogImpl.confirm_adv_offset?(user, device, partition, offset)

      def get_ack_status(user, device, partition, offset),
        do: QueueLogImpl.message_status(user, device, partition, offset)

      def ack_status_multi(users_offsets_status),
        do: QueueLogImpl.ack_status_multi(users_offsets_status)

      def get_message_offset(user,  partition, message_id),
        do: QueueLogImpl.get_message_offset(user,  partition, message_id)

      def insert_message_id(snd_id, rec_id, partition_id, message_id, snd_offset, rec_offset),
        do: QueueLogImpl.insert_message_id(snd_id, rec_id, partition_id, message_id, snd_offset, rec_offset)

      def get_last_seen_offset(user, device, partition),
        do: QueueLogImpl.get_last_seen_offset(user, device, partition)

    end
  end
end


# test_data = [
#   {"a@domain.com", 0, 1, :delivered},
#   {"b@domain.com", 0, 1, :delivered}
# ]


# QueueLogImpl.fetch(user, device_id, partition_id, limit)

# Queue.Injection.ack_status_multi(test_data)
# Queue.Injection.advance_offset("a@domain.com_b@domain.com", "mmmmm", 1, 0..3)
# Queue.Injection.get_last_seen_offset("a@domain.com", "aaaaa1", 1)

# Queue.Injection.get_ack_status("a@domain.com_b@domain.com", "aaaaa1", 1, 1)

#  Queue.Injection.get_last_offset("a@domain.com_b@domain.com", 1)

# iex(4)>  Queue.Injection.get_ack_status("a@domain.com_b@domain.com", "aaaaa1", 1, 1)
# %{read: true, sent: true, delivered: true}
# iex(5)> Queue.Injection.get_ack_status("a@domain.com_b@domain.com", "aaaaa1", 1, 2)
# %{read: false, sent: true, delivered: false}
# iex(6)> Queue.Injection.get_ack_status("a@domain.com_b@domain.com", "aaaaa1", 1, 3)
# %{read: false, sent: true, delivered: false}
# iex(7)> Queue.Injection.get_ack_status("a@domain.com_b@domain.com", "aaaaa1", 1, 4)
# %{read: false, sent: true, delivered: false}
# iex(8)> Queue.Injection.get_ack_status("a@domain.com_b@domain.com", "aaaaa1", 1, 5)
# %{read: false, sent: true, delivered: false}
# iex(9)> Queue.Injection.get_ack_status("a@domain.com_b@domain.com", "aaaaa1", 1, 6)
# %{read: false, sent: true, delivered: false}

# Queue.Injection.mark_ack_status()

# Queue.Injection.fetch_messages("b@domain.com_a@domain.com", "", 1, 1)
# Queue.Injection.fetch_messages("a@domain.com", "aaaaa2", 1..10 )


# # ack_status(user, device, partition, 0..5, :read)
