### Subscription Request

```proto

subscribe_request = %Bimip.SubscribeRequest{
  from: %Bimip.Identity{
    eid: "a@domain.com",
    connection_resource_id: nil
  },
  to: %Bimip.Identity{
    eid: "d@domain.com",
    connection_resource_id: nil
  },
  subscription_id: "ancisdcsad",
  one_way: false,
  timestamp: System.system_time(:millisecond)
}

is_subscribe_request = %Bimip.MessageScheme{
  route: 6,
  payload: {:subscribe_request, subscribe_request}
}

binary = Bimip.MessageScheme.encode(is_subscribe_request)
hex    = Base.encode16(binary, case: :upper)

080632330A0E0A0C6140646F6D61696E2E636F6D120E0A0C6440646F6D61696E2E636F6D1A0A616E636973646373616428CDE787BB9333

```

### Subscription Response

```proto

subscribe_response = %Bimip.SubscribeResponse{
  from: %Bimip.Identity{
    eid: "d@domain.com",
    connection_resource_id: nil
  },
  to: %Bimip.Identity{
    eid: "a@domain.com",
    connection_resource_id: nil
  },
  status: 2,
  message: "This is the message",
  subscription_id: "ancisdcsad",
  one_way: false,
  timestamp: System.system_time(:millisecond)
}

is_subscribe_response = %Bimip.MessageScheme{
  route: 7,
  payload: {:subscribe_response, subscribe_response}
}

binary = Bimip.MessageScheme.encode(is_subscribe_response)
hex    = Base.encode16(binary, case: :upper)

//1=ACCEPTED,
08073A4A0A0E0A0C6440646F6D61696E2E636F6D120E0A0C6140646F6D61696E2E636F6D180122135468697320697320746865206D65737361676528CAF69CBB9333320A616E6369736463736164

//2=REJECTED
08073A4A0A0E0A0C6440646F6D61696E2E636F6D120E0A0C6140646F6D61696E2E636F6D180222135468697320697320746865206D65737361676528C2979FBB9333320A616E6369736463736164

```
