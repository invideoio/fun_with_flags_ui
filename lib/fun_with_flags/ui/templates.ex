defmodule FunWithFlags.UI.Templates do
  @moduledoc false

  require EEx
  alias FunWithFlags.{Flag, Gate}
  alias FunWithFlags.UI.{AuditLogFormatter, Utils}
  import FunWithFlags.UI.HTMLEscape, only: [html_escape: 1]

  @templates [
    _head: "_head",
    _header: "_header",
    index: "index",
    _flag_list_item: "_flag_list_item",
    _flag_panel: "_flag_panel",
    _flag_panel_not_found: "_flag_panel_not_found",
    new: "new",
    settings: "settings",
    _boolean_row: "rows/_boolean",
    _gate_section: "rows/_gate_section",
    _gate_row: "rows/_gate_row",
    _percentage_section: "rows/_percentage_section",
    audit_logs: "audit_logs",
    _audit_log_table: "rows/_audit_log_table",
    _audit_log_pagination: "rows/_audit_log_pagination",
    _audit_log_section: "rows/_audit_log_section",
  ]

  for {fn_name, file_name} <- @templates do
    EEx.function_from_file :def, fn_name, Path.expand("./templates/#{file_name}.html.eex", __DIR__), [:assigns]
  end


  # The three states of a flag, labelled the same way everywhere on the
  # flags page. `half_open` used to read "Enabled", which made it
  # indistinguishable from a fully enabled flag except by colour.
  #
  @status_labels %{fully_open: {"on", "On"}, half_open: {"partial", "Partial"}, closed: {"off", "Off"}}

  def status_key(flag) do
    {key, _label} = Map.fetch!(@status_labels, Utils.get_flag_status(flag))
    key
  end

  def html_status_pill(flag) do
    {key, label} = Map.fetch!(@status_labels, Utils.get_flag_status(flag))
    ~s(<span class="fwf-pill fwf-pill-#{key}">#{label}</span>)
  end

  def html_status_for({:ok, bool}) do
    html_status_for(bool)
  end

  def html_status_for(:missing) do
    ~s{<span class="badge badge-default">Disabled (missing)</span>}
  end

  def html_status_for(bool) when is_boolean(bool) do
    if bool do
      ~s(<span class="badge badge-success">Enabled</span>)
    else
      ~s(<span class="badge badge-danger">Disabled</span>)
    end
  end

  @gate_type_order [
    :boolean,
    :actor,
    :group,
    :percentage_of_actors,
    :percentage_of_time,
  ]
  |> Enum.with_index()
  |> Map.new()

  # The gate types used by the list filter: both percentage gates
  # are reported as "percentage".
  #
  def gate_type_keys(%Flag{gates: gates}) do
    gates
    |> Enum.map(fn
      %Gate{type: type} when type in [:percentage_of_time, :percentage_of_actors] -> :percentage
      %Gate{type: type} -> type
    end)
    |> Enum.uniq()
    |> Enum.sort_by(&Map.get(@gate_type_order, &1, 99))
    |> Enum.join(" ")
  end


  # e.g. "3 actors · 1 group · 25% of actors"
  #
  def gate_summary(%Flag{} = flag) do
    actors = length(Utils.actor_gates(flag))
    groups = length(Utils.group_gates(flag))

    parts =
      [
        actors > 0 && pluralize(actors, "actor", "actors"),
        groups > 0 && pluralize(groups, "group", "groups"),
        percentage_summary(Utils.percentage_gate(flag))
      ]
      |> Enum.filter(& &1)

    cond do
      parts != [] -> Enum.join(parts, " · ")
      Utils.boolean_gate(flag) -> "boolean only"
      true -> "no gates"
    end
  end

  defp percentage_summary(nil), do: false
  defp percentage_summary(%Gate{type: :percentage_of_time, for: ratio}), do: "#{format_percentage(ratio)}% of time"
  defp percentage_summary(%Gate{type: :percentage_of_actors, for: ratio}), do: "#{format_percentage(ratio)}% of actors"

  defp format_percentage(ratio) do
    percentage = Utils.as_percentage(ratio)
    if round(percentage) == percentage, do: Integer.to_string(round(percentage)), else: to_string(percentage)
  end

  defp pluralize(1, singular, _plural), do: "1 #{singular}"
  defp pluralize(n, _singular, plural), do: "#{n} #{plural}"


  # Gate targets embedded once in each list row, for the client-side
  # search. Newline separated, HTML-escaped by the caller.
  #
  def actor_targets(%Flag{} = flag) do
    flag |> Utils.actor_gates() |> Enum.map_join("\n", &to_string(&1.for))
  end

  def group_targets(%Flag{} = flag) do
    flag |> Utils.group_gates() |> Enum.map_join("\n", &to_string(&1.for))
  end


  # `created_at` is nil on Redis, and it can be a NaiveDateTime (in UTC)
  # when it comes from a raw SQL query on Postgres.
  #
  def iso_timestamp(nil), do: ""
  def iso_timestamp(%DateTime{} = dt), do: dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  def iso_timestamp(%NaiveDateTime{} = ndt), do: ndt |> DateTime.from_naive!("Etc/UTC") |> iso_timestamp()

  def format_date(nil), do: ""
  def format_date(dt), do: Calendar.strftime(dt, "%Y-%m-%d")


  def _flag_panel_empty(assigns) do
    flag_icon = icon(assigns[:conn], "flag", "fwf-icon fwf-icon--lg")

    """
    <div class="fwf-panel fwf-panel-empty">#{flag_icon}<p>Select a flag to see who it is on for.</p>\
    <div class="fwf-panel-keys">\
    <span><kbd>/</kbd></span><span>search flags, actors, groups</span>\
    <span><kbd>j</kbd><kbd>k</kbd></span><span>move through the list</span>\
    <span><kbd>Enter</kbd></span><span>open the flag</span>\
    <span><kbd>?</kbd></span><span>all shortcuts</span></div></div>
    """
  end


  # --- shared header ---------------------------------------------------

  # "copilot · production" from APP_NAME / APP_ENV, so the dashboards of
  # different services can be told apart. {nil, nil} when neither is set.
  #
  def app_label do
    app = blank_to_nil(System.get_env("APP_NAME"))
    env = blank_to_nil(System.get_env("APP_ENV"))

    case Enum.reject([app, env], &is_nil/1) do
      [] -> {nil, nil}
      parts -> {Enum.join(parts, " · "), env_key(env)}
    end
  end

  defp env_key(nil), do: "none"

  defp env_key(env) do
    case String.downcase(env) do
      e when e in ["prod", "production"] -> "prod"
      e when e in ["staging", "stage", "preprod"] -> "staging"
      _ -> "other"
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(str), do: if(String.trim(str) == "", do: nil, else: str)

  # The signed-in user, from the header the audit log reads its user ID
  # from (a display value only).
  #
  def viewer(conn) do
    header = FunWithFlags.Config.audit_log_user_id_header()

    case Plug.Conn.get_req_header(conn, header) do
      [value | _] when value != "" -> value
      _ -> nil
    end
  end

  def nav_current(active, key) when active == key, do: ~s( aria-current="page")
  def nav_current(_active, _key), do: ""


  # Icons: Hugeicons (stroke-rounded, MIT), vendored as one SVG sprite in
  # priv/static/icons/hugeicons.svg (see dev/icons/build_sprite.js). A
  # same-origin <use href> is allowed by `default-src 'self'` CSPs.
  # Decorative next to text: aria-hidden; icon-only buttons carry an
  # aria-label themselves.
  #
  def icon_sprite(conn), do: path(conn, "/assets/icons/hugeicons.svg")

  def icon(conn, name, class \\ "fwf-icon") do
    ~s(<svg class="#{class}" aria-hidden="true" focusable="false"><use href="#{icon_sprite(conn)}#hi-#{name}"></use></svg>)
  end

  # For icons repeated on every row (a 252-actor panel): the symbol is
  # inlined once (`icon_symbols/1`) and each row points at it by fragment,
  # instead of repeating the sprite URL.
  @external_resource Path.expand("../../../priv/static/icons/hugeicons.svg", __DIR__)
  @sprite_symbols Path.expand("../../../priv/static/icons/hugeicons.svg", __DIR__)
                  |> File.read!()
                  |> then(&Regex.scan(~r{<symbol id="hi-([\w-]+)".*?</symbol>}s, &1))
                  |> Map.new(fn [symbol, name] -> {name, symbol} end)

  def icon_symbols(names) do
    symbols = Enum.map_join(names, &Map.fetch!(@sprite_symbols, &1))
    ~s(<svg class="fwf-sprite" aria-hidden="true" focusable="false">#{symbols}</svg>)
  end

  def icon_ref(name), do: ~s(<svg class="fwf-icon" aria-hidden="true" focusable="false"><use href="#hi-#{name}"></use></svg>)


  # --- panel --------------------------------------------------------------

  # Gate rows shown before "Show all N"; the rest render inside a <details>.
  @gate_rows_visible 10
  def gate_rows_visible, do: @gate_rows_visible

  # "On for 3 actors and 1 group; off for everyone else." — see Summary.
  def flag_summary(flag), do: FunWithFlags.UI.Summary.sentence(flag)

  # "Your actor gate email:ana@example.com is on." under the summary, only
  # when an actor gate names the signed-in viewer exactly (see
  # Summary.for_viewer/2). A description of the gate, never a verdict.
  def html_for_viewer(conn, flag) do
    case FunWithFlags.UI.Summary.for_viewer(flag, viewer(conn)) do
      nil -> ""
      # (a plain string, not ~s(): credo 1.7.12 crashes on that sigil here)
      text -> "<p class=\"fwf-for-you\">#{html_escape(text)}</p>"
    end
  end

  # Percentage gate as display text: "25%" (no float noise).
  def percent_text(ratio) do
    percentage = Utils.as_percentage(ratio)
    if round(percentage) == percentage, do: "#{round(percentage)}%", else: "#{percentage}%"
  end

  # Toggle/remove buttons of a gate row post through two shared forms per
  # section (see _gate_section), via the button's `form`/`formaction`, so a
  # row is two buttons instead of two full forms. The request is the same as
  # before: PATCH .../actors/:id with enabled=..., DELETE .../actors/:id.
  def section_form_id(kind, :toggle), do: "fwf-#{singular(kind)}-toggle-form"
  def section_form_id(kind, :clear), do: "fwf-#{singular(kind)}-clear-form"

  def singular("actors"), do: "actor"
  def singular("groups"), do: "group"

  def gate_param("actors"), do: "actor_id"
  def gate_param("groups"), do: "group_name"


  def page_title(assigns) do
    cond do
      assigns[:flag] -> html_escape(assigns[:flag].name)
      assigns[:selected_name] -> "Not Found"
      true -> "List"
    end
  end


  def any_created_at?(flags) do
    Enum.any?(flags, &(not is_nil(&1.created_at)))
  end


  # A flag name for display, HTML-escaped, with a line-break opportunity
  # (<wbr>) after every run of underscores: a long snake_case name is a single word to
  # the browser, so it would otherwise wrap mid-word. Escaping comes first, so
  # only our <wbr> tags are markup; the text content is the name, unchanged.
  #
  def html_breakable_name(name) do
    name
    |> html_escape()
    |> IO.iodata_to_binary()
    |> String.replace(~r/_+/, "\\0<wbr>")
  end


  # The flag name with the most characters. The list is set in a monospace
  # font, so that is also the widest name: the list's column sizer row
  # (see index.html.eex) uses it.
  #
  def longest_flag_name([]), do: nil

  def longest_flag_name(flags) do
    flags
    |> Enum.map(&to_string(&1.name))
    |> Enum.max_by(&String.length/1)
  end


  # The action of an actor/group gate's toggle and Clear forms. A target of
  # "." or ".." can't be a path segment: browsers resolve it as a
  # dot-segment (percent-encoding doesn't help, %2e%2e is one too), so
  # /flags/foo/actors/.. would post to /flags/foo and Clear would delete the
  # whole flag. Those post to the collection URL with the target in the body
  # instead (see `gate_target_input/2` and the router's body-target routes).
  # New targets like that are rejected by `Utils.validate/1`; this covers
  # gates that already exist.
  #
  def gate_form_action(conn, flag, kind, target) when kind in ["actors", "groups"] do
    base = "/flags/#{url_safe(flag.name)}/#{kind}"
    if dot_segment?(target), do: path(conn, base), else: path(conn, "#{base}/#{url_safe(target)}")
  end

  def gate_target_input(kind, target) when kind in ["actors", "groups"] do
    if dot_segment?(target) do
      param = if kind == "actors", do: "actor_id", else: "group_name"
      ~s(<input type="hidden" name="#{param}" value="#{html_escape(target)}">)
    else
      ""
    end
  end

  def dot_segment?(target), do: to_string(target) in [".", ".."]


  def flag_path(conn, name) do
    path(conn, "/flags/#{url_safe(name)}")
  end


  def path(conn, path) do
    Path.join(conn.assigns[:namespace], path)
  end


  # Percent-encodes a value for use as a single path segment. Flag names
  # created in code can be any atom (e.g. `:"Ook? Ook!"`), and actor IDs can
  # contain "/", so "?", "#" and "/" must be encoded too, which `URI.encode/1`
  # alone doesn't do.
  #
  def url_safe(val) do
    val
    |> to_string()
    |> URI.encode(&path_segment_char?/1)
  end

  defp path_segment_char?(char) do
    URI.char_unreserved?(char) or char in ~c":@!$&'()*+,;="
  end


  def describe_audit_record(record) do
    AuditLogFormatter.describe(record)
  end

  def format_utc_timestamp(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  end

  def format_utc_timestamp(%NaiveDateTime{} = ndt) do
    Calendar.strftime(ndt, "%Y-%m-%d %H:%M:%S")
  end

  def format_utc_timestamp(nil), do: ""

  def audit_log_page_path(conn, page, assigns) do
    page_param = assigns[:page_param] || "page"
    base_path = assigns[:pagination_base_path] || path(conn, "/audit_logs")

    params = %{page_param => page}

    # Preserve search flag_name for the dedicated audit logs page
    params =
      case assigns[:search_flag_name] do
        nil -> params
        "" -> params
        name -> Map.put(params, "flag_name", name)
      end

    query = URI.encode_query(params)
    "#{base_path}?#{query}"
  end

  def pagination_range(_current, total) when total <= 7 do
    Enum.to_list(1..total)
  end

  def pagination_range(current, total) do
    cond do
      current <= 4 ->
        Enum.to_list(1..5) ++ [:ellipsis, total]
      current >= total - 3 ->
        [1, :ellipsis] ++ Enum.to_list((total - 4)..total)
      true ->
        [1, :ellipsis] ++ Enum.to_list((current - 1)..(current + 1)) ++ [:ellipsis, total]
    end
  end
end
