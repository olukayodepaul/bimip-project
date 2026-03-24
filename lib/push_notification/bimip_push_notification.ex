defmodule Bimip.Push.Dispatcher do
  require Logger

  @doc """
  Dispatches a WAKE signal.
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
        "reason" => reason,
        "from" => from_eid
      })

    notification = if reason == "CALL",
      do: Pigeon.APNS.Notification.put_priority(notification, 10),
      else: notification

    push_async(:apns, notification)
  end

  # --- Android Logic ---
  defp dispatch_android(%{d_tok: token}, from_eid, reason) do
    # For Pigeon 1.6 Legacy FCM, targets MUST be a list of strings.
    # Do NOT use {:token, token} or [token: token] as they cause EncodeErrors.
    targets = [token]

    notification = Pigeon.FCM.Notification.new(
      targets,
      %{}, # Notification body (empty for silent data-only push)
      %{
        "type" => "WAKE",
        "reason" => reason,
        "from" => from_eid
      }
    )
    |> Pigeon.FCM.Notification.put_priority(:high)

    push_async(:fcm, notification)
  end

  # --- Async Dispatcher ---
  defp push_async(service, notification) do
    worker = if service == :apns, do: :apns_default, else: :fcm_default

    Task.start(fn ->
      # In Pigeon 1.6, use the module-specific push
      case service do
        :apns -> Pigeon.APNS.push(notification, to: worker)
        :fcm  -> Pigeon.FCM.push(notification, to: worker)
      end
      |> handle_response()
    end)
  end

  defp handle_response(notification) do
    # Pigeon 1.6 returns the notification struct.
    # 'status' is usually nil or :success depending on the adapter state.
    # 'response' contains the result list from the provider.
    case notification.status do
      :success -> :ok
      _ ->
        # Log the response list to see specific error strings (e.g., "InvalidRegistration")
        Logger.error("Push Dispatch Result: #{inspect(notification.response)}")
    end
  end
end
