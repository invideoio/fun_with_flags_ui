defmodule FunWithFlags.UI.AuditLogFormatter do
  @moduledoc false

  import FunWithFlags.UI.HTMLEscape, only: [html_escape: 1]

  @doc """
  Returns a human-friendly HTML description of an audit log record's data map.
  Handles both atom-keyed and string-keyed maps.
  """
  def describe(%{data: data}) when is_map(data) do
    describe_data(normalize_keys(data))
  end

  def describe(_), do: "Unknown action"

  defp normalize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), normalize_keys(v)}
      {k, v} -> {k, normalize_keys(v)}
    end)
  end

  defp normalize_keys(other), do: other

  defp describe_data(%{"action" => "enable", "gate" => gate}) do
    describe_gate_action("Enabled", gate)
  end

  defp describe_data(%{"action" => "disable", "gate" => gate}) do
    describe_gate_action("Disabled", gate)
  end

  defp describe_data(%{"action" => "clear_flag"}) do
    "Cleared all gates"
  end

  defp describe_data(%{"action" => "clear_gate", "gate" => gate}) do
    describe_gate_action("Cleared", gate)
  end

  defp describe_data(%{"action" => "export"}) do
    "Exported all flags"
  end

  defp describe_data(%{"action" => "import", "operation_metadata" => meta}) do
    count = Map.get(meta, "flag_count", "?")
    mode = meta |> Map.get("mode", "") |> humanize_mode()
    "Bulk imported #{count} flags (#{mode})"
  end

  defp describe_data(%{"action" => "import"}) do
    "Bulk imported flags"
  end

  defp describe_data(%{"action" => action}) do
    "#{String.capitalize(to_string(action))}"
  end

  defp describe_data(_), do: "Unknown action"

  defp describe_gate_action(verb, %{"type" => "boolean"}) do
    "#{verb} boolean gate"
  end

  defp describe_gate_action(verb, %{"type" => "actor", "target" => target}) do
    "#{verb} actor gate for #{html_escape(target)}"
  end

  defp describe_gate_action(verb, %{"type" => "group", "target" => target}) do
    "#{verb} group gate for #{html_escape(target)}"
  end

  defp describe_gate_action(verb, %{"type" => "percentage_of_time", "target" => target}) do
    "#{verb} percentage of time gate (#{format_percentage(target)})"
  end

  defp describe_gate_action(verb, %{"type" => "percentage_of_actors", "target" => target}) do
    "#{verb} percentage of actors gate (#{format_percentage(target)})"
  end

  defp describe_gate_action(verb, %{"type" => type}) do
    "#{verb} #{humanize_gate_type(type)} gate"
  end

  defp describe_gate_action(verb, _) do
    "#{verb} gate"
  end

  defp format_percentage(val) when is_binary(val) do
    case Float.parse(val) do
      {f, _} -> "#{round(f * 100)}%"
      :error -> val
    end
  end

  defp format_percentage(val) when is_float(val), do: "#{round(val * 100)}%"
  defp format_percentage(val) when is_integer(val), do: "#{val}%"
  defp format_percentage(val), do: to_string(val)

  defp humanize_gate_type(type) do
    type
    |> to_string()
    |> String.replace("_", " ")
  end

  defp humanize_mode("clear_and_import"), do: "clear and import"
  defp humanize_mode("import_and_overwrite"), do: "import and overwrite"
  defp humanize_mode(mode), do: to_string(mode)
end
