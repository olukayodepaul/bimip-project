defmodule Chat.AckSignal do
  alias Queue.Injection
  alias Route.SignalCommunication

  @partition_id 1

  @handlers %{
    1 => &sender/1,
    2 => &device/1,
    3 => &receiver/1
  }

  def ack(%Chat.SignalStruct{} = signal) do
    # Pick the value that decides the handler
    signal_type = signal.signal_type

    case Map.get(@handlers, signal_type) do
      nil ->
        IO.puts("Unknown signal type: #{signal_type}")

      handler ->
        handler.(signal)
    end
  end

  def sender(payload) do

    IO.inspect(payload, label: "SENDER handler received")
  end

  def device(payload) do
    IO.inspect(payload, label: "DEVICE handler received")
  end

  def receiver(payload) do
    IO.inspect(payload, label: "RECEIVER handler received")
  end
end
