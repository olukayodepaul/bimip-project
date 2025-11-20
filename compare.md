Compare


%Bimip.MessageScheme{
  route: 6,
  payload: {:message,
   %Bimip.Message{
     id: "1",
     signal_offset: 2,
     user_offset: 2,
     from: %Bimip.Identity{
       eid: "b@domain.com",
       connection_resource_id: "bbbbb1",
       node: nil,
       __unknown_fields__: []
     },
     to: %Bimip.Identity{
       eid: "a@domain.com",
       connection_resource_id: "aaaaa1",
       node: nil,
       __unknown_fields__: []
     },
     timestamp: 1763621287733,
     payload: "{\"text\":\"Hello! Check out these items 👋\",\"files\":[{\"size\":1024000,\"filename\":\"MonthlyReport.pdf\",\"url\":\"https://example.com/report.pdf\"}],\"images\":[{\"url\":\"https://example.com/image1.png\",\"caption\":\"Sunset view\"},{\"url\":\"https://example.com/image2.png\",\"caption\":\"Coffee moment\"}],\"reactions\":[{\"user\":\"bob@domain.com\",\"emoji\":\"👍\"},{\"user\":\"carol@domain.com\",\"emoji\":\"❤️\"}],\"mentions\":[{\"eid\":\"dave@domain.com\",\"display_name\":\"Dave\"}],\"custom_data\":{\"poll\":{\"options\":[\"Elixir\",\"Go\",\"Rust\"],\"question\":\"Which framework do you prefer?\",\"votes\":{\"alice@domain.com\":\"Elixir\",\"bob@domain.com\":\"Go\"}}}}",
     encryption_type: "none",
     encrypted: "",
     signature: "",
     signal_type: 3,
     signal_offset_state: false,
     signal_ack_state: %Bimip.SignalAckState{
       send: true,
       received: false,
       read: false,
       __unknown_fields__: []
     },
     signal_request: 2,
     __unknown_fields__: []
   }},
  __unknown_fields__: []


%Bimip.MessageScheme{
  route: 6,
  payload: {:message,
   %Bimip.Message{
     id: "1",
     signal_offset: 2,
     user_offset: 2,
     from: %Bimip.Identity{
       eid: "b@domain.com",
       connection_resource_id: "bbbbb1",
       node: nil,
       __unknown_fields__: []
     },
     to: %Bimip.Identity{
       eid: "a@domain.com",
       connection_resource_id: "aaaaa1",
       node: nil,
       __unknown_fields__: []
     },
     timestamp: 1763621287733,
     payload: "{\"text\":\"Hello! Check out these items 👋\",\"files\":[{\"size\":1024000,\"filename\":\"MonthlyReport.pdf\",\"url\":\"https://example.com/report.pdf\"}],\"images\":[{\"url\":\"https://example.com/image1.png\",\"caption\":\"Sunset view\"},{\"url\":\"https://example.com/image2.png\",\"caption\":\"Coffee moment\"}],\"reactions\":[{\"user\":\"bob@domain.com\",\"emoji\":\"👍\"},{\"user\":\"carol@domain.com\",\"emoji\":\"❤️\"}],\"mentions\":[{\"eid\":\"dave@domain.com\",\"display_name\":\"Dave\"}],\"custom_data\":{\"poll\":{\"options\":[\"Elixir\",\"Go\",\"Rust\"],\"question\":\"Which framework do you prefer?\",\"votes\":{\"alice@domain.com\":\"Elixir\",\"bob@domain.com\":\"Go\"}}}}",
     encryption_type: "none",
     encrypted: "",
     signature: "",
     signal_type: 3,
     signal_offset_state: false,
     signal_ack_state: %Bimip.SignalAckState{
       send: true,
       received: false,
       read: false,
       __unknown_fields__: []
     },
     signal_request: 2,
     __unknown_fields__: []
   }},
  __unknown_fields__: []
}}


%Bimip.MessageScheme{
  route: 6,
  payload: {:message,
   %Bimip.Message{
     id: "1",
     signal_offset: 2,
     user_offset: 2,
     from: %Bimip.Identity{
       eid: "b@domain.com",
       connection_resource_id: "bbbbb1",
       node: nil,
       __unknown_fields__: []
     },
     to: %Bimip.Identity{
       eid: "a@domain.com",
       connection_resource_id: "aaaaa1",
       node: nil,
       __unknown_fields__: []
     },
     timestamp: 1763622941849,
     payload: "{\"text\":\"Hello! Check out these items 👋\",\"files\":[{\"size\":1024000,\"filename\":\"MonthlyReport.pdf\",\"url\":\"https://example.com/report.pdf\"}],\"images\":[{\"url\":\"https://example.com/image1.png\",\"caption\":\"Sunset view\"},{\"url\":\"https://example.com/image2.png\",\"caption\":\"Coffee moment\"}],\"reactions\":[{\"user\":\"bob@domain.com\",\"emoji\":\"👍\"},{\"user\":\"carol@domain.com\",\"emoji\":\"❤️\"}],\"mentions\":[{\"eid\":\"dave@domain.com\",\"display_name\":\"Dave\"}],\"custom_data\":{\"poll\":{\"options\":[\"Elixir\",\"Go\",\"Rust\"],\"question\":\"Which framework do you prefer?\",\"votes\":{\"alice@domain.com\":\"Elixir\",\"bob@domain.com\":\"Go\"}}}}",
     encryption_type: "none",
     encrypted: "",
     signature: "",
     signal_type: 2,
     signal_offset_state: false,
     signal_ack_state: %Bimip.SignalAckState{
       send: true,
       received: false,
       read: false,
       __unknown_fields__: []
     },
     signal_request: 1,
     __unknown_fields__: []
   }},
  __unknown_fields__: []
}
iex(2)> 