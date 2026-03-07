defmodule ThrowMessageDeliveryReceiptsSchema do

  @route_id 13

  def build(id, from, to, offset, timestamp) do

    message_delivery_receipts = %Bimip.MessageDeliveryReceipts{
       id: id,
      from: from,
      to: to,
      offset: offset,
      timestamp: timestamp
    }

    %Bimip.MessageScheme{
      route_id: @route_id,
      payload: {:message_delivery_receipts, message_delivery_receipts}
    }
    |> Bimip.MessageScheme.encode()
  end
end
