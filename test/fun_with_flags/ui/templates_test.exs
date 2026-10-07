defmodule FunWithFlags.UI.TemplatesTest do
  use ExUnit.Case, async: true

  alias FunWithFlags.UI.Templates
  alias FunWithFlags.{Flag, Gate}

  # These tests only render templates and never touch Redis, so they must
  # not clear it either: they run concurrently with UtilsTest, which does.

  setup do
    conn = Plug.Conn.assign(%Plug.Conn{}, :namespace, "/pear")
    conn = Plug.Conn.assign(conn, :csrf_token, Plug.CSRFProtection.get_csrf_token())
    {:ok, conn: conn}
  end


  describe "_head()" do
    test "it renders", %{conn: conn} do
      out = Templates._head(conn: conn, title: "Coconut")
      assert is_binary(out)
    end

    test "it includes the right content", %{conn: conn} do
      out = Templates._head(conn: conn, title: "Coconut")
      assert String.contains?(out, "<title>FunWithFlags - Coconut</title>")
      assert String.contains?(out, ~s{href="/pear/assets/style.css"})
    end

    test "it sets the viewport, so phones lay the page out at device width", %{conn: conn} do
      out = Templates._head(conn: conn, title: "Coconut")
      assert String.contains?(out, ~s{<meta name="viewport" content="width=device-width, initial-scale=1">})
    end
  end


  describe "index()" do
    setup do
      flags = [
        %Flag{name: :pineapple, gates: [Gate.new(:boolean, true)]},
        %Flag{name: :papaya, gates: [Gate.new(:boolean, false)]},
      ]
      {:ok, flags: flags}
    end

    defp index_assigns(conn, flags, extra \\ []) do
      [
        conn: conn,
        flags: flags,
        flag: nil,
        selected_name: nil,
        any_created: false,
        viewer: nil,
        app_label: nil,
        app_env_key: nil
      ]
      |> Keyword.merge(extra)
    end

    test "it renders", %{conn: conn, flags: flags} do
      out = Templates.index(index_assigns(conn, flags))
      assert is_binary(out)
    end

    test "it includes the right content", %{conn: conn, flags: flags} do
      out = Templates.index(index_assigns(conn, flags))
      assert String.contains?(out, "<title>FunWithFlags - List</title>")
      assert String.contains?(out, ~s{<a href="/pear/new" class="fwf-btn fwf-btn--primary fwf-new-flag"})
      assert String.contains?(out, ~s{<a class="fwf-row-link" href="/pear/flags/pineapple">})
      assert String.contains?(out, ~s{<a class="fwf-row-link" href="/pear/flags/papaya">})
      assert String.contains?(out, ~s{data-base="/pear/flags"})
      assert String.contains?(out, ~s{src="/pear/assets/flags.js"})
      assert String.contains?(out, "Select a flag to see who it is on for.")
    end

    test "each flag is rendered once, as a list row", %{conn: conn, flags: flags} do
      out = Templates.index(index_assigns(conn, flags))
      assert length(String.split(out, ~s{data-name="pineapple"})) == 2
      refute String.contains?(out, "<table")
      refute String.contains?(out, "🦖")
    end

    test "it ends the list with an invisible sizer row holding the longest name", %{conn: conn} do
      flags = [
        %Flag{name: :kiwi, gates: []},
        %Flag{name: :"a_<b>_much_longer_name", gates: []},
        %Flag{name: :fig, gates: []},
      ]
      out = Templates.index(index_assigns(conn, flags))
      sizer = ~s{<li class="fwf-row-sizer" aria-hidden="true"><span class="fwf-row-name">a_&lt;b&gt;_much_longer_name</span><span class="fwf-pill fwf-pill-partial">Partial</span></li>}
      assert String.contains?(out, sizer)
      [_, after_list_start] = String.split(out, ~s{<ul class="fwf-list" id="fwf-list">}, parts: 2)
      [list | _] = String.split(after_list_start, "</ul>", parts: 2)
      assert String.ends_with?(String.trim_trailing(list), sizer)
      refute out =~ ~r/fwf-row-sizer"[^>]*data-name/
      assert length(String.split(out, ~s{<li class="fwf-row"})) == 4
    end

    test "with no flags there is no sizer row", %{conn: conn} do
      refute String.contains?(Templates.index(index_assigns(conn, [])), "fwf-row-sizer")
    end

    test "with a selected flag it renders its panel and marks its row", %{conn: conn, flags: flags} do
      [pineapple | _] = flags
      out = Templates.index(index_assigns(conn, flags, flag: pineapple, selected_name: "pineapple"))
      assert String.contains?(out, "<title>FunWithFlags - pineapple</title>")
      assert String.contains?(out, ~s{<body class="fwf-flags-page fwf-has-selection"})
      assert String.contains?(out, ~s{<a class="fwf-row-link" href="/pear/flags/pineapple" aria-current="page">})
      assert String.contains?(out, ~s{<div class="fwf-panel fwf-fade-in" data-name="pineapple"})
    end
  end


  describe "_flag_list_item()" do
    test "it labels the three states On, Partial and Off", %{conn: conn} do
      on = %Flag{name: :on_flag, gates: [Gate.new(:boolean, true)]}
      partial = %Flag{name: :partial_flag, gates: [Gate.new(:boolean, false), %Gate{type: :actor, for: "user:1", enabled: true}]}
      off = %Flag{name: :off_flag, gates: [Gate.new(:boolean, false)]}

      assert String.contains?(item(conn, on), ~s{<span class="fwf-pill fwf-pill-on">On</span>})
      assert String.contains?(item(conn, partial), ~s{<span class="fwf-pill fwf-pill-partial">Partial</span>})
      assert String.contains?(item(conn, off), ~s{<span class="fwf-pill fwf-pill-off">Off</span>})

      assert String.contains?(item(conn, on), ~s{data-status="on"})
      assert String.contains?(item(conn, partial), ~s{data-status="partial"})
      assert String.contains?(item(conn, off), ~s{data-status="off"})
    end

    test "it embeds the gate targets and summarises the gates", %{conn: conn} do
      flag = %Flag{name: :kiwi, gates: [
        %Gate{type: :actor, for: "workspace:123", enabled: true},
        %Gate{type: :actor, for: "email:ana@example.com", enabled: false},
        %Gate{type: :group, for: "beta", enabled: true},
        %Gate{type: :percentage_of_actors, for: 0.25, enabled: true},
      ]}
      out = item(conn, flag)
      assert String.contains?(out, ~s{data-actors="email:ana@example.com\nworkspace:123"})
      assert String.contains?(out, ~s{data-groups="beta"})
      assert String.contains?(out, ~s{data-types="actor group percentage"})
      assert String.contains?(out, "2 actors · 1 group · 25% of actors")
    end

    test "it shows the created date, or nothing when there is none", %{conn: conn} do
      with_date = %Flag{name: :fig, gates: [], created_at: ~U[2025-03-04 05:06:07Z]}
      out = item(conn, with_date)
      assert String.contains?(out, ~s{data-created="2025-03-04T05:06:07Z"})
      assert String.contains?(out, ~s{<time class="fwf-row-created" title="2025-03-04 05:06:07 UTC">2025-03-04</time>})

      naive = %Flag{name: :fig, gates: [], created_at: ~N[2025-03-04 05:06:07]}
      assert String.contains?(item(conn, naive), ~s{data-created="2025-03-04T05:06:07Z"})

      without = %Flag{name: :fig, gates: []}
      out = item(conn, without)
      assert String.contains?(out, ~s{data-created=""})
      refute String.contains?(out, "<time")
      assert String.contains?(out, "no gates")
    end

    test "it escapes names and targets, and encodes the URL", %{conn: conn} do
      flag = %Flag{name: :"Ook? <b>Ook!</b>", gates: [%Gate{type: :actor, for: "x\"><script>", enabled: true}]}
      out = item(conn, flag)
      assert String.contains?(out, ~s{data-name="Ook? &lt;b&gt;Ook!&lt;/b&gt;"})
      assert String.contains?(out, ~s{href="/pear/flags/Ook%3F%20%3Cb%3EOok!%3C%2Fb%3E"})
      assert String.contains?(out, ~s{data-actors="x&quot;&gt;&lt;script&gt;"})
      refute String.contains?(out, "<b>")
      refute String.contains?(out, "<script>")
    end

    test "long snake_case names can break after underscores, and nowhere else is changed", %{conn: conn} do
      flag = %Flag{name: :analytics_trial_extension_rollout, gates: [Gate.new(:boolean, true)]}
      out = item(conn, flag)
      assert String.contains?(out, ~s{<span class="fwf-row-name">analytics_<wbr>trial_<wbr>extension_<wbr>rollout</span>})
      assert String.contains?(out, ~s{data-name="analytics_trial_extension_rollout"})
      assert String.contains?(out, ~s{href="/pear/flags/analytics_trial_extension_rollout"})
      assert length(String.split(out, "<wbr>")) == 4
    end

    test "the <wbr> breaks go in after escaping, so an escaped name stays escaped", %{conn: conn} do
      flag = %Flag{name: :"a_<b>_c", gates: []}
      out = item(conn, flag)
      assert String.contains?(out, ~s{<span class="fwf-row-name">a_<wbr>&lt;b&gt;_<wbr>c</span>})
      assert String.contains?(out, ~s{data-name="a_&lt;b&gt;_c"})
      assert String.contains?(out, ~s{href="/pear/flags/a_%3Cb%3E_c"})
      refute String.contains?(out, "<b>")
    end

    test "the gate summary carries its full text as a title, for when it is truncated", %{conn: conn} do
      flag = %Flag{name: :kiwi, gates: [%Gate{type: :group, for: "beta", enabled: true}, %Gate{type: :percentage_of_time, for: 0.25, enabled: true}]}
      assert String.contains?(item(conn, flag), ~s{<span class="fwf-row-gates" title="1 group · 25% of time">1 group · 25% of time</span>})
    end

    defp item(conn, flag) do
      Templates._flag_list_item(conn: conn, flag: flag, selected: false)
    end
  end


  describe "_flag_panel()" do
    setup do
      flag = %Flag{name: :avocado, gates: []}
      {:ok, flag: flag}
    end

    test "it renders", %{conn: conn, flag: flag} do
      out = Templates._flag_panel(conn: conn, flag: flag)
      assert is_binary(out)
    end

    test "it includes the right content", %{conn: conn, flag: flag} do
      out = Templates._flag_panel(conn: conn, flag: flag)
      assert String.contains?(out, ~s{<h1 class="fwf-panel-title">avocado</h1>})
      assert String.contains?(out, ~s{data-copy="avocado"})
      assert String.contains?(out, ~s{<a class="fwf-back" href="/pear/flags">})
      refute String.contains?(out, "<html")
    end

    test "the title breaks after underscores; copy-name and data-name keep the exact name", %{conn: conn} do
      out = Templates._flag_panel(conn: conn, flag: %Flag{name: :new_checkout, gates: []})
      assert String.contains?(out, ~s{<h1 class="fwf-panel-title">new_<wbr>checkout</h1>})
      assert String.contains?(out, ~s{data-copy="new_checkout"})
      assert String.contains?(out, ~s{<div class="fwf-panel fwf-fade-in" data-name="new_checkout"})
    end

    test "it includes the CSRF token", %{conn: conn, flag: flag} do
      csrf_token = Plug.CSRFProtection.get_csrf_token()
      out = Templates._flag_panel(conn: conn, flag: flag)
      assert String.contains?(out, ~s{<input type="hidden" name="_csrf_token" value="#{csrf_token}">})
    end

    test "it includes the global toggle, the new actor, new group and percentage forms, and the global delete form", %{conn: conn, flag: flag} do
      out = Templates._flag_panel(conn: conn, flag: flag)
      assert String.contains?(out, ~s{<form id="fwf-global-disable-form" action="/pear/flags/avocado/boolean" method="post"})
      assert String.contains?(out, ~s{<form id="fwf-global-enable-form" action="/pear/flags/avocado/boolean" method="post"})
      assert out =~ ~r{<form id="fwf-new-actor-form" class="fwf-add" action="/pear/flags/avocado/actors" method="post">}
      assert out =~ ~r{<form id="fwf-new-group-form" class="fwf-add" action="/pear/flags/avocado/groups" method="post">}
      assert out =~ ~r{<form id="fwf-percentage-form" class="fwf-pct-form" action="/pear/flags/avocado/percentage" method="post"}
      assert String.contains?(out, ~s{<form id="fwf-delete-flag-form" action="/pear/flags/avocado" method="post">})
    end

    test "it has no duplicate element ids", %{conn: conn, flag: flag} do
      f = %Flag{flag | gates: [
        %Gate{type: :actor, for: "moss:123", enabled: true},
        %Gate{type: :group, for: :rocks, enabled: true},
        %Gate{type: :percentage_of_time, for: 0.1, enabled: true},
      ]}
      out = Templates._flag_panel(conn: conn, flag: f)
      ids = Regex.scan(~r/\sid="([^"]+)"/, out, capture: :all_but_first) |> List.flatten()
      assert ids == Enum.uniq(ids)
    end

    test "with no boolean gate, it includes both the enabled and disable boolean buttons", %{conn: conn, flag: flag} do
      out = Templates._flag_panel(conn: conn, flag: flag)
      assert String.contains?(out, ~s{<button id="enable-boolean-btn" type="submit"})
      assert String.contains?(out, ~s{<button id="disable-boolean-btn" type="submit"})
    end

    test "with an enabled boolean gate, it includes both the disable and clear boolean buttons", %{conn: conn, flag: flag} do
      f = %Flag{flag | gates: [Gate.new(:boolean, true)]}
      out = Templates._flag_panel(conn: conn, flag: f)
      assert String.contains?(out, ~s{<button id="disable-boolean-btn" type="submit"})
      assert String.contains?(out, ~s{<button id="clear-boolean-btn" type="submit"})
    end

    test "with a disabled boolean gate, it includes both the enable and clear boolean buttons", %{conn: conn, flag: flag} do
      f = %Flag{flag | gates: [Gate.new(:boolean, false)]}
      out = Templates._flag_panel(conn: conn, flag: f)
      assert String.contains?(out, ~s{<button id="enable-boolean-btn" type="submit"})
      assert String.contains?(out, ~s{<button id="clear-boolean-btn" type="submit"})
    end


    test "with no gates it reports the lists as empty", %{conn: conn, flag: flag} do
      group_gate = %Gate{type: :group, for: :rocks, enabled: true}
      actor_gate = %Gate{type: :actor, for: "moss:123", enabled: true}
      ptime_gate = %Gate{type: :percentage_of_time, for: 0.1, enabled: true}

      no_actors = %Flag{flag | gates: [group_gate, ptime_gate]}
      out = Templates._flag_panel(conn: conn, flag: no_actors)
      assert String.contains?(out, ~s{No actor gates.})
      refute String.contains?(out, ~s{No group gates.})

      no_groups = %Flag{flag | gates: [actor_gate, ptime_gate]}
      out = Templates._flag_panel(conn: conn, flag: no_groups)
      assert String.contains?(out, ~s{No group gates.})
      refute String.contains?(out, ~s{No actor gates.})

      no_percent = %Flag{flag | gates: [actor_gate, group_gate]}
      out = Templates._flag_panel(conn: conn, flag: no_percent)
      refute String.contains?(out, ~s{id="percentage_gate"})
      assert String.contains?(out, ~s{Roll out to})

      with_all = %Flag{flag | gates: [actor_gate, group_gate, ptime_gate]}
      out = Templates._flag_panel(conn: conn, flag: with_all)
      refute String.contains?(out, ~s{No actor gates.})
      refute String.contains?(out, ~s{No group gates.})
      assert String.contains?(out, ~s{<div id="percentage_gate"})
    end

    test "with actors and groups it contains their rows", %{conn: conn, flag: flag} do
      group_gate = %Gate{type: :group, for: :rocks, enabled: true}
      actor_gate = %Gate{type: :actor, for: "moss:123", enabled: true}
      flag = %Flag{flag | gates: [actor_gate, group_gate]}

      out = Templates._flag_panel(conn: conn, flag: flag)

      assert String.contains?(out, ~s{<li class="fwf-gate" id="actor_moss:123"})
      assert String.contains?(out, ~s{formaction="/pear/flags/avocado/actors/moss:123"})

      assert String.contains?(out, ~s{<li class="fwf-gate" id="group_rocks"})
      assert String.contains?(out, ~s{formaction="/pear/flags/avocado/groups/rocks"})
    end

    test "with actors and groups it contains their rows with escaped HTML and URLs", %{conn: conn, flag: flag} do
      group_gate = %Gate{type: :group, for: :rocks, enabled: true}
      actor_gate = %Gate{type: :actor, for: "moss:<h1>123</h1>", enabled: true}
      flag = %Flag{flag | gates: [actor_gate, group_gate]}

      out = Templates._flag_panel(conn: conn, flag: flag)

      assert String.contains?(out, ~s{<li class="fwf-gate" id="actor_moss:&lt;h1&gt;123&lt;/h1&gt;"})
      assert String.contains?(out, ~s{formaction="/pear/flags/avocado/actors/moss:%3Ch1%3E123%3C%2Fh1%3E"})

      assert String.contains?(out, ~s{<li class="fwf-gate" id="group_rocks"})
      assert String.contains?(out, ~s{formaction="/pear/flags/avocado/groups/rocks"})
    end
  end


  describe "new()" do
    test "it renders", %{conn: conn} do
      out = Templates.new(conn: conn)
      assert is_binary(out)
    end

    test "it includes the right content", %{conn: conn} do
      out = Templates.new(conn: conn)
      assert String.contains?(out, "<title>FunWithFlags - New Flag</title>")
      assert String.contains?(out, ~s{<form id="new-flag-form" action="/pear/flags" method="post"})
    end
  end

  describe "_flag_panel_not_found()" do
    test "it includes the right content", %{conn: conn} do
      out = Templates._flag_panel_not_found(conn: conn, name: "watermelon")
      assert String.contains?(out, ~s{The flag <strong>watermelon</strong> doesn't exist.})
      assert String.contains?(out, ~s{data-title="Not Found"})
    end

    test "it escapes the name", %{conn: conn} do
      out = Templates._flag_panel_not_found(conn: conn, name: "<i>melon</i>")
      assert String.contains?(out, ~s{<strong>&lt;i&gt;melon&lt;/i&gt;</strong>})
    end
  end


  describe "longest_flag_name()" do
    test "it is the name with the most characters, as a string" do
      assert nil == Templates.longest_flag_name([])
      flags = [%Flag{name: :ab}, %Flag{name: :"Ook? Ook!"}, %Flag{name: :abcd}]
      assert "Ook? Ook!" == Templates.longest_flag_name(flags)
    end
  end


  describe "html_breakable_name()" do
    test "it adds a <wbr> after each run of underscores and escapes everything else" do
      assert "abc" = Templates.html_breakable_name(:abc)
      assert "a_<wbr>b_<wbr>c" = Templates.html_breakable_name(:a_b_c)
      assert "a__<wbr>b" = Templates.html_breakable_name(:a__b)
      assert "trail_<wbr>" = Templates.html_breakable_name("trail_")
      assert "x_<wbr>&lt;i&gt;&amp;_<wbr>y" = Templates.html_breakable_name("x_<i>&_y")
    end

    test "removing the <wbr> tags gives back the escaped name" do
      for name <- [:analytics_trial_extension_rollout, :"Ook? Ook!", :"a_<b>_c", :__init__] do
        assert String.replace(Templates.html_breakable_name(name), "<wbr>", "") ==
                 IO.iodata_to_binary(FunWithFlags.UI.HTMLEscape.html_escape(name))
      end
    end
  end


  describe "url_safe()" do
    test "it encodes everything that would break a path segment" do
      assert "moss:123" = Templates.url_safe("moss:123")
      assert "user@example.com" = Templates.url_safe("user@example.com")
      assert "Ook%3F%20Ook!" = Templates.url_safe(:"Ook? Ook!")
      assert "a%2Fb%23c" = Templates.url_safe("a/b#c")
    end
  end
end
