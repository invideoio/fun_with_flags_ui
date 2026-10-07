defmodule FunWithFlags.UI.FormRequests do
  @moduledoc false
  # What each submit button on a rendered page would send without JS:
  # method (after the `_method` override), path (the button's formaction or
  # its form's action) and params (the form's hidden and named fields, plus
  # the button's own name/value). Buttons are associated with a form either
  # by being inside it or through a `form="id"` attribute.
  #
  # A regex reading of our own templates, not a general HTML parser: forms
  # are never nested, and attributes are always double-quoted.

  @typed "TYPED"

  def requests(html) do
    forms = forms(html)
    by_id = Map.new(Enum.filter(forms, & &1.attrs["id"]), &{&1.attrs["id"], &1})

    Enum.flat_map(forms, fn form ->
      form.inner
      |> buttons()
      |> Enum.reject(&Map.has_key?(&1.attrs, "form"))
      |> Enum.map(&request(&1, form))
    end) ++
      (html
       |> buttons()
       |> Enum.filter(&Map.has_key?(&1.attrs, "form"))
       |> Enum.map(fn button -> request(button, Map.fetch!(by_id, button.attrs["form"])) end))
  end

  defp request(button, form) do
    params =
      form.fields
      |> Map.merge(button_param(button))

    {method_override, params} = Map.pop(params, "_method")
    {_csrf, params} = Map.pop(params, "_csrf_token")
    method = String.upcase(method_override || form.attrs["method"] || "get")

    %{
      label: button.label,
      method: method,
      path: button.attrs["formaction"] || form.attrs["action"],
      params: params,
      confirm: button.attrs["data-confirm"]
    }
  end

  defp button_param(%{attrs: %{"name" => name} = attrs}), do: %{name => Map.get(attrs, "value", "")}
  defp button_param(_), do: %{}

  defp forms(html) do
    ~r{<form\b([^>]*)>(.*?)</form>}s
    |> Regex.scan(html, capture: :all_but_first)
    |> Enum.map(fn [attrs, inner] ->
      %{attrs: attrs(attrs), inner: inner, fields: fields(inner)}
    end)
  end

  # Hidden inputs keep their value; text/number inputs get a typed value;
  # radios contribute the checked one.
  defp fields(inner) do
    ~r{<input\b([^>]*)>}s
    |> Regex.scan(inner, capture: :all_but_first)
    |> Enum.map(fn [a] -> attrs(a) end)
    |> Enum.reduce(%{}, fn input, acc ->
      case {input["type"], input["name"]} do
        {_, nil} -> acc
        {"hidden", name} -> Map.put(acc, name, input["value"] || "")
        {"radio", name} -> if Map.has_key?(input, "checked"), do: Map.put(acc, name, input["value"]), else: acc
        {"file", name} -> Map.put(acc, name, :file)
        {_, name} -> Map.put(acc, name, @typed)
      end
    end)
  end

  defp buttons(html) do
    ~r{<button\b([^>]*)>(.*?)</button>}s
    |> Regex.scan(html, capture: :all_but_first)
    |> Enum.map(fn [a, label] -> %{attrs: attrs(a), label: label |> strip_tags() |> String.trim()} end)
    |> Enum.filter(&(&1.attrs["type"] == "submit"))
  end

  defp attrs(str) do
    ~r{([\w:-]+)(?:="([^"]*)")?}
    |> Regex.scan(str, capture: :all_but_first)
    |> Map.new(fn
      [name] -> {name, true}
      [name, value] -> {name, unescape(value)}
    end)
  end

  defp strip_tags(s), do: s |> String.replace(~r{<[^>]*>}, "") |> unescape()

  defp unescape(s) do
    s
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&times;", "×")
    |> String.replace("&amp;", "&")
  end

  def typed, do: @typed
end
