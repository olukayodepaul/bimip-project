defmodule Bimip.Push.Dispatcher do
  require Logger

  @doc """
  Dispatches a WAKE signal.
  'reason' should be "MESSAGE" or "CALL".
  """
  def send_wake_signal(meta, from_eid, reason \\ "MESSAGE") do
    case meta.plat do
      "ios" -> dispatch_ios(meta, from_eid, reason)
      "android" -> dispatch_android(meta, from_eid, reason)
      _ -> Logger.warning("Unknown platform for #{meta.eid}")
    end
  end

  # --- iOS Logic ---
  defp dispatch_ios(%{d_tok: token, app_id: app_id}, from_eid, reason) do
    notification =
      Pigeon.APNS.Notification.new("", token, app_id)
      |> Pigeon.APNS.Notification.put_content_available(true)
      |> Pigeon.APNS.Notification.put_custom(%{
        "type" => "WAKE",
        "reason" => reason, # "MESSAGE" or "CALL"
        "from" => from_eid
      })

    # For Calls, we increase priority to 10 (immediate)
    notification = if reason == "CALL",
      do: Pigeon.APNS.Notification.put_priority(notification, 10),
      else: notification

    push_async(:apns, notification)
  end

  # --- Android Logic ---
  defp dispatch_android(%{d_tok: token}, from_eid, reason) do
    notification = Pigeon.FCM.Notification.new(%{
      "message" => %{
        "token" => token,
        "android" => %{ "priority" => "high" },
        "data" => %{
          "type" => "WAKE",
          "reason" => reason,
          "from" => from_eid
        }
      }
    })

    push_async(:fcm, notification)
  end

  defp push_async(service, notification) do
    worker = if service == :apns, do: :apns_default, else: :fcm_default
    Task.start(fn ->
      Pigeon.push(notification, on: worker)
      |> handle_response()
    end)
  end

  defp handle_response({:ok, _}), do: :ok
  defp handle_response({:error, reason}), do: Logger.error("Push Error: #{inspect(reason)}")
end


# # Inside your message handling logic
# Bimip.Push.Dispatcher.send_wake_signal(meta, message.from.eid, "MESSAGE")

# # Inside your call signaling logic
# Bimip.Push.Dispatcher.send_wake_signal(meta, call_initiator_eid, "CALL")

# if (remoteMessage.data["type"] == "WAKE") {
#     // Start your BimipClient connection service
#     val intent = Intent(this, BimipSyncService::class.java)
#     startForegroundService(intent)
# }

# func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable : Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
#     if let type = userInfo["type"] as? String, type == "WAKE" {
#         // Connect to bimIPs and fetch messages
#         BimipClient.shared.connect { success in
#             completionHandler(success ? .newData : .failed)
#         }
#     }
# }
