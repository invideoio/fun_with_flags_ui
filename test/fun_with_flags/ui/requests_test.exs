defmodule FunWithFlags.UI.RequestsTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  import FunWithFlags.UI.TestUtils

  # The redesigned panel posts through shared section forms and per-button
  # formaction/name/value. These tests pin that every button still sends
  # exactly the request the routes have always taken (method, path, params),
  # replay those requests through the real router, and check the shared
  # header and other page-level markup.

  alias FunWithFlags.UI.{FormRequests, Router, SimpleActor}
  alias FunWithFlags.Gate

  @opts Router.init([])

  setup do
    clear_redis_test_db()
    :ok
  end

  setup_all do
    on_exit(__MODULE__, fn -> clear_redis_test_db() end)
    :ok
  end

  defp contract_flag do
    {:ok, false} = FunWithFlags.disable(:contract)
    {:ok, true} = FunWithFlags.enable(:contract, for_actor: %SimpleActor{id: "user:1"})
    {:ok, false} = FunWithFlags.disable(:contract, for_actor: %SimpleActor{id: "user:2"})
    {:ok, true} = FunWithFlags.enable(:contract, for_group: "beta")
    {:ok, true} = FunWithFlags.enable(:contract, for_percentage_of: {:actors, 0.25})
  end

  defp panel_requests(path) do
    request!(:get, path).resp_body
    |> FormRequests.requests()
    |> Enum.map(&{&1.method, &1.path, &1.params})
  end

  describe "without JS, every panel button sends the same request as before" do
    test "the exact set of requests" do
      contract_flag()
      t = FormRequests.typed()

      expected =
        MapSet.new([
          # default: currently Off, so the On segment is the button; Reset
          {"PATCH", "/flags/contract/boolean", %{"enabled" => "true"}},
          {"DELETE", "/flags/contract/boolean", %{}},
          # actors: a switch (flips) and a remove per row; two add buttons
          {"PATCH", "/flags/contract/actors/user:1", %{"enabled" => "false"}},
          {"DELETE", "/flags/contract/actors/user:1", %{}},
          {"PATCH", "/flags/contract/actors/user:2", %{"enabled" => "true"}},
          {"DELETE", "/flags/contract/actors/user:2", %{}},
          {"POST", "/flags/contract/actors", %{"actor_id" => t, "enabled" => "true"}},
          {"POST", "/flags/contract/actors", %{"actor_id" => t, "enabled" => "false"}},
          # groups
          {"PATCH", "/flags/contract/groups/beta", %{"enabled" => "false"}},
          {"DELETE", "/flags/contract/groups/beta", %{}},
          {"POST", "/flags/contract/groups", %{"group_name" => t, "enabled" => "true"}},
          {"POST", "/flags/contract/groups", %{"group_name" => t, "enabled" => "false"}},
          # percentage: remove, and set (the current type preselected)
          {"DELETE", "/flags/contract/percentage", %{}},
          # the form says its value is a percent (round 9)
          {"POST", "/flags/contract/percentage", %{"percent_value" => t, "percent_type" => "actors", "percent_unit" => "percent"}},
          # delete flag
          {"DELETE", "/flags/contract", %{}}
        ])

      for path <- ["/flags/contract/panel", "/flags/contract"] do
        got = path |> panel_requests() |> MapSet.new()
        panel_only = MapSet.filter(got, fn {_, p, _} -> String.starts_with?(p, "/flags/contract") end)
        assert panel_only == expected, "#{path}\nextra: #{inspect(MapSet.difference(panel_only, expected))}\nmissing: #{inspect(MapSet.difference(expected, panel_only))}"
      end
    end

    # Round 13: plain questions that name the flag ("Remove user:1 from
    # contract?") instead of "Are you sure you want to clear …".
    test "every destructive button carries a confirm" do
      contract_flag()
      reqs = FormRequests.requests(request!(:get, "/flags/contract/panel").resp_body)

      for r <- reqs, r.method == "DELETE" do
        assert is_binary(r.confirm) and r.confirm =~ "contract" and r.confirm =~ "?", inspect(r)
        refute r.confirm =~ ~r/Are you sure|clear|\?\./, inspect(r)
      end
    end

    test "replayed through the router, they do what they always did, with the same redirects" do
      contract_flag()

      reqs =
        request!(:get, "/flags/contract/panel").resp_body
        |> FormRequests.requests()
        |> Enum.reject(&(&1.method == "DELETE" and &1.path == "/flags/contract"))

      for r <- reqs do
        params =
          r.params
          |> Enum.map(fn
            {"actor_id", _} -> {"actor_id", "user:9"}
            {"group_name", _} -> {"group_name", "qa"}
            {"percent_value", _} -> {"percent_value", "50"}
            other -> other
          end)
          |> Map.new()
          |> then(fn p -> if r.method == "POST", do: p, else: Map.put(p, "_method", r.method) end)

        conn = request!(:post, r.path, params)
        assert 302 = conn.status, inspect(r)
        [location] = get_resp_header(conn, "location")
        assert String.starts_with?(location, "/flags/contract"), inspect({r, location})
      end

      # a few effects, after all of the above ran in order
      flag = FunWithFlags.get_flag(:contract)
      assert Enum.any?(flag.gates, &match?(%Gate{type: :actor, for: "user:9"}, &1))
      assert Enum.any?(flag.gates, &match?(%Gate{type: :group, for: "qa"}, &1))
    end

    test "the switch on a row flips that one gate" do
      contract_flag()

      [switch] =
        request!(:get, "/flags/contract/panel").resp_body
        |> FormRequests.requests()
        |> Enum.filter(&(&1.path == "/flags/contract/actors/user:1" and &1.method == "PATCH"))

      conn = request!(:post, switch.path, Map.put(switch.params, "_method", "PATCH"))
      assert ["/flags/contract#actor_user:1"] = get_resp_header(conn, "location")
      refute FunWithFlags.enabled?(:contract, for: %SimpleActor{id: "user:1"})
    end

    test "dot-segment IDs never produce a request to the flag itself" do
      {:ok, false} = FunWithFlags.disable(:walnut)
      {:ok, true} = FunWithFlags.enable(:walnut, for_actor: %SimpleActor{id: ".."})
      {:ok, true} = FunWithFlags.enable(:walnut, for_group: ".")

      reqs = panel_requests("/flags/walnut/panel")
      refute Enum.any?(reqs, fn {_, p, _} -> p =~ ~r{/\.\.?$} or p =~ ~r{/\./} end), inspect(reqs)

      assert {"PATCH", "/flags/walnut/actors", %{"actor_id" => "..", "enabled" => "false"}} in reqs
      assert {"DELETE", "/flags/walnut/actors", %{"actor_id" => ".."}} in reqs
      assert {"PATCH", "/flags/walnut/groups", %{"group_name" => ".", "enabled" => "false"}} in reqs
      assert {"DELETE", "/flags/walnut/groups", %{"group_name" => "."}} in reqs
    end
  end

  describe "round 7" do
    test "the flags pages autofocus nothing (the first keystroke is a shortcut)" do
      contract_flag()

      for path <- ["/flags", "/flags/contract"] do
        refute request!(:get, path).resp_body =~ "autofocus", path
      end
    end

    test "Add and 'Add as off' sit together in one group, and still send the same requests" do
      contract_flag()
      body = request!(:get, "/flags/contract/panel").resp_body

      for kind <- ["actor", "group"] do
        [_, form] = String.split(body, ~s{<form id="fwf-new-#{kind}-form"}, parts: 2)
        [form | _] = String.split(form, "</form>", parts: 2)
        [_, group] = String.split(form, ~s{<span class="fwf-add-actions">}, parts: 2)
        [group | _] = String.split(group, "</span>\n", parts: 2)
        assert group =~ ~s{name="enabled" value="true"}, kind
        assert group =~ ~s{name="enabled" value="false"}, kind
        assert group =~ "Add as off", kind
      end
    end
  end


  describe "round 9: the percentage form sends a percent, and the server converts" do
    defp set_percent(flag, params) do
      request!(:post, "/flags/#{flag}/percentage", params)
    end

    defp pct_gate(flag) do
      Enum.find(FunWithFlags.get_flag(flag).gates, &(&1.type in [:percentage_of_actors, :percentage_of_time]))
    end

    test "percent mode converts exactly" do
      for {input, fraction} <- [{"25", 0.25}, {"42.1337", 0.421337}, {"0.5", 0.005}, {"99.99", 0.9999}, {" 5 ", 0.05}, {".5", 0.005}] do
        {:ok, false} = FunWithFlags.disable(:pct)
        conn = set_percent(:pct, %{percent_value: input, percent_type: "actors", percent_unit: "percent"})
        assert 302 = conn.status, input
        assert ["/flags/pct#percentage_gate"] = get_resp_header(conn, "location")
        assert %Gate{type: :percentage_of_actors, for: ^fraction} = pct_gate(:pct), input
        FunWithFlags.clear(:pct)
      end
    end

    test "percent mode rejects anything that isn't a plain 0 < x < 100, and writes nothing" do
      {:ok, false} = FunWithFlags.disable(:pct)

      for {input, message} <- [
            {"100", "is outside the &#39;0 &lt; x &lt; 100&#39; range"},
            {"0", "is outside the &#39;0 &lt; x &lt; 100&#39; range"},
            {"-1", "is not a valid percentage"},
            {"1e-3", "is not a valid percentage"},
            {"abc", "is not a valid percentage"},
            {"25abc", "is not a valid percentage"},
            {"", "can&#39;t be blank"},
            {"  ", "can&#39;t be blank"}
          ] do
        conn = set_percent(:pct, %{percent_value: input, percent_type: "time", percent_unit: "percent"})
        assert 400 = conn.status, inspect(input)
        assert conn.resp_body =~ "The percentage value " <> message, inspect(input)
        assert pct_gate(:pct) == nil, inspect(input)
      end
    end

    test "percent mode: huge integer parts are a 400, not a crash, and write nothing" do
      {:ok, false} = FunWithFlags.disable(:pct)

      for input <- [String.duplicate("9", 400), "1" <> String.duplicate("0", 400) <> ".0"] do
        conn = set_percent(:pct, %{percent_value: input, percent_type: "time", percent_unit: "percent"})
        assert 400 = conn.status
        assert conn.resp_body =~ "The percentage value is outside the &#39;0 &lt; x &lt; 100&#39; range."
        assert pct_gate(:pct) == nil
      end

      # leading zeros don't count as integer digits
      conn = set_percent(:pct, %{percent_value: "0000025", percent_type: "time", percent_unit: "percent"})
      assert 302 = conn.status
      assert %Gate{for: 0.25} = pct_gate(:pct)
    end

    test "without percent_unit the value is still a fraction, exactly as before" do
      {:ok, false} = FunWithFlags.disable(:pct)
      conn = set_percent(:pct, %{percent_value: "0.5", percent_type: "time"})
      assert ["/flags/pct#percentage_gate"] = get_resp_header(conn, "location")
      assert %Gate{type: :percentage_of_time, for: 0.5} = pct_gate(:pct)

      # master's parse, unchanged: Float.parse accepts exponent form
      set_percent(:pct, %{percent_value: "1e-3", percent_type: "time"})
      assert %Gate{for: 0.001} = pct_gate(:pct)

      for bad <- ["25", "1", "0", "abc", ""] do
        assert 400 = set_percent(:pct, %{percent_value: bad, percent_type: "time"}).status, bad
      end

      # any other unit value is treated as no unit
      set_percent(:pct, %{percent_value: "0.3", percent_type: "time", percent_unit: "fraction"})
      assert %Gate{for: 0.3} = pct_gate(:pct)
    end

    test "the rendered form carries the unit and no client-side conversion hooks" do
      {:ok, false} = FunWithFlags.disable(:pct)
      body = request!(:get, "/flags/pct/panel").resp_body
      [_, form] = String.split(body, ~s{<form id="fwf-percentage-form"}, parts: 2)
      [form | _] = String.split(form, "</form>", parts: 2)
      assert form =~ ~s{<input type="hidden" name="percent_unit" value="percent">}
      assert form =~ ~s{<span id="fwf-pct-unit">%</span>}
      assert form =~ ~s{placeholder="25"}
      refute form =~ "data-fwf"
      refute form =~ "fraction"
      refute body =~ "fwf-nojs-only"
    end

    test "the percentage type defaults to time (master), or to the current gate's type" do
      {:ok, false} = FunWithFlags.disable(:pct)
      body = request!(:get, "/flags/pct/panel").resp_body
      assert body =~ ~s{value="time" checked>}
      refute body =~ ~s{value="actors" checked>}

      FunWithFlags.enable(:pct, for_percentage_of: {:actors, 0.1})
      body = request!(:get, "/flags/pct/panel").resp_body
      assert body =~ ~s{value="actors" checked>}

      FunWithFlags.enable(:pct, for_percentage_of: {:time, 0.1})
      body = request!(:get, "/flags/pct/panel").resp_body
      assert body =~ ~s{value="time" checked>}
    end
  end

  describe "round 9: add forms" do
    test "the default (Enter) button is labelled for what it does: Add as on" do
      contract_flag()
      body = request!(:get, "/flags/contract/panel").resp_body

      for kind <- ["actor", "group"] do
        [_, form] = String.split(body, ~s{<form id="fwf-new-#{kind}-form"}, parts: 2)
        [form | _] = String.split(form, "</form>", parts: 2)
        # the first submit button is the one Enter uses
        [first | _] = Regex.scan(~r{<button type="submit"[^>]*>(.*?)</button>}s, form, capture: :all_but_first)
        assert hd(first) =~ "Add as on", kind
        [enabled] = Regex.run(~r{<button type="submit" name="enabled" value="(\w+)"}, form, capture: :all_but_first)
        assert enabled == "true"
        assert form =~ "Add as off"
      end
    end

    test "add inputs have ids no target can produce, and their labels point at them" do
      {:ok, false} = FunWithFlags.disable(:ids)
      # targets that used to collide with the inputs' ids
      FunWithFlags.enable(:ids, for_actor: %SimpleActor{id: "id"})
      FunWithFlags.enable(:ids, for_group: "name")
      body = request!(:get, "/flags/ids/panel").resp_body

      assert body =~ ~s{<label class="fwf-sr" for="fwf-add-actor-input">}
      assert body =~ ~s{id="fwf-add-actor-input" name="actor_id"}
      assert body =~ ~s{<label class="fwf-sr" for="fwf-add-group-input">}
      assert body =~ ~s{id="fwf-add-group-input" name="group_name"}

      ids = Regex.scan(~r/\sid="([^"]+)"/, body, capture: :all_but_first) |> List.flatten()
      assert ids == Enum.uniq(ids), inspect(ids -- Enum.uniq(ids))
    end

    test "error messages are escaped" do
      {:ok, false} = FunWithFlags.disable(:esc)
      body = request!(:post, "/flags/esc/actors", %{actor_id: "a?b", enabled: "true"}).resp_body
      assert body =~ "The actor ID includes invalid characters: &#39;?&#39;."
      body = request!(:post, "/flags/esc/percentage", %{percent_value: "x", percent_type: "time", percent_unit: "percent"}).resp_body
      assert body =~ ~s{<p class="fwf-error" role="alert">The percentage value is not a valid percentage}
    end
  end


  describe "long gate lists" do
    test "show the first 10 rows and the rest behind 'Show all N'" do
      {:ok, false} = FunWithFlags.disable(:many)
      for i <- 1..15, do: FunWithFlags.enable(:many, for_actor: %SimpleActor{id: "user:#{i}"})

      body = request!(:get, "/flags/many/panel").resp_body
      [before_more, after_more] = String.split(body, ~s{<details class="fwf-more" data-gate-more>}, parts: 2)
      assert length(Regex.scan(~r/<li class="fwf-gate"/, before_more)) == 10
      assert after_more =~ "Show all 15"
      [tail | _] = String.split(after_more, "</details>", parts: 2)
      assert length(Regex.scan(~r/<li class="fwf-gate"/, tail)) == 5
      assert body =~ "Actors <span class=\"fwf-section-count\">· 15</span>"
      assert body =~ "data-gate-filter"
    end

    test "short lists have no filter box and no collapse" do
      {:ok, false} = FunWithFlags.disable(:few)
      FunWithFlags.enable(:few, for_actor: %SimpleActor{id: "user:1"})
      body = request!(:get, "/flags/few/panel").resp_body
      refute body =~ "data-gate-more"
      refute body =~ "data-gate-filter"
    end
  end

  describe "the panel answers 'who is this on for' first" do
    test "the summary sentence is in the panel header" do
      contract_flag()
      body = request!(:get, "/flags/contract/panel").resp_body
      assert body =~
               ~s{<p class="fwf-summary">On for 1 actor and 1 group and 25% of actors; off for 1 actor. An actor&#39;s own gate wins over its groups.</p>} or
               body =~ ~s{<p class="fwf-summary">On for 1 actor and 1 group and 25% of actors; off for 1 actor. An actor's own gate wins over its groups.</p>}
    end
  end

  describe "the shared header" do
    test "is on every page, with the current page marked" do
      {:ok, true} = FunWithFlags.enable(:hazel)

      for {path, current} <- [
            {"/flags", "flags"},
            {"/flags/hazel", "flags"},
            {"/new", nil},
            {"/settings", "settings"},
            {"/audit_logs", "audit"}
          ] do
        body = request!(:get, path).resp_body
        assert body =~ ~s{<header class="fwf-header" id="fwf-top-bar" data-icons="/assets/icons/hugeicons.svg">}, path
        assert body =~ ~s{data-shortcuts-open}, path
        assert body =~ ~s{data-theme-toggle}, path
        refute body =~ "bootstrap.min.css", path
        refute body =~ "glyphicon", path

        marked = Regex.scan(~r/data-nav="(\w+)" aria-current="page"/, body, capture: :all_but_first) |> List.flatten()
        assert marked == List.wrap(current), "#{path}: #{inspect(marked)}"
      end
    end

    test "shows the env badge and the viewer on every page" do
      prev = {System.get_env("APP_NAME"), System.get_env("APP_ENV")}
      on_exit(fn ->
        {a, e} = prev
        if a, do: System.put_env("APP_NAME", a), else: System.delete_env("APP_NAME")
        if e, do: System.put_env("APP_ENV", e), else: System.delete_env("APP_ENV")
      end)

      System.put_env("APP_NAME", "copilot")
      System.put_env("APP_ENV", "production")
      header = FunWithFlags.Config.audit_log_user_id_header()

      for path <- ["/flags", "/new", "/settings", "/audit_logs"] do
        body =
          conn(:get, path)
          |> put_req_header(header, "ana@example.com")
          |> Router.call(@opts)
          |> Map.fetch!(:resp_body)

        assert body =~ ~s{<span class="fwf-app-badge fwf-env-prod" title="APP_NAME · APP_ENV">copilot · production</span>}, path
        assert body =~ ~s{signed in as <strong>ana@example.com</strong>}, path
      end
    end
  end

  describe "settings" do
    test "the success banner can be dismissed without JS" do
      body = request!(:get, "/settings?success=imported_12").resp_body
      assert body =~ "Successfully imported 12 flags"
      assert body =~ ~s{<a href="/settings" class="fwf-banner-close" aria-label="Dismiss">}
    end

    # Round 13: the import form only renders where import works (APP_ENV
    # "dev"); elsewhere the section is one line. The form, when shown, sends
    # what it always did.
    test "the theme control is a real control, and the import/export forms are unchanged" do
      prev = System.get_env("APP_ENV")
      on_exit(fn -> if prev, do: System.put_env("APP_ENV", prev), else: System.delete_env("APP_ENV") end)
      System.put_env("APP_ENV", "dev")

      body = request!(:get, "/settings").resp_body
      assert body =~ ~s{<input type="radio" name="fwf-theme" value="system" checked>}
      reqs = body |> FormRequests.requests() |> Enum.map(&{&1.method, &1.path, &1.params})
      assert {"POST", "/settings/export", %{}} in reqs
      assert {"POST", "/settings/import", %{"file" => :file, "mode" => "overwrite"}} in reqs
      refute body =~ "only available in development"
      refute body =~ ~r/<(input|button)[^>]*\sdisabled/
    end

    test "outside dev, import is one line: no file picker, no modes, no dead button" do
      prev = System.get_env("APP_ENV")
      on_exit(fn -> if prev, do: System.put_env("APP_ENV", prev), else: System.delete_env("APP_ENV") end)

      for env <- [nil, "production", "staging"] do
        if env, do: System.put_env("APP_ENV", env), else: System.delete_env("APP_ENV")
        body = request!(:get, "/settings").resp_body
        assert body =~ ~s{<p class="fwf-import-off">Import is only available in development.</p>}, inspect(env)
        refute body =~ "disabled in production"
        refute body =~ ~s{name="file"}
        refute body =~ ~s{name="mode"}
        refute body =~ "Import flags</button>"
        reqs = body |> FormRequests.requests() |> Enum.map(&{&1.method, &1.path})
        assert reqs == [{"POST", "/settings/export"}], inspect(env)
      end
    end
  end

  describe "no inline styles or event handlers (hosts send a CSP)" do
    test "on every page" do
      contract_flag()

      for path <- ["/flags", "/flags/contract", "/new", "/settings", "/audit_logs", "/flags/contract/panel"] do
        body = request!(:get, path).resp_body
        refute body =~ ~r/\sstyle="/, path
        refute body =~ ~r/\son[a-z]+="/, path
        # the one inline script is the pre-existing theme bootstrap in the head
        assert length(Regex.scan(~r/<script>/, body)) <= 1, path
      end
    end
  end

  defp request!(method, path) do
    conn(method, path) |> Router.call(@opts)
  end

  defp request!(method, path, params) when is_map(params) do
    conn(method, path, Plug.Conn.Query.encode(params))
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> Router.call(@opts)
  end
end
