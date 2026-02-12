defmodule ThrowMessagePeerAckSignalSchema do

  @method 2
  @status_code 200

  def build(%{
    offset: offset,
    from: from,
    to: to,
    peer_uid: peer_uid,
    reply_to: reply_to
  }) do

    message_ack_signal = %Bimip.MessageAckSignal{
      offset: offset,
      peer_uid: peer_uid,
      from: from,
      to: to,
      method: @method,
      timestamp: Until.UniPosTime.uni_pos_time(),
      status_code: @status_code,
      reply_to: reply_to
    }

    %Bimip.MessageScheme{
      route: 13,
      payload: {:message_ack_signal, message_ack_signal}
    }
    |> Bimip.MessageScheme.encode()
  end
end
