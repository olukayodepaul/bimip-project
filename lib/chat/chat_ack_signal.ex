defmodule Chat.AckSignal do
  alias Queue.Injection
  alias Route.SignalCommunication
  alias ThrowSignalSchema
  alias Storage.DeviceStorage
  alias Settings.ServerState

  @stale_threshold_seconds ServerState.stale_threshold_seconds()

  @partition_id 1
  @status 1

  # ---------------------------------------------------
  # Entry point
  # ---------------------------------------------------
  def ack(%Chat.SignalStruct{signal_type: type} = signal) do
    case type do
      1 -> sender(signal)
      2 -> device(signal)
      3 -> receiver(signal)
      _ -> IO.puts("Unknown signal type: #{type}")
    end
  end

  # ---------------------------------------------------
  # SENDER → Just pull ack status
  # ---------------------------------------------------
  def sender(%Chat.SignalStruct{
        id: id,
        to: %{eid: to_eid},
        from: %{eid: from_eid},
        device: device,
        signal_offset: so,
        user_offset: uo,
        eid: eid,
        signal_lifecycle_state: state
      } = payload) do

    queue = "#{from_eid}_#{to_eid}"
     IO.inspect(3)

    send_signal(
      id, so, uo, @status,
      %{eid: eid, connection_resource_id: device},
      payload.to,
      queue,
      device,
      @partition_id,
      state
    )
  end

  # ---------------------------------------------------
  # DEVICE → Advance offset, then reply
  # ---------------------------------------------------
  def device(%Chat.SignalStruct{
        id: id,
        to: %{eid: to_eid},
        from: %{eid: from_eid},
        device: device,
        signal_offset: so,
        user_offset: uo,
        eid: eid,
        signal_lifecycle_state: state
      } = payload) do

    queue = "#{from_eid}_#{to_eid}"
      IO.inspect(1)
    commit =
      if confirm_advance_offset(queue, device, @partition_id, so) do
        :ok
      else
        case maybe_advance_offset(queue, device, @partition_id, so, false) do
          {:ok, _} -> :ok
          {:error, _} -> :skip
        end
      end

    if commit == :ok do
      send_signal(
        id, so, uo, @status,
        %{eid: eid, connection_resource_id: device},
        payload.to,
        queue,
        device,
        @partition_id,
        state
      )
    end
  end

  # ---------------------------------------------------
  # RECEIVER → delivered/read ack + forward ack to sender
  # ---------------------------------------------------
  def receiver(%Chat.SignalStruct{
        id: id,
        to: %{eid: to_eid, connection_resource_id: to_dev},
        from: %{eid: from_eid, connection_resource_id: from_dev},
        device: device,
        signal_offset: so,
        user_offset: uo,
        signal_lifecycle_state: state
      } = payload) do

    queue = "#{from_eid}_#{to_eid}"
    rev   = "#{to_eid}_#{from_eid}"

    commit =
      case String.to_existing_atom(state) do
        :delivered ->
          mark_ack_status(queue, "", @partition_id, so, :delivered)
          mark_ack_status(rev, "", @partition_id, uo, :delivered)
          maybe_advance_offset(queue, device, @partition_id, so, false)
          :ok

        :read ->
          mark_ack_status(queue, "", @partition_id, so, :read)
          mark_ack_status(rev, "", @partition_id, uo, :read)
          maybe_advance_offset(queue, device, @partition_id, so, false)
          :ok

        _ ->
          :error
      end

    if commit == :ok do
      fan_out_sender_devices(
        id, so, uo, @status,
        %{eid: from_eid, connection_resource_id: device},
        payload.to,
        queue,
        device,
        @partition_id,
        state
      )

    end
  end

  # ---------------------------------------------------
  # Helpers
  # ---------------------------------------------------
  defp get_ack_status(user, device, part, offset),
    do: Injection.get_ack_status(user, device, part, offset)

  defp confirm_advance_offset(u, d, p, o),
    do: Injection.confirm_advance_offset(u, d, p, o)

  defp maybe_advance_offset(q, d, p, o, true), do: {:ok, o}
  defp maybe_advance_offset(q, d, p, o, false),
    do: Injection.advance_offset(q, d, p, o)

  defp mark_ack_status(q, d, p, o, state),
    do: Injection.mark_ack_status(q, d, p, o, state)

  # ---------------------------------------------------
  # Build ack signal
  # ---------------------------------------------------
  defp send_signal(id, so, uo, status, from, to, user, dev, part, state) do

    %{read: r, sent: s, delivered: d} =
      get_ack_status(user, dev, part, so)

    adv = confirm_advance_offset(user, dev, part, so)

    rt = set_signal(
      id, so, uo, status, to, from, state, s, d, r, adv
    )

    rt
    |> route()

  end

  def set_signal(id, so, uo, status, to, from, state, s, d, r, adv) do
    %{
      id: id,
      signal_offset: so,
      user_offset: uo,
      status: status,
      from: to,
      to: from,
      signal_type: 1,
      signal_request: 2,
      signal_lifecycle_state: state,
      signal_ack_state: %{send: s, delivered: d, read: r, advance_offset: adv}
    }
  end

  # ---------------------------------------------------
  # Routing
  # ---------------------------------------------------
  def route(payload) do
    payload
    |> ThrowSignalSchema.success()
    |> then(&SignalCommunication.outbouce(payload.to, &1))
  end

  def fan_out_sender_devices(id, so, uo, status, from, to, user, dev, part, state) do

    now = DateTime.utc_now()
    DeviceStorage.fetch_devices_by_eid(from.eid)
    |> Stream.filter(&(&1.status == "ONLINE" and DateTime.diff(now, &1.last_seen) <= @stale_threshold_seconds))
    |> Task.async_stream(
      fn device ->

        %{read: r, sent: s, delivered: d} = get_ack_status(user, "", part, so)
        adv = confirm_advance_offset(user, device.device_id, part, so)

        set_signal(id, so, uo, status, to, from, state, s, d, r, adv)
        |> ThrowSignalSchema.success()
        |> then(&SignalCommunication.outbouce(%{eid: device.eid, connection_resource_id: device.device_id}, &1))

      end,
      max_concurrency: 10,
      timeout: 5_000,
      on_timeout: :kill_task
    )
    |> Stream.run()
    :ok
  end


end
