defmodule FunWithFlags.UI.GroupCatalog do
  @moduledoc """
  Lists the group names a `FunWithFlags.Group` implementation matches, so the
  dashboard's add-group picker offers them without anyone keeping a list.

      defimpl FunWithFlags.Group, for: MyApp.Workspace do
        use FunWithFlags.UI.GroupCatalog,
          hints: %{
            "country_group:" => {MyApp.CountryGroups, :names, []},
            "created_at:gt:" => "unix timestamp"
          }

        def in?(%{bucket: b}, "a0"), do: b == :a0
        def in?(ws, "country_group:" <> group), do: ...
        def in?(_, _), do: false
      end

  At compile time it reads the second argument of every 2-arity function in
  the module (so `in?/2` and any private helper it delegates to, like
  `matches?(bucket, "signup_a0")`):

    * a string literal, or literals joined with `<>` (`"email" <> ":eq:" <> "x"`),
      is an exact group name;
    * literals followed by a variable (`"country_group:" <> group`) is a
      pattern: the prefix, then a value;
    * a variable compared to literals in the guard (`when group in ~w(a b)`)
      gives those literals as exact names.

  Anything else (`_`, a bare variable) adds nothing. A new clause shows up in
  the picker on the next compile.

  `hints` describe a pattern's value: a string is the value box's placeholder,
  a list (or an `{m, f, a}` returning one, called when the page renders) is
  the values to suggest.
  """

  defmacro __using__(opts) do
    hints = Keyword.get(opts, :hints, quote(do: %{}))

    quote do
      @fwf_group_hints unquote(hints)
      @before_compile FunWithFlags.UI.GroupCatalog
    end
  end

  defmacro __before_compile__(env) do
    groups = extract(env.module)

    quote do
      @doc false
      def __fwf_groups__, do: %{groups: unquote(Macro.escape(groups)), hints: @fwf_group_hints}
    end
  end

  @doc false
  # [{:exact, "a0"} | {:prefix, "country_group:"}], in source order.
  def extract(module) do
    module
    |> Module.definitions_in()
    |> Enum.filter(fn {_name, arity} -> arity == 2 end)
    |> Enum.flat_map(fn def_id ->
      {:v1, _kind, _meta, clauses} = Module.get_definition(module, def_id)
      Enum.map(clauses, fn {meta, [_, arg], guards, _body} -> {meta[:line] || 0, arg, guards} end)
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {_line, arg, guards} -> from_arg(arg, guards) end)
    |> Enum.uniq()
  end

  defp from_arg(arg, _guards) when is_binary(arg), do: [{:exact, arg}]

  defp from_arg({:<<>>, _, segments}, _guards), do: from_segments(segments, "")

  defp from_arg({name, _, ctx}, guards) when is_atom(name) and is_atom(ctx) do
    guards
    |> Enum.flat_map(&compared_literals(&1, name))
    |> Enum.map(&{:exact, &1})
  end

  defp from_arg(_arg, _guards), do: []

  defp from_segments([], acc), do: [{:exact, acc}]

  defp from_segments([{:"::", _, [lit, {:binary, _, _}]} | rest], acc) when is_binary(lit),
    do: from_segments(rest, acc <> lit)

  defp from_segments([{:"::", _, [{name, _, ctx}, _type]}], acc)
       when is_atom(name) and is_atom(ctx) and acc != "",
       do: [{:prefix, acc}]

  defp from_segments(_segments, _acc), do: []

  # `group in ~w(a b)` in a guard expands to `:erlang.orelse(:erlang."=:="(group, "a"), ...)`.
  defp compared_literals(guard, var) do
    {_, found} =
      Macro.prewalk(guard, [], fn
        {{:., _, [:erlang, op]}, _, [{^var, _, ctx}, lit]} = node, acc
        when op in [:"=:=", :==] and is_atom(ctx) and is_binary(lit) ->
          {node, [lit | acc]}

        {{:., _, [:erlang, op]}, _, [lit, {^var, _, ctx}]} = node, acc
        when op in [:"=:=", :==] and is_atom(ctx) and is_binary(lit) ->
          {node, [lit | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(found)
  end
end
