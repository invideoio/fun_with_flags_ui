defmodule FunWithFlags.UI.Router do
  @moduledoc """
  A `Plug.Router`. This module is meant to be plugged into host applications.

  See the [Readme](/fun_with_flags_ui/readme.html#how-to-run) for more detailed instructions.
  """
  require Logger
  use Plug.Router
  alias FunWithFlags.UI.{SimpleActor, Templates, Utils}

  if Mix.env == :dev do
    use Plug.Debugger, otp_app: :fun_with_flags_ui
  end

  plug Plug.Logger, log: :debug

  plug Plug.Static,
    gzip: true,
    at: "/assets",
    from: :fun_with_flags_ui

  plug :protect_from_forgery, Plug.CSRFProtection.init([])

  plug Plug.Parsers, parsers: [:urlencoded, :multipart], length: 10_000_000
  plug Plug.MethodOverride

  plug :assign_csrf_token
  plug :match
  plug :dispatch

  defp import_disabled? do
    System.get_env("APP_ENV") != "dev"
  end

  defp get_audit_user_id(conn) do
    header = FunWithFlags.Config.audit_log_user_id_header()
    case Plug.Conn.get_req_header(conn, header) do
      [user_id | _] -> user_id
      _ -> nil
    end
  end

  defp audit_opts(conn) do
    case get_audit_user_id(conn) do
      nil -> []
      user_id -> [audit: [user_id: user_id]]
    end
  end

  @doc false
  def call(conn, opts) do
    conn = extract_namespace(conn, opts)
    super(conn, opts)
  end


  get "/" do
    conn
    |> redirect_to("/flags")
  end


  # form to create a new flag
  #
  get "/new" do
    conn
    |> html_resp(200, Templates.new(%{conn: conn}))
  end


  # endpoint to create a new flag
  #
  post "/flags" do
    name = Utils.sanitize(conn.params["flag_name"])

    case Utils.validate_flag_name(conn, name) do
      :ok ->
        case Utils.create_flag_with_name(name, audit_opts(conn)) do
          {:ok, _} -> redirect_to conn, flag_location(name)
          _ -> html_resp(conn, 400, Templates.new(%{conn: conn, error_message: "Something went wrong!"}))
        end
      {:fail, reason} ->
        html_resp(conn, 400, Templates.new(%{conn: conn, error_message: reason}))
    end
  end


  # The flags page: the list of flags, with nothing selected.
  #
  get "/flags" do
    render_flags_page(conn, 200, nil)
  end


  # The flags page with one flag selected, its panel rendered server-side.
  #
  get "/flags/:name" do
    render_flags_page(conn, 200, name)
  end


  # Just the panel of one flag, swapped in by the JS when a row is clicked.
  # It must not list all the flags.
  #
  get "/flags/:name/panel" do
    conn = put_resp_header(conn, "cache-control", "no-store")

    case Utils.get_flag(name) do
      {:ok, flag} ->
        assigns = [conn: conn, flag: flag] ++ fetch_flag_audit_logs(conn, name, conn.query_params)
        html_resp(conn, 200, Templates._flag_panel(assigns))
      {:error, _} ->
        html_resp(conn, 404, Templates._flag_panel_not_found(conn: conn, name: name))
    end
  end


  # to clear an entire flag
  #
  delete "/flags/:name" do
    name
    |> String.to_existing_atom()
    |> FunWithFlags.clear(audit_opts(conn))

    # The list says "Deleted <name>." once, carried in the session so only a
    # real deletion can produce it (see take_deleted_name/1).
    conn
    |> put_deleted_name(name)
    |> redirect_to("/flags")
  end


  # to toggle the default state of a flag
  #
  patch "/flags/:name/boolean" do
    enabled = Utils.parse_bool(conn.params["enabled"])
    flag_name = String.to_existing_atom(name)

    if enabled do
      FunWithFlags.enable(flag_name, audit_opts(conn))
    else
      FunWithFlags.disable(flag_name, audit_opts(conn))
    end

    redirect_to conn, flag_location(name)
  end


  # to clear a boolean gate
  #
  delete "/flags/:name/boolean" do
    flag_name = String.to_existing_atom(name)
    FunWithFlags.clear(flag_name, [boolean: true] ++ audit_opts(conn))
    redirect_to conn, flag_location(name)
  end


  # to toggle an actor gate
  #
  patch "/flags/:name/actors/:actor_id" do
    toggle_actor(conn, name, actor_id)
  end


  # to clear an actor gate
  #
  delete "/flags/:name/actors/:actor_id" do
    clear_actor(conn, name, actor_id)
  end


  # The same two, with the actor ID in the body (`actor_id`) instead of the
  # path. Used for IDs that can't be a path segment: "." and ".." are
  # dot-segments, which browsers resolve away, so a Clear form posting to
  # /flags/foo/actors/.. would DELETE /flags/foo, the whole flag.
  #
  patch "/flags/:name/actors" do
    with_body_target(conn, name, "actor_id", "actor ID", &toggle_actor/3)
  end

  delete "/flags/:name/actors" do
    with_body_target(conn, name, "actor_id", "actor ID", &clear_actor/3)
  end


  # to toggle a group gate
  #
  patch "/flags/:name/groups/:group_name" do
    toggle_group(conn, name, group_name)
  end


  # to clear a group gate
  #
  delete "/flags/:name/groups/:group_name" do
    clear_group(conn, name, group_name)
  end


  # Group name in the body (`group_name`); see the actor routes above.
  #
  patch "/flags/:name/groups" do
    with_body_target(conn, name, "group_name", "group name", &toggle_group/3)
  end

  delete "/flags/:name/groups" do
    with_body_target(conn, name, "group_name", "group name", &clear_group/3)
  end


  # to clear a percentage gate
  #
  delete "/flags/:name/percentage" do
    flag_name = String.to_existing_atom(name)
    FunWithFlags.clear(flag_name, [for_percentage: true] ++ audit_opts(conn))
    redirect_to conn, flag_location(name)
  end


  # to add a new actor to a flag
  #
  post "/flags/:name/actors" do
    flag_name = String.to_existing_atom(name)
    actor_id = Utils.sanitize(conn.params["actor_id"])

    case Utils.validate(actor_id) do
      :ok ->
        enabled = Utils.parse_bool(conn.params["enabled"])
        actor = %SimpleActor{id: actor_id}
        if enabled do
          FunWithFlags.enable(flag_name, [for_actor: actor] ++ audit_opts(conn))
        else
          FunWithFlags.disable(flag_name, [for_actor: actor] ++ audit_opts(conn))
        end
        redirect_to conn, flag_location(name, "actor_#{actor_id}")
      {:fail, reason} ->
        render_flags_page(conn, 400, name, actor_error_message: "The actor ID #{reason}.")
    end
  end


  # to add a new group to a flag
  #
  post "/flags/:name/groups" do
    flag_name = String.to_existing_atom(name)
    group_name = Utils.sanitize(conn.params["group_name"])

    case Utils.validate(group_name) do
      :ok ->
        enabled = Utils.parse_bool(conn.params["enabled"])
        if enabled do
          FunWithFlags.enable(flag_name, [for_group: group_name] ++ audit_opts(conn))
        else
          FunWithFlags.disable(flag_name, [for_group: group_name] ++ audit_opts(conn))
        end
        redirect_to conn, flag_location(name, "group_#{group_name}")
      {:fail, reason} ->
        render_flags_page(conn, 400, name, group_error_message: "The group name #{reason}.")
    end
  end


  # to add or replace a percentage gate
  #
  post "/flags/:name/percentage" do
    flag_name = String.to_existing_atom(name)
    type = Utils.parse_percentage_type(conn.params["percent_type"])

    # The panel's form says which unit it sends (`percent_unit=percent`,
    # rendered by the server, so the label and the parse always agree);
    # without it the value is a fraction, as before.
    parsed =
      case conn.params["percent_unit"] do
        "percent" -> Utils.parse_and_validate_percent(conn.params["percent_value"])
        _ -> Utils.parse_and_validate_float(conn.params["percent_value"])
      end

    case parsed do
      {:ok, float} ->
        FunWithFlags.enable(flag_name, [for_percentage_of: {type, float}] ++ audit_opts(conn))
        redirect_to conn, flag_location(name, "percentage_gate")
      {:fail, reason} ->
        render_flags_page(conn, 400, name, percentage_error_message: "The percentage value #{reason}.")
    end
  end


  # Audit logs page
  #
  get "/audit_logs" do
    if audit_log_viewing_available?() do
      flag_name = Map.get(conn.query_params, "flag_name")
      page = parse_page(Map.get(conn.query_params, "page"))

      opts = [page: page, per_page: 25]
      opts = if flag_name && flag_name != "", do: Keyword.put(opts, :flag_name, flag_name), else: opts

      case FunWithFlags.audit_log_entries(opts) do
        {:ok, result} ->
          assigns = %{
            conn: conn,
            audit_records: result.records,
            audit_page: result.page,
            audit_total_pages: result.total_pages,
            audit_total: result.total,
            search_flag_name: flag_name
          }
          html_resp(conn, 200, Templates.audit_logs(assigns))

        {:error, _} ->
          html_resp(conn, 200, Templates.audit_logs(%{conn: conn, audit_disabled: true}))
      end
    else
      html_resp(conn, 200, Templates.audit_logs(%{conn: conn, audit_disabled: true}))
    end
  end


  # Settings page
  #
  get "/settings" do
    success_message = Map.get(conn.query_params, "success")

    assigns = %{
      conn: conn,
      success_message: parse_success_message(success_message),
      import_disabled: import_disabled?()
    }

    html_resp(conn, 200, Templates.settings(assigns))
  end


  # Export flags
  #
  post "/settings/export" do
    case FunWithFlags.export_flags(user_id: get_audit_user_id(conn)) do
      {:ok, binary} ->
        timestamp = Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d_%H-%M-%S")
        filename = "flags_export_#{System.get_env("APP_NAME") || "unknown_app"}_#{System.get_env("APP_ENV") || "unknown_env"}_#{timestamp}.etf"

        conn
        |> put_resp_content_type("application/octet-stream")
        |> put_resp_header("content-disposition", "attachment; filename=\"#{filename}\"")
        |> send_resp(200, binary)

      {:error, reason} ->
        assigns = %{
          conn: conn,
          error_message: "Export failed: #{inspect(reason)}",
          import_disabled: import_disabled?()
        }

        html_resp(conn, 500, Templates.settings(assigns))
    end
  end


  # Import flags
  #
  post "/settings/import" do
    if import_disabled?() do
      html_resp(conn, 403, Templates.settings(%{
        conn: conn,
        import_disabled: true,
        import_error_message: "Import is only available in development."
      }))
    else
      handle_import(conn)
    end
  end


  match _ do
    send_resp(conn, 404, "")
  end


  defp toggle_actor(conn, name, actor_id) do
    enabled = Utils.parse_bool(conn.params["enabled"])
    flag_name = String.to_existing_atom(name)
    actor = %SimpleActor{id: actor_id}

    if enabled do
      FunWithFlags.enable(flag_name, [for_actor: actor] ++ audit_opts(conn))
    else
      FunWithFlags.disable(flag_name, [for_actor: actor] ++ audit_opts(conn))
    end

    redirect_to conn, flag_location(name, "actor_#{actor_id}")
  end

  defp clear_actor(conn, name, actor_id) do
    flag_name = String.to_existing_atom(name)
    actor = %SimpleActor{id: actor_id}

    FunWithFlags.clear(flag_name, [for_actor: actor] ++ audit_opts(conn))
    redirect_to conn, flag_location(name, "actor_gates")
  end

  defp toggle_group(conn, name, group_name) do
    enabled = Utils.parse_bool(conn.params["enabled"])
    flag_name = String.to_existing_atom(name)
    group_name = to_string(group_name)

    if enabled do
      FunWithFlags.enable(flag_name, [for_group: group_name] ++ audit_opts(conn))
    else
      FunWithFlags.disable(flag_name, [for_group: group_name] ++ audit_opts(conn))
    end

    redirect_to conn, flag_location(name, "group_#{group_name}")
  end

  defp clear_group(conn, name, group_name) do
    flag_name = String.to_existing_atom(name)
    group_name = to_string(group_name)

    FunWithFlags.clear(flag_name, [for_group: group_name] ++ audit_opts(conn))
    redirect_to conn, flag_location(name, "group_gates")
  end

  # Only for existing gates whose target can't be a path segment, so any
  # non-blank value is accepted (`Utils.validate/1` would reject "." and "..",
  # the very targets these routes exist for). A missing or blank one, e.g. an
  # old form whose /actors/. action was resolved to /actors, changes nothing.
  #
  defp with_body_target(conn, name, param, label, fun) do
    case conn.params[param] do
      target when is_binary(target) and target != "" ->
        fun.(conn, name, target)

      _ ->
        render_flags_page(conn, 400, name, [{error_key(param), "The #{label} can't be blank."}])
    end
  end

  defp error_key("actor_id"), do: :actor_error_message
  defp error_key("group_name"), do: :group_error_message


  # The one render path for the flags page, shared by `GET /flags`,
  # `GET /flags/:name` and the validation-error branches of the POST routes,
  # so the panel always gets its audit log assigns.
  #
  # The selected flag is picked from `all_flags` rather than looked up
  # separately: no atom is created for unknown names, and one query fewer.
  #
  defp render_flags_page(conn, status, name, extra_assigns \\ []) do
    {conn, deleted_name} = if name, do: {conn, nil}, else: take_deleted_name(conn)
    {:ok, flags} = FunWithFlags.all_flags()
    flags = Utils.sort_flags(flags)
    flag = name && Enum.find(flags, &(to_string(&1.name) == name))

    {status, panel_assigns} =
      cond do
        flag -> {status, fetch_flag_audit_logs(conn, name, conn.query_params)}
        name -> {404, []}
        true -> {status, []}
      end

    assigns =
      [
        conn: conn,
        flags: flags,
        flag: flag,
        selected_name: name,
        any_created: Templates.any_created_at?(flags),
        viewer: get_audit_user_id(conn),
        deleted_name: deleted_name
      ] ++ panel_assigns ++ extra_assigns

    html_resp(conn, status, Templates.index(assigns))
  end


  # "Deleted <name>." on the list after a delete: the name rides in the
  # session from the DELETE to the next list render, which reads and drops
  # it, so no link can show the banner. Without a session (the host has no
  # session plug) there is no banner. Capped: the page shows at most
  # @deleted_name_max characters of it.
  @deleted_session_key "fwf_deleted_flag"
  @deleted_name_max 120

  defp put_deleted_name(conn, name) do
    Plug.Conn.put_session(conn, @deleted_session_key, String.slice(name, 0, @deleted_name_max + 1))
  rescue
    ArgumentError -> conn
  end

  defp take_deleted_name(conn) do
    case Plug.Conn.get_session(conn, @deleted_session_key) do
      name when is_binary(name) and name != "" ->
        {Plug.Conn.delete_session(conn, @deleted_session_key), truncate(name, @deleted_name_max)}

      _ ->
        {conn, nil}
    end
  rescue
    ArgumentError -> {conn, nil}
  end

  defp truncate(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max) <> "…", else: text
  end


  defp flag_location(name), do: "/flags/" <> Templates.url_safe(name)
  defp flag_location(name, anchor), do: flag_location(name) <> "#" <> Templates.url_safe(anchor)


  defp html_resp(conn, status, body) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(status, body)
  end


  defp redirect_to(conn, uri) do
    path = Path.join(conn.assigns[:namespace], uri)

    conn
    |> put_resp_header("location", path)
    |> put_resp_content_type("text/html")
    |> send_resp(302, "<html><body>You are being <a href=\"#{path}\">redirected</a>.</body></html>")
  end


  defp extract_namespace(conn, opts) do
    ns = opts[:namespace] || ""
    Plug.Conn.assign(conn, :namespace, "/" <> ns)
  end


  defp assign_csrf_token(conn, _opts) do
    csrf_token = Plug.CSRFProtection.get_csrf_token()
    Plug.Conn.assign(conn, :csrf_token, csrf_token)
  end


  # Custom CSRF protection plug. It wraps the default plug provided
  # by `Plug`, it calls `Plug.Conn.fetch_session/1` (no-op if already
  # fetched), and it bails out gracefully if no session is configured.
  #
  defp protect_from_forgery(conn, opts) do
    try do
      conn
      |> fetch_session()
      |> Plug.CSRFProtection.call(opts)
    rescue
      _e in ArgumentError ->
        Logger.warning("CSRF protection won't work unless your host application uses the session plug")
        conn
    end
  end


  defp handle_import(conn) do
    case conn.params do
      %{"file" => %Plug.Upload{path: temp_path}, "mode" => mode_str} ->
        case File.read(temp_path) do
          {:ok, binary} ->
            mode = parse_import_mode(mode_str)

            case FunWithFlags.import_flags(binary, mode, user_id: get_audit_user_id(conn)) do
              {:ok, count} ->
                redirect_to conn, "/settings?success=imported_#{count}"

              {:error, reason} ->
                assigns = %{
                  conn: conn,
                  import_disabled: import_disabled?(),
                  import_error_message: to_string(reason)
                }

                html_resp(conn, 400, Templates.settings(assigns))
            end

          {:error, posix_error} ->
            assigns = %{
              conn: conn,
              import_disabled: import_disabled?(),
              import_error_message: "Failed to read uploaded file: #{posix_error}"
            }

            html_resp(conn, 400, Templates.settings(assigns))
        end

      _ ->
        assigns = %{
          conn: conn,
          import_disabled: import_disabled?(),
          import_error_message: "No file uploaded or invalid form data"
        }

        html_resp(conn, 400, Templates.settings(assigns))
    end
  end


  defp parse_import_mode("clear"), do: :clear_and_import
  defp parse_import_mode("overwrite"), do: :import_and_overwrite
  defp parse_import_mode(_), do: :import_and_overwrite


  defp parse_success_message("imported_" <> count), do: "Successfully imported #{count} flags"
  defp parse_success_message(_), do: nil


  defp audit_log_viewing_available? do
    Code.ensure_loaded?(FunWithFlags.AuditLog) and
      function_exported?(FunWithFlags.AuditLog, :list, 1)
  end


  defp parse_page(nil), do: 1
  defp parse_page(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} when n > 0 -> n
      _ -> 1
    end
  end
  defp parse_page(_), do: 1


  defp fetch_flag_audit_logs(conn, flag_name, query_params) do
    if audit_log_viewing_available?() do
      page = parse_page(Map.get(query_params, "audit_page"))

      case FunWithFlags.audit_log_entries_for_flag(flag_name, page: page, per_page: 10) do
        {:ok, result} ->
          [
            audit_records: result.records,
            audit_page: result.page,
            audit_total_pages: result.total_pages,
            audit_total: result.total,
            page_param: "audit_page",
            pagination_base_path: Templates.path(conn, "/flags/#{Templates.url_safe(flag_name)}"),
            hide_flag_column: true
          ]

        {:error, _} ->
          [audit_disabled: true]
      end
    else
      [audit_disabled: true]
    end
  end
end
