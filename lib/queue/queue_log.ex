defmodule Queue.QueueLog do
  # alias Queue.QueueLogImpl

  # @moduledoc """
  # Macro wrapper for QueueLogImpl.

  # Provides a stable public API for the append-only log
  # backed by file segments + ETS sparse index.
  # """

  # defmacro __using__(_opts) do
  #   quote do
  #     require Logger

  #     @doc """
  #     Append a message to the log.

  #     Returns:
  #       {:ok, offset, :ok | :rollover}
  #     """
  #     def write(fd, partition_id, user, to, payload, message_id \\ nil, sender_offset \\ 0) do
  #       QueueLogImpl.write(
  #         fd,
  #         partition_id,
  #         user,
  #         to,
  #         payload,
  #         message_id,
  #         sender_offset
  #       )
  #     end

  #     @doc """
  #     Fetch messages for a device starting from its commit offset.
  #     """
  #     def fetch_messages(user, device_id, partition_id, limit \\ 1)
  #         when limit > 0 do
  #       QueueLogImpl.fetch(user, device_id, partition_id, limit)
  #     end

  #     @doc """
  #     Get the current active log file path for a partition.
  #     """
  #     def get_current_log_path(user, partition_id) do
  #       QueueLogImpl.get_current_log_path(user, partition_id)
  #     end
  #   end
  # end
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
# Queue.Injection.fetch_messages("a@domain.com", "aaaaa2", 1, 10 )


# # ack_status(user, device, partition, 0..5, :read)
