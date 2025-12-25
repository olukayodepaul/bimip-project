defmodule Queue.OfflineManager do
  alias Queue.QueueLogImpl

  def log_for_offline_user(to_user, partition_id, from_user, payload, message_id) do
    # 1. Start an atomic transaction
    :mnesia.transaction(fn ->
      # 2. Get the current state (This locks the row for to_user)
      {:ok, %{seg: seg, next_offset: current_offset, do_rollover: do_rollover}} =
        QueueLogImpl.get_write_state(to_user, partition_id)

      # 3. Open the file just for this write
      path = QueueLogImpl.get_current_log_path(to_user, partition_id)

      # Note: We don't use :raw here because we are opening/closing immediately
      case File.open(path, [:append, :binary]) do
        {:ok, fd} ->
          {:ok, pos_before} = :file.position(fd, :cur)

          # 4. Build and Write
          record = QueueLogImpl.build_record(from_user, to_user, payload, message_id, current_offset)
          :ok = QueueLogImpl.write_log_entry(fd, record, record.device_id, current_offset)

          File.close(fd)

          # 5. Finalize state (Increments offset in Mnesia)
          QueueLogImpl.finalize_write_state(to_user, partition_id, seg, current_offset, pos_before, do_rollover)

          {:ok, current_offset}

        {:error, reason} ->
          :mnesia.abort(reason)
      end
    end)
  end
end
