defmodule Chat.AckSignal do
  alias Queue.Injection
  alias Route.SignalCommunication
  alias ThrowSignalSchema

  @partition_id 1
  @status 1

  def ack(%Chat.SignalStruct{} = signal) do

    handlers = %{
      1 => &sender/1,
      2 => &device/1,
      3 => &receiver/1
    }

    signal_type = signal.signal_type

    case Map.get(handlers, signal_type) do
      nil ->
        IO.puts("Unknown signal type: #{signal_type}")

      handler ->
        handler.(signal)
    end
  end

  def sender(%Chat.SignalStruct{
      id: id,
      to: %{eid: to_eid},
      from: %{eid: from_eid},
      device: device,
      signal_offset: signal_offset,
      user_offset: user_offset,
      eid: eid,
      signal_lifecycle_state: signal_lifecycle_state} = payload) do

    queue_id = "#{from_eid}_#{to_eid}"

    send_signal_to_sender(
      id,
      signal_offset,
      user_offset,
      @status,
      %{eid: eid, connection_resource_id: device},
      payload.to,
      queue_id,
      device,
      @partition_id,
      signal_lifecycle_state
    )
  end

  def device(%Chat.SignalStruct{
      id: id,
      to: %{eid: to_eid},
      from: %{eid: from_eid},
      device: device,
      signal_offset: signal_offset,
      user_offset: user_offset,
      eid: eid,
      signal_lifecycle_state: signal_lifecycle_state
  } = payload) do

    queue_id = "#{from_eid}_#{to_eid}"
    commit_status =
    if confirm_advance_offset(queue_id, device, @partition_id, signal_offset) do
        :ok
    else
        case maybe_advance_offset(queue_id, device, @partition_id, signal_offset, false) do
          {:ok, _commit} ->
            :ok
          {:error, _reason} -> :skip
        end
    end

    if commit_status == :ok do
      send_signal_to_sender(
        id,
        signal_offset,
        user_offset,
        @status,
        %{eid: eid, connection_resource_id: device},
        payload.to,
        queue_id,
        device,
        @partition_id,
        signal_lifecycle_state
      )
    end
  end

  def receiver(%Chat.SignalStruct{
        id: id,
        to: %{eid: to_eid, connection_resource_id: to_device_id},
        from: %{eid: from_eid, connection_resource_id: from_device_id},
        device: device,
        signal_offset: signal_offset,
        user_offset: user_offset,
        signal_lifecycle_state: signal_lifecycle_state
    } = payload) do

    # queue_id = "#{from_eid}_#{to_eid}"          # A → B queue (sender queue)
    # reverse_queue_id = "#{to_eid}_#{from_eid}"  # B → A queue (receiver queue)
    # ack_atom = String.to_existing_atom(signal_lifecycle_state)

    # with {:atomic, _} <- Injection.mark_ack_status(queue_id, from_device_id, @partition_id, signal_offset, ack_atom),
    #     {:atomic, _} <- Injection.mark_ack_status(reverse_queue_id, to_device_id, @partition_id, user_offset, ack_atom) do

    #     case ack_atom do
    #       :read -> IO.inspect(:read)
    #       :delivered ->

    #         with {:ok, _ } <- Injection.advance_offset(queue_id, from_device_id, @partition_id, signal_offset) do

    #           # 1.  receiver send to it self first
    #           ack_state = Injection.get_ack_status(queue_id, device, @partition_id, signal_offset)
    #           get_commit_offset = Injection.get_commit_offset(queue_id, device, @partition_id, signal_offset)
    #           reply = send_signal_to_sender(id, signal_offset, user_offset, 1, payload.from, payload.to, get_commit_offset, ack_state)

    #           # receiver send to is other online device by filtering it self
    #           # send to sender genserver while genserver send to other devices......

    #           reply
    #             |> ThrowSignalSchema.success()
    #             |> then(&SignalCommunication.outbouce(payload.from, &1))

    #         else
    #             error ->
    #             IO.inspect(error, label: "Receiver ACK failed")
    #             {:error, error}
    #         end

    #       :sent -> :ok
    #     end

    # else
    #   error ->
    #     IO.inspect(error, label: "Receiver ACK failed")
    #     {:error, error}
    # end
  end

  # ----------------------
  # Helpers
  # ----------------------
  defp get_ack_status(user, device, partition, offset), do: Injection.get_ack_status(user, device, partition, offset)
  defp confirm_advance_offset(user, device, partition, offset), do: Injection.confirm_advance_offset(user, device, partition, offset)

  defp maybe_advance_offset(queue_id, device_id, partition, offset, true), do: {:ok, offset}
  defp maybe_advance_offset(queue_id, device_id, partition, offset, false), do: Injection.advance_offset(queue_id, device_id, partition, offset)


  # ---------------------------
  # Send signal to sender
  # ---------------------------
  defp send_signal_to_sender(id, offset, user_offset, status, from, to, user, from_device_id, partition_id, signal_lifecycle_state) do
    %{read: read, sent: sent, delivered: delivered} = get_ack_status(user, from_device_id, partition_id, offset)
    adv = confirm_advance_offset(user, from_device_id, partition_id, offset)

    %{
      id: id,
      signal_offset: offset,
      user_offset: user_offset,
      status: status,
      from: to,
      to: from,
      signal_type: 1,
      signal_request: 2,
      signal_lifecycle_state: signal_lifecycle_state,
      signal_ack_state: %{send: sent, delivered: delivered, read: read, advance_offset: adv}
    }
    |> ThrowSignalSchema.success()
    |> then(&SignalCommunication.outbouce(from, &1))
  end


end
