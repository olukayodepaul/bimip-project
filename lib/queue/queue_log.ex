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

      def fetch_messages(user, device_id, partition_id, limit \\ 10) when limit > 0 do
        QueueLogImpl.fetch(user, device_id, partition_id, limit)
      end

      def  advance_offset(user, device, partition, offset),
        do: QueueLogImpl.ack_message(user, device, partition, offset)

      def get_ack_status(user, device, partition, offset),
        do: QueueLogImpl.message_status(user, device, partition, offset)

      def mark_ack_status(user, device, partition, offset, status),
        do: QueueLogImpl.ack_status(user, device, partition, offset, status)


    end
  end
end
