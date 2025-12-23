defmodule ThrowMessagePeerAckSignalSchema do

  @method 2
  @status_code 200

  def build(%{
    offset: offset,
    message_id: message_id,
    from: from,
    to: to,
    peer: peer
  }) do

    message_peer_ack_signal = %Bimip.MessagePeerAckSignal{
      offset: offset,
      message_id: message_id,
      from: from,
      to: to,
      method: @method,
      timestamp: Until.UniPosTime.uni_pos_time(),
      status_code: @status_code,
      peer: peer
    }

    %Bimip.MessageScheme{
      route: 13,
      payload: {:message_peer_ack_signal, message_peer_ack_signal}
    }
    |> Bimip.MessageScheme.encode()
  end
end
