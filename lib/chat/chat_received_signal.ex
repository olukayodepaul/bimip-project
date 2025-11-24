defmodule Chat.ReceivedSignal do
  alias Chat.{ResumeSignal, AckSignal}

  @handlers %{
    1 => &AckSignal.ack/1,
    7 => &ResumeSignal.resume/1
  }

  def handle_received_signal(%Chat.SignalStruct{status: status} = payload) do
    case Map.get(@handlers, status) do
      nil ->
        IO.puts("Unknown signal status: #{status}")

      handler ->
        handler.(payload)
    end
  end
end
