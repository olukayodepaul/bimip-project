defmodule WebApiElection.ExternalSocket.Connection do
  use WebSockex
  require Logger

  @max_backoff_ms 30_000
  @ping_interval_ms 25_000

  @doc """
  Starts a socket process tied to a specific user_id.
  """
  def start_link(opts) do
    user_id = Keyword.fetch!(opts, :user_id)
    token = Keyword.fetch!(opts, :token)
    raw_url = Keyword.fetch!(opts, :url)

    url = String.replace(raw_url, ~r/^ws:\/\//, "wss://")
    uri = URI.parse(url)

    auth_val = if String.starts_with?(token, "Bearer "), do: token, else: "Bearer #{token}"

    extra_headers = [
      {"origin", "https://#{uri.host}"},
      {"token", auth_val},
      {"authorization", auth_val},
      {"ngrok-skip-browser-warning", "true"},
      {"user-agent", "PostmanRuntime/7.39.0"}
    ]

    name = via_tuple(user_id)

    state = %{
      user_id: user_id,
      token: token,
      eid: "bim#{user_id}@bimip.com",
      reconnect_attempts: 0,
      ping_timer: nil
    }

    WebSockex.start_link(
      url,
      __MODULE__,
      state,
      name: name,
      extra_headers: extra_headers,
      insecure: true,
      async: true,
      handle_initial_conn_failure: true
    )
  end

  def via_tuple(user_id) do
    {:via, Registry, {WebApiElection.UserSocketRegistry, user_id}}
  end

  defp dispatch_map do
    %{
      3 => &handle_ping_ack/2,
      6 => &handle_message/2
    }
  end

  # --- WebSockex Callbacks ---

  @impl true
  def handle_connect(_conn, state) do
    Logger.info("🟢 WebSocket connected for User ID: #{state.user_id}")

    # Cancel any lingering timer and schedule a fresh keep-alive ping loop
    cancel_ping_timer(state)
    timer_ref = schedule_ping()

    {:ok, %{state | reconnect_attempts: 0, ping_timer: timer_ref}}
  end

  @impl true
  def handle_frame({:binary, data}, state) do
    if data == <<>> do
      {:ok, state}
    else
      case safe_decode_route(data) do
        {:ok, route, decoded} ->
          dispatch_map()
          |> Map.get(route, &default_handler/2)
          |> then(fn handler -> handler.(state, decoded) end)

        {:error, reason} ->
          Logger.error("Failed to decode route: #{inspect(reason)}")
          {:ok, state}
      end
    end
  end

  def handle_frame({:text, _msg}, state), do: {:ok, state}
  def handle_frame({_type, _msg}, state), do: {:ok, state}

  # --- Keep-alive ping loop ---

  @impl true
  def handle_info(:send_ping, state) do
    binary_ping = build_ping_frame(state)
    timer_ref = schedule_ping()
    new_state = %{state | ping_timer: timer_ref}

    {:reply, {:binary, binary_ping}, new_state}
  end

  def handle_info(_msg, state), do: {:ok, state}

  @impl true
  def handle_pong(_pong_frame, state) do
    {:ok, state}
  end

  defp build_ping_frame(state) do
    Bimip.MessageScheme.encode(%Bimip.MessageScheme{
      route_id: 3,
      payload:
        {:ping,
        %Bimip.Ping{
          id: Ecto.UUID.generate(),
          from: %Bimip.Identity{eid: state.eid},
          type: 1,
          timestamp: System.system_time(:millisecond)
        }}
    })
  end

  defp schedule_ping do
    Process.send_after(self(), :send_ping, @ping_interval_ms)
  end

  defp cancel_ping_timer(%{ping_timer: nil}), do: :ok

  defp cancel_ping_timer(%{ping_timer: ref}) do
    Process.cancel_timer(ref)

    receive do
      :send_ping -> :ok
    after
      0 -> :ok
    end
  end

  # --- Ping ack from server ---

  defp handle_ping_ack(state, %Bimip.MessageScheme{payload: {:ping, ping}}) do
    IO.inspect(ping, label: "📥 PING RAW INCOMING WEBSOCKET BINARY")
    {:ok, state}
  end

  defp handle_ping_ack(state, _decoded), do: {:ok, state}

  # --- Message handling ---

  defp handle_message(state, %Bimip.MessageScheme{payload: {:message, message}}) do
    IO.inspect(message, label: "📥 RAW INCOMING 1")
    with {:ok, outer} <- Jason.decode(message.payload),
         {:ok, inner} <- decode_inner_message(outer),
         {:ok, user_id} <- parse_user_id(outer["user_id"]) do
      case outer["category"] do
        "1" -> insert_message(state, user_id, outer, inner)
        "2" -> insert_polling_unit_report(state, user_id, outer, inner)
        "3" -> insert_polling_unit_security_report(state, user_id, outer, inner)
        "4" -> insert_ward_security_report(state, user_id, outer, inner)
        "5" -> insert_party_agent_report(state, user_id, outer, inner)
        _ -> :ok
      end
    else
      {:error, reason} ->
        Logger.error("Failed to parse message payload: #{inspect(reason)}")
    end

    {:ok, state}
  end

  defp insert_polling_unit_report(state, user_id, outer, inner) do
    IO.inspect(outer, label: "📥 RAW INCOMING 2")

    case WebApiElection.Reporting.PollingUnitReportQuery.insert_report(
          user_id,
          outer["id"],
          outer["polling_unit_code"],
          outer["ward_code"],
          outer["lg_code"],
          outer["state_code"],
          inner
        ) do
      {:ok, report} ->
        broadcast_report(state, report)

        %WebApiElection.Reporting.PollingUnitReport{payload: payload, user_id: report_user_id} = report

        inec_ar_time =
          case outer["timestamp"] do
            ms when is_integer(ms) -> DateTime.from_unix!(ms, :millisecond)
            _ -> nil
          end

        report_user_id =
          case report_user_id do
            val when is_binary(val) -> String.to_integer(val)
            val when is_integer(val) -> val
            _ -> nil
          end

        attrs = %{
          inec_ar_time:        inec_ar_time,
          official_no:         payload["numberOfInecOfficial"] && to_string(payload["numberOfInecOfficial"]),
          is_bvas_available:   payload["isBvnMachineAvail"],
          is_bvas_working:     payload["isBvbDeviceGoodCond"],
          is_voters_verify:    payload["isVotersVerifyWithBvas"],
          has_accr_commence:   payload["hasAccredCommence"],
          has_voting_commence: payload["hasVolingCommence"],
          is_voters_verify_with_bvas: payload["isVotersVerifyWithBvas"]
        }

        case WebApiElection.Elections.ElecCurrentStateQuery.upsert_state(report_user_id, attrs) do
          {:ok, _updated} ->
            :ok

          {:error, :not_found} ->
            Logger.error("No elec_current_state row for user_id=#{report_user_id}")

          {:error, changeset} ->
            Logger.error("Failed to update elec_current_state: #{inspect(changeset)}")
        end

      {:error, changeset} ->
        Logger.error("Failed to insert field report: #{inspect(changeset)}")
    end
  end

  defp insert_polling_unit_security_report(state, user_id, outer, inner) do
    case WebApiElection.Reporting.PollingUnitSecurityReportQuery.insert_report(
           user_id,
           outer["id"],
           outer["polling_unit_code"],
           outer["ward_code"],
           outer["lg_code"],
           outer["state_code"],
           inner
         ) do
      {:ok, report} ->
        broadcast_report(state, report)

        %WebApiElection.Reporting.PollingSecuriyReport{payload: payload, user_id: report_user_id} = report

        report_user_id =
          case report_user_id do
            val when is_binary(val) -> String.to_integer(val)
            val when is_integer(val) -> val
            _ -> nil
          end

        attrs = %{
          security_present: payload["isSecurityPersonPresent"]
        }

        case WebApiElection.Elections.ElecCurrentStateQuery.update_security(report_user_id, attrs) do
          {:ok, _updated} ->
            :ok

          {:error, :not_found} ->
            Logger.error("No elec_current_state row for user_id=#{report_user_id}")

          {:error, changeset} ->
            Logger.error("Failed to update security state: #{inspect(changeset)}")
        end

        IO.inspect(attrs, label: "📥 RAW INCOMING 1000")

      {:error, changeset} ->
        Logger.error("Failed to insert security report: #{inspect(changeset)}")
    end
  end

  defp insert_ward_security_report(state, user_id, outer, inner) do
    case WebApiElection.Reporting.WardSecurityReportQuery.insert_report(
           user_id,
           outer["id"],
           outer["polling_unit_code"],
           outer["ward_code"],
           outer["lg_code"],
           outer["state_code"],
           inner
         ) do
      {:ok, report} ->

        broadcast_report(state, report)

        %WebApiElection.Reporting.WardSecurityReport{payload: payload, user_id: report_user_id} = report

          report_user_id =
          case report_user_id do
            val when is_binary(val) -> String.to_integer(val)
            val when is_integer(val) -> val
            _ -> nil
          end

          attrs = %{
            has_proceed_to_ward: payload["isInecOfficialProceedToWardCollationCenter"],
            is_pu_officer_at_collation_center: payload["isPuOfficialArriveAtCollationCenter"],
            is_inec_officer_same_as_pu_officer: payload["isInecOfficialSameAsPuOfficer"],
            is_inec_officer_at_collation_center: payload["isInecOfficialArriveAtCollationCenter"]
          }

          case WebApiElection.Elections.ElecCurrentStateQuery.update_ward_security(report_user_id, attrs) do
            {:ok, _updated} ->
              :ok

            {:error, :not_found} ->
              Logger.error("No elec_current_state row for user_id=#{report_user_id}")

            {:error, changeset} ->
              Logger.error("Failed to update security state: #{inspect(changeset)}")
          end

      {:error, changeset} ->
        Logger.error("Failed to insert ward security report: #{inspect(changeset)}")
    end
  end

  defp insert_party_agent_report(state, user_id, outer, inner) do
    case WebApiElection.Reporting.PartyAgentReportQuery.insert_report(
           user_id,
           outer["id"],
           outer["polling_unit_code"],
           outer["ward_code"],
           outer["lg_code"],
           outer["state_code"],
           inner
         ) do
      {:ok, report} ->

        broadcast_report(state, report)

        %WebApiElection.Reporting.PartyAgentReport{payload: payload, user_id: report_user_id} = report

          report_user_id =
            case report_user_id do
              val when is_binary(val) -> String.to_integer(val)
              val when is_integer(val) -> val
              _ -> nil
            end

          attrs = %{
            is_agent_at_polling_unit: payload["isAtAssignedUnit"],
            did_inec_clear_agent: payload["isAgentVerifiedByInec"]
          }

          case WebApiElection.Elections.ElecCurrentStateQuery.update_party_agent_security(report_user_id, attrs) do
            {:ok, _updated} ->
              :ok

            {:error, :not_found} ->
              Logger.error("No elec_current_state row for user_id=#{report_user_id}")

            {:error, changeset} ->
              Logger.error("Failed to update security state: #{inspect(changeset)}")
          end

      {:error, changeset} ->
        Logger.error("Failed to insert party agent report: #{inspect(changeset)}")
    end
  end

  defp insert_message(state, user_id, outer, _inner) do
    msg_type = outer["msg_type"]

    payload_string =
      case msg_type do
        "TEXT" -> outer["message"] || ""
        "IMAGE" -> outer["remote_media_url"] || ""
        "VIDEO" -> outer["remote_media_url"] || ""
        _ -> ""
      end

    case WebApiElection.Reporting.MessageQuery.insert_message(
           user_id,
           outer["id"],
           outer["polling_unit_code"],
           outer["ward_code"],
           outer["lg_code"],
           outer["state_code"],
           payload_string,
           msg_type || "TEXT",
           0,
           "SENT"
         ) do
      {:ok, message} ->

        broadcast_report(state, message)

      {:error, changeset} ->
        Logger.error("Failed to insert message: #{inspect(changeset.errors)}")
    end
  end

  defp broadcast_report(state, report) do
    Phoenix.PubSub.broadcast(
      WebApiElection.PubSub,
      "inec_official:#{state.user_id}",
      {:inec_official, report}
    )
  end

  defp parse_user_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> {:ok, int}
      _ -> {:error, {:invalid_user_id, id}}
    end
  end

  defp parse_user_id(id) when is_integer(id), do: {:ok, id}
  defp parse_user_id(id), do: {:error, {:invalid_user_id, id}}

  defp decode_inner_message(%{"message" => inner_str}) when is_binary(inner_str) do
    case Jason.decode(inner_str) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> {:ok, inner_str}
    end
  end

  defp decode_inner_message(_outer), do: {:ok, nil}

  defp default_handler(state, decoded) do
    Logger.warning("Unhandled route_id=#{decoded.route_id} for user #{state.user_id}")
    {:ok, state}
  end

  defp safe_decode_route(data) do
    with %Bimip.MessageScheme{route_id: route} = decoded <- Bimip.MessageScheme.decode(data) do
      {:ok, route, decoded}
    else
      _ -> {:error, :invalid_route}
    end
  rescue
    e -> {:error, e}
  end

  @impl true
  def handle_disconnect(disconnect_map, state) do
    cancel_ping_timer(state)

    attempts = state.reconnect_attempts + 1

    Logger.error(
      "🔴 User #{state.user_id} disconnected: #{inspect(disconnect_map)}. " <>
        "Attempting reconnect (Attempt ##{attempts})..."
    )

    # Allow WebSockex to handle reconnects without blocking execution loops
    {:reconnect, %{state | reconnect_attempts: attempts, ping_timer: nil}}
  end

  def send_chat_message(message) do
    IO.inspect(message, label: "📥 1 GET DECODE MESSAGE")

    frame = build_message_frame(message)

    IO.inspect(frame, label: "📥 2 GET DECODE MESSAGE")

    case Registry.lookup(WebApiElection.UserSocketRegistry, message.from) do
      [{pid, _}] ->
        case WebApiElection.Reporting.MessageQuery.insert_message(
              message.to,
              Ecto.UUID.generate(),
              message.pu_code,
              message.ward_code,
              message.lg_code,
              message.state_code,
              message.message,
              "TEXT",
              1,
              "SENT"
            ) do
          {:ok, _saved_message} ->
            :ok

          {:error, changeset} ->
            Logger.error("Failed to insert outgoing message: #{inspect(changeset.errors)}")
        end

        WebSockex.send_frame(pid, {:binary, frame})
        :ok

      [] ->
        {:error, :not_connected}
    end
  end

  defp build_message_frame(message) do
    id = Ecto.UUID.generate()
    timestamp = System.system_time(:millisecond)

    payload_json =
      Jason.encode!(%{
        "id" => id,
        "category" => "1",
        "sub_category" => "1",
        "sub_sub_category" => "0",
        "type" => "TEXT",
        "msg_type" => "TEXT",
        "message" => message.message,
        "leadingType" => "1",
        "trailType" => "1",
        "msg_state" => 0,
        "polling_unit_code" => message.pu_code,
        "ward_code" => message.ward_code,
        "lg_code" => message.lg_code,
        "state_code" => message.state_code,
        "user_id" => to_string(message.to),
        "timestamp" => timestamp,
        "owner" => 0
      })

      from_eid = "bim#{message.from}@bimip.com"
      to_eid = "bim#{message.to}@bimip.com"

    Bimip.MessageScheme.encode(%Bimip.MessageScheme{
      route_id: 6,
      payload:
        {:message,
          %Bimip.Message{
            id: id,
            from: %Bimip.Identity{eid: from_eid},
            to: %Bimip.Identity{eid: to_eid},
            timestamp: timestamp,
            payload: payload_json,
            delivery_type: 1,
            participant_role: 1,
            content_type: 1,
            message_type: 1,
            ephemeral_public_key: <<>>,
            mac: <<>>
          }
        }
    })
  end


end
