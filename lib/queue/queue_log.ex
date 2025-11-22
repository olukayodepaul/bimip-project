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
      def store_message(user, partition_id, from, to, payload, user_offset \\ nil, merge_offset \\ nil) do
        QueueLogImpl.write(user, partition_id, from, to, payload, user_offset, merge_offset)
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

      def mark_ack_status(user, device, partition, offset, status),
        do: QueueLogImpl.ack_status(user, device, partition, offset, status)

      def get_message_offset(user, device, partition, message_id),
        do: QueueLogImpl.get_message_offset(user, device, partition, message_id)

      def insert_message_id(user, device, partition, message_id, offset),
        do: QueueLogImpl.insert_message_id(user, device, partition, message_id, offset)

    end
  end
end


# Queue.Injection.insert_message_id("a@domain.com_b@domain.com", "aaaaa1", 1, "4637829384765473892", 3)
# Injection.fetch_messages("b@domain.com_a@domain.com", "aaaaa1", 1, 3)
# Queue.Injection.confirm_advance_offset("a@domain.com_b@domain.com", "aaaaa1", 1, 1)

# Queue.Injection.get_message_offset("a@domain.com_b@domain.com", "aaaaa1", 1, "4637829384765473892")
