defmodule FunWithFlags.UI.Templates do
  @moduledoc false

  require EEx
  alias FunWithFlags.Flag
  alias FunWithFlags.UI.{AuditLogFormatter, Utils}
  import FunWithFlags.UI.HTMLEscape, only: [html_escape: 1]

  @templates [
    _head: "_head",
    index: "index",
    details: "details",
    new: "new",
    settings: "settings",
    not_found: "not_found",
    _boolean_row: "rows/_boolean",
    _actor_row: "rows/_actor",
    _group_row: "rows/_group",
    _percentage_row: "rows/_percentage",
    _new_actor_row: "rows/_new_actor",
    _new_group_row: "rows/_new_group",
    _percentage_form_row: "rows/_percentage_form",
    audit_logs: "audit_logs",
    _audit_log_table: "rows/_audit_log_table",
    _audit_log_pagination: "rows/_audit_log_pagination",
    _audit_log_section: "rows/_audit_log_section",
  ]

  for {fn_name, file_name} <- @templates do
    EEx.function_from_file :def, fn_name, Path.expand("./templates/#{file_name}.html.eex", __DIR__), [:assigns]
  end


  def html_smart_status_for(flag) do
    case Utils.get_flag_status(flag) do
      :fully_open ->
        ~s(<span class="text-success">Enabled</span>)
      :half_open ->
        ~s(<span class="text-warning">Enabled</span>)
      :closed ->
        ~s(<span class="text-danger">Disabled</span>)
    end
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

  def html_gate_list(%Flag{gates: gates}) do
    gates
    |> Enum.map(&(&1.type))
    |> Enum.uniq()
    |> Enum.sort_by(&Map.get(@gate_type_order, &1, 99))
    |> Enum.join(", ")
  end


  def path(conn, path) do
    Path.join(conn.assigns[:namespace], path)
  end


  def url_safe(val) do
    val
    |> to_string()
    |> URI.encode()
  end


  def describe_audit_record(record) do
    AuditLogFormatter.describe(record)
  end

  def format_utc_timestamp(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
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
