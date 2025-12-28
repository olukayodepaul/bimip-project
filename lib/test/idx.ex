defmodule Queue.TestQueueWrite do
  require Logger
  alias Queue.QueueLogImpl

  def run_bulk_test(n \\ 100) do
    Enum.each(1..n, fn idx ->
      chat_msg = %Chat.MessageStruct{
        peer_uid: "vcNAQcDoIIB4TCCAd0CAQAxggE2MIIBMgI-#{idx}",
        timestamp: System.system_time(:millisecond),
        payload: "\"This is test message #{idx} 👋\"",
        payload_context: 1,
        encryption_type: "E2E",
        encrypted: "MIIB8AYJKoZIhvcNAQcDoIIB4TCCAd0CAQAxggE2MIIBMgIBADAfMA4GCSqGSIb3DQEBCwUwggExBgsqhkiG9w0BCwEw",
        signature: "SHA256-R4f0S4E3V7gH6tK2mP9Yc0B1dZ2eG3h4iJ5kL7o9pQ8rT6uV5wX4yZ3aBcD1fG0hI7jKmNlOpZqRsT",
        device_id: 5,
        app_device_id: "aaaaa1",
        eid: "a@domain.com",
        from: %Chat.EntityStruct{eid: "a@domain.com", connection_resource_id: 5},
        to: %Chat.EntityStruct{eid: "b@domain.com", connection_resource_id: nil}
      }

      owner_eid = chat_msg.eid
      partition_id = 0
      device_id = chat_msg.device_id
      message_id = chat_msg.peer_uid

      # Ensure log folder exists
      path = Queue.QueueLogImpl.get_current_log_path(owner_eid, partition_id)
      File.mkdir_p!(Path.dirname(path))

      # Open file descriptor
      fd = File.open!(path, [:append, :binary, :raw])

      # Write message
      case Queue.QueueLogImpl.safe_write(
             fd,
             partition_id,
             owner_eid,
             chat_msg.to.eid,
             :chat,
             %{ctx: "test"},
             chat_msg,
             message_id,
             device_id
           ) do
        {:ok, offset, status} ->
          Logger.debug("Message #{idx} written: offset=#{offset}, status=#{inspect(status)}")

        {:error, reason} ->
          Logger.error("Failed to write message #{idx}: #{inspect(reason)}")
      end

      File.close(fd)
    end)
  end
end

# Usage in IEx:
# Queue.TestQueueWrite.run_bulk_test(500)   # insert 500 messages
