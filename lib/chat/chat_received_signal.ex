defmodule Chat.ReceivedSignal do

  alias Chat.ResumeSignal

  def handle_received_signal(%Chat.ResumeStruct{status: status} = payload) do

    case status do
      7 ->
        ResumeSignal.resume(payload)
    end

  end

end
