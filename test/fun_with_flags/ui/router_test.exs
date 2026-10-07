defmodule FunWithFlags.UI.RouterTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  import FunWithFlags.UI.TestUtils

  alias FunWithFlags.UI.{Router, Templates}
  alias FunWithFlags.{Flag, Gate}

  setup do
    clear_redis_test_db()
    :ok
  end

  setup_all do
    on_exit(__MODULE__, fn() -> clear_redis_test_db() end)
    :ok
  end

  @opts Router.init([])

  describe "GET /" do
    test "redirects to /flags" do
      conn = request!(:get, "/")
      assert 302 = conn.status
      assert ["/flags"] = get_resp_header(conn, "location")
    end
  end


  describe "GET /new" do
    test "responds with HTML" do
      conn = request!(:get, "/flags")
      assert 200 = conn.status
      assert is_binary(conn.resp_body)
      assert ["text/html; charset=utf-8"] = get_resp_header(conn, "content-type")
    end
  end

  describe "POST /flags" do
    test "with valid parameters it creates the flag and redirects to its page" do
      refute Enum.member?(elem(FunWithFlags.all_flag_names, 1), :mango)
      conn = request!(:post, "/flags", %{flag_name: "mango"})
      assert Enum.member?(elem(FunWithFlags.all_flag_names, 1), :mango)

      assert 302 = conn.status
      assert ["/flags/mango"] = get_resp_header(conn, "location")
    end

    test "with invalid parameters it re-renders the page" do
      initially = FunWithFlags.all_flag_names
      conn = request!(:post, "/flags", %{flag_name: ""})
      assert ^initially = FunWithFlags.all_flag_names # no changes

      assert 400 = conn.status
      assert is_binary(conn.resp_body)
      assert ["text/html; charset=utf-8"] = get_resp_header(conn, "content-type")
    end


    test "with valid parameters but a name that is already in use it re-renders the page" do
      {:ok, true} = FunWithFlags.enable :papaya
      assert Enum.member?(elem(FunWithFlags.all_flag_names, 1), :papaya)

      initially = FunWithFlags.all_flag_names
      conn = request!(:post, "/flags", %{flag_name: "papaya"})
      assert ^initially = FunWithFlags.all_flag_names # no changes

      assert 400 = conn.status
      assert is_binary(conn.resp_body)
      assert ["text/html; charset=utf-8"] = get_resp_header(conn, "content-type")
    end
  end


  describe "GET /flags" do
    test "responds with HTML" do
      conn = request!(:get, "/flags")
      assert 200 = conn.status
      assert is_binary(conn.resp_body)
      assert ["text/html; charset=utf-8"] = get_resp_header(conn, "content-type")
    end

    test "when some flags exist, the response contains their names" do
      name = unique_atom()
      FunWithFlags.enable(name)

      conn = request!(:get, "/flags")
      assert String.contains?(conn.resp_body, to_string(name))
    end

    test "it renders the list and the empty panel" do
      {:ok, true} = FunWithFlags.enable :apricot
      {:ok, false} = FunWithFlags.disable :blueberry

      conn = request!(:get, "/flags")
      body = conn.resp_body
      assert String.contains?(body, ~s{<ul class="fwf-list" id="fwf-list">})
      assert String.contains?(body, ~s{<a class="fwf-row-link" href="/flags/apricot">})
      assert String.contains?(body, ~s{<a class="fwf-row-link" href="/flags/blueberry">})
      assert String.contains?(body, ~s{<section class="fwf-panel-col" id="fwf-panel"})
      assert String.contains?(body, "Select a flag to see who it is on for.")
      assert String.contains?(body, ~s{<body class="fwf-flags-page"\n})
      assert String.contains?(body, "2 flags")
    end

    test "it labels flag states On, Partial and Off" do
      {:ok, true} = FunWithFlags.enable :on_flag
      {:ok, false} = FunWithFlags.disable :partial_flag
      {:ok, true} = FunWithFlags.enable :partial_flag, for_group: "beta"
      {:ok, false} = FunWithFlags.disable :off_flag

      body = request!(:get, "/flags").resp_body
      assert row(body, "on_flag") =~ ~s{<span class="fwf-pill fwf-pill-on">On</span>}
      assert row(body, "partial_flag") =~ ~s{<span class="fwf-pill fwf-pill-partial">Partial</span>}
      assert row(body, "off_flag") =~ ~s{<span class="fwf-pill fwf-pill-off">Off</span>}
      refute body =~ ">Enabled<"
    end

    test "rows carry their gate targets for the search, once" do
      {:ok, false} = FunWithFlags.disable :guava
      {:ok, true} = FunWithFlags.enable :guava, for_actor: %FunWithFlags.UI.SimpleActor{id: "workspace:123"}
      {:ok, true} = FunWithFlags.enable :guava, for_actor: %FunWithFlags.UI.SimpleActor{id: "email:ana@example.com"}
      {:ok, true} = FunWithFlags.enable :guava, for_group: "beta"
      {:ok, true} = FunWithFlags.enable :guava, for_percentage_of: {:actors, 0.25}

      body = request!(:get, "/flags").resp_body
      guava = row(body, "guava")
      assert guava =~ ~s{data-actors="email:ana@example.com\nworkspace:123"}
      assert guava =~ ~s{data-groups="beta"}
      assert guava =~ ~s{data-types="boolean actor group percentage"}
      assert guava =~ "2 actors · 1 group · 25% of actors"
      assert length(String.split(body, "workspace:123")) == 2
    end

    test "with a namespace, every link and asset is prefixed" do
      {:ok, true} = FunWithFlags.enable :lychee

      body = request!(:get, "/flags", nil, Router.init(namespace: "internal/feature-flags")).resp_body
      assert String.contains?(body, ~s{data-base="/internal/feature-flags/flags"})
      assert String.contains?(body, ~s{href="/internal/feature-flags/flags/lychee"})
      assert String.contains?(body, ~s{href="/internal/feature-flags/new"})
      assert String.contains?(body, ~s{href="/internal/feature-flags/audit_logs"})
      assert String.contains?(body, ~s{src="/internal/feature-flags/assets/flags_core.js"})
      assert String.contains?(body, ~s{src="/internal/feature-flags/assets/flags.js"})
      refute Regex.match?(~r{(href|src|action)="/(flags|new|assets|audit_logs|settings)}, body)
    end

    test "every page sets the viewport meta tag" do
      {:ok, true} = FunWithFlags.enable :mulberry
      viewport = ~s{<meta name="viewport" content="width=device-width, initial-scale=1">}

      for path <- ["/flags", "/flags/mulberry", "/flags/missing_mulberry", "/new", "/settings", "/audit_logs"] do
        assert String.contains?(request!(:get, path).resp_body, viewport), path
      end
    end

    test "without the viewer header there is no Mine chip and no signed-in line" do
      body = request!(:get, "/flags").resp_body
      refute String.contains?(body, ~s{data-chip="mine"})
      refute String.contains?(body, "signed in as")
      assert String.contains?(body, ~s{data-viewer=""})
    end

    test "with the viewer header there is a Mine chip and a signed-in line" do
      header = FunWithFlags.Config.audit_log_user_id_header()
      body =
        conn(:get, "/flags")
        |> put_req_header(header, "ana@example.com")
        |> Router.call(@opts)
        |> Map.fetch!(:resp_body)

      assert String.contains?(body, ~s{data-chip="mine"})
      assert String.contains?(body, ~s{signed in as <strong>ana@example.com</strong>})
      assert String.contains?(body, ~s{data-viewer="ana@example.com"})
    end

    test "an actor gate for the viewer is described under the summary, on the page and in the panel" do
      header = FunWithFlags.Config.audit_log_user_id_header()
      {:ok, true} = FunWithFlags.enable :quince, for_actor: %FunWithFlags.UI.SimpleActor{id: "email:ana@example.com"}
      {:ok, false} = FunWithFlags.disable :quince_off, for_actor: %FunWithFlags.UI.SimpleActor{id: "email:ana@example.com"}
      {:ok, true} = FunWithFlags.enable :quince_case, for_actor: %FunWithFlags.UI.SimpleActor{id: "email:Ana@Invideo.io"}

      get = fn path, viewer ->
        conn = conn(:get, path)
        conn = if viewer, do: put_req_header(conn, header, viewer), else: conn
        conn |> Router.call(@opts) |> Map.fetch!(:resp_body)
      end

      for path <- ["/flags/quince", "/flags/quince/panel"] do
        body = get.(path, "ana@example.com")
        assert body =~ ~s{<p class="fwf-for-you">Your actor gate email:ana@example.com is on.</p>}
        refute body =~ ~r/for you/i
      end

      assert get.("/flags/quince_off", "ana@example.com") =~
               ~s{<p class="fwf-for-you">Your actor gate email:ana@example.com is off.</p>}

      # a case variant, someone else, or no header: nothing
      refute get.("/flags/quince_case", "ana@invideo.io") =~ "fwf-for-you"
      refute get.("/flags/quince_off", "Ana@example.com") =~ "fwf-for-you"
      refute get.("/flags/quince", "bob@example.com") =~ "fwf-for-you"
      refute get.("/flags/quince", nil) =~ "fwf-for-you"
      refute get.("/flags/quince/panel", nil) =~ "fwf-for-you"
    end

    test "the viewer header value is escaped" do
      header = FunWithFlags.Config.audit_log_user_id_header()
      body =
        conn(:get, "/flags")
        |> put_req_header(header, "<b>x</b>")
        |> Router.call(@opts)
        |> Map.fetch!(:resp_body)

      refute String.contains?(body, "<b>x</b>")
      assert String.contains?(body, "&lt;b&gt;x&lt;/b&gt;")
    end

    test "the New chip only shows when some flag has a creation date (never on Redis)" do
      {:ok, true} = FunWithFlags.enable :nectarine
      body = request!(:get, "/flags").resp_body
      refute String.contains?(body, ~s{data-chip="new"})
      assert row(body, "nectarine") =~ ~s{data-created=""}
    end

    test "APP_NAME and APP_ENV show as a badge, and nothing shows when they are unset" do
      prev = {System.get_env("APP_NAME"), System.get_env("APP_ENV")}
      on_exit(fn -> restore_env(prev) end)

      System.delete_env("APP_NAME")
      System.delete_env("APP_ENV")
      refute String.contains?(request!(:get, "/flags").resp_body, "fwf-app-badge")

      System.put_env("APP_NAME", "copilot")
      System.put_env("APP_ENV", "production")
      body = request!(:get, "/flags").resp_body
      assert String.contains?(body, ~s{<span class="fwf-app-badge fwf-env-prod" title="APP_NAME · APP_ENV">copilot · production</span>})
    end
  end


  describe "GET /flags/:name" do
    test "when the flag exists, it responds the the details page" do
      {:ok, true} = FunWithFlags.enable :coconut

      conn = request!(:get, "/flags/coconut")
      assert 200 = conn.status
      assert is_binary(conn.resp_body)
      assert ["text/html; charset=utf-8"] = get_resp_header(conn, "content-type")
    end

    test "when the flag doesn't exists, it responds the the details page" do
      conn = request!(:get, "/flags/#{unique_atom()}")
      assert 404 = conn.status
      assert is_binary(conn.resp_body)
      assert ["text/html; charset=utf-8"] = get_resp_header(conn, "content-type")
    end

    test "it renders the same page as /flags, with the list and the flag's panel" do
      {:ok, true} = FunWithFlags.enable :coconut
      {:ok, true} = FunWithFlags.enable :damson

      body = request!(:get, "/flags/coconut").resp_body
      assert String.contains?(body, "<title>FunWithFlags - coconut</title>")
      assert String.contains?(body, ~s{<ul class="fwf-list" id="fwf-list">})
      assert String.contains?(body, ~s{<a class="fwf-row-link" href="/flags/damson">})
      assert String.contains?(body, ~s{<a class="fwf-row-link" href="/flags/coconut" aria-current="page">})
      assert String.contains?(body, ~s{<div class="fwf-panel fwf-fade-in" data-name="coconut"})
      assert String.contains?(body, ~s{<body class="fwf-flags-page fwf-has-selection"})
      assert body =~ ~s{<form id="fwf-new-actor-form" class="fwf-add" action="/flags/coconut/actors" method="post">}
      assert String.contains?(body, "Audit logging is not enabled.")
    end

    test "an unknown flag renders the page with a not-found panel and a 404" do
      {:ok, true} = FunWithFlags.enable :elderberry
      name = "missing_#{unique_atom()}"

      conn = request!(:get, "/flags/#{name}")
      assert 404 = conn.status
      assert String.contains?(conn.resp_body, "<title>FunWithFlags - Not Found</title>")
      assert String.contains?(conn.resp_body, ~s{<a class="fwf-row-link" href="/flags/elderberry">})
      assert String.contains?(conn.resp_body, ~s{The flag <strong>#{name}</strong> doesn't exist.})
      refute conn.resp_body =~ ~r/class="fwf-row-link"[^>]*aria-current/
    end

    test "a long snake_case name breaks after underscores in the list and the panel, nowhere else" do
      name = :analytics_trial_extension_rollout
      {:ok, true} = FunWithFlags.enable name

      body = request!(:get, "/flags/analytics_trial_extension_rollout").resp_body
      row = row(body, "analytics_trial_extension_rollout")
      assert row =~ ~s{<span class="fwf-row-name">analytics_<wbr>trial_<wbr>extension_<wbr>rollout</span>}
      assert row =~ ~s{href="/flags/analytics_trial_extension_rollout"}
      assert body =~ ~s{<h1 class="fwf-panel-title">analytics_<wbr>trial_<wbr>extension_<wbr>rollout</h1>}
      assert body =~ ~s{data-copy="analytics_trial_extension_rollout"}
      assert body =~ "<title>FunWithFlags - analytics_trial_extension_rollout</title>"
    end

    test "a flag whose name needs escaping and encoding" do
      name = :"Ook? <b>Ook!</b>"
      {:ok, true} = FunWithFlags.enable name
      encoded = "Ook%3F%20%3Cb%3EOok!%3C%2Fb%3E"

      list = request!(:get, "/flags").resp_body
      assert String.contains?(list, ~s{data-name="Ook? &lt;b&gt;Ook!&lt;/b&gt;"})
      assert String.contains?(list, ~s{href="/flags/#{encoded}"})
      refute String.contains?(list, "<b>Ook!</b>")

      conn = request!(:get, "/flags/#{encoded}")
      assert 200 = conn.status
      assert String.contains?(conn.resp_body, ~s{<h1 class="fwf-panel-title">Ook? &lt;b&gt;Ook!&lt;/b&gt;</h1>})
      assert String.contains?(conn.resp_body, ~s{action="/flags/#{encoded}/actors"})
      refute String.contains?(conn.resp_body, "<b>Ook!</b>")

      panel = request!(:get, "/flags/#{encoded}/panel")
      assert 200 = panel.status
      assert String.contains?(panel.resp_body, ~s{data-name="Ook? &lt;b&gt;Ook!&lt;/b&gt;"})

      conn = request!(:patch, "/flags/#{encoded}/boolean", %{enabled: "false"})
      assert get_resp_header(conn, "location") == ["/flags/#{encoded}"]
    end
  end


  describe "GET /flags/:name/panel" do
    test "it responds with just the panel of the flag, without the list" do
      {:ok, true} = FunWithFlags.enable :fig
      {:ok, true} = FunWithFlags.enable :grape

      conn = request!(:get, "/flags/fig/panel")
      assert 200 = conn.status
      assert ["text/html; charset=utf-8"] = get_resp_header(conn, "content-type")
      assert ["no-store"] = get_resp_header(conn, "cache-control")
      assert String.starts_with?(conn.resp_body, ~s{<div class="fwf-panel fwf-fade-in" data-name="fig"})
      assert String.contains?(conn.resp_body, ~s{<form id="fwf-delete-flag-form" action="/flags/fig" method="post">})
      assert String.contains?(conn.resp_body, "Audit logging is not enabled.")
      refute String.contains?(conn.resp_body, "<html")
      refute String.contains?(conn.resp_body, "fwf-list")
      refute String.contains?(conn.resp_body, "grape")
    end

    test "it responds with a 404 not-found fragment for an unknown flag" do
      name = "missing_#{unique_atom()}"
      conn = request!(:get, "/flags/#{name}/panel")
      assert 404 = conn.status
      assert String.contains?(conn.resp_body, ~s{The flag <strong>#{name}</strong> doesn't exist.})
      refute String.contains?(conn.resp_body, "<html")
    end

    test "with a namespace, the panel's forms are prefixed" do
      {:ok, true} = FunWithFlags.enable :fig
      body = request!(:get, "/flags/fig/panel", nil, Router.init(namespace: "ns")).resp_body
      assert String.contains?(body, ~s{action="/ns/flags/fig/boolean"})
      assert String.contains?(body, ~s{<a class="fwf-back" href="/ns/flags">})
    end
  end


  describe "round 13 copy in the panel" do
    test "confirms are plain questions that name what goes and from where" do
      {:ok, true} = FunWithFlags.enable :fig, for_actor: %FunWithFlags.UI.SimpleActor{id: "workspace:9999"}
      {:ok, true} = FunWithFlags.enable :fig, for_group: "beta"
      {:ok, true} = FunWithFlags.enable :fig, for_percentage_of: {:actors, 0.1}
      {:ok, true} = FunWithFlags.enable :fig
      body = request!(:get, "/flags/fig/panel").resp_body

      confirms = Regex.scan(~r/data-confirm="([^"]*)"/, body, capture: :all_but_first) |> List.flatten() |> Enum.sort()

      assert confirms == Enum.sort([
               "Remove workspace:9999 from fig?",
               "Remove beta from fig?",
               "Remove the 10% of actors rollout from fig?",
               "Remove the boolean gate from fig? Without it the default is Off. This is mainly for debugging.",
               "Delete the flag fig and all its gates? This cannot be undone."
             ])
    end

    test "the percentage form says it has no effect while the default is On, and only then" do
      {:ok, true} = FunWithFlags.enable :fig
      hint = ~s{<p class="fwf-hint fwf-pct-hint" id="fwf-pct-no-effect">Has no effect while the default is On.</p>}
      assert request!(:get, "/flags/fig/panel").resp_body =~ hint

      {:ok, false} = FunWithFlags.disable :fig
      refute request!(:get, "/flags/fig/panel").resp_body =~ "fwf-pct-no-effect"

      {:ok, true} = FunWithFlags.enable :fig_time, for_percentage_of: {:time, 0.5}
      refute request!(:get, "/flags/fig_time/panel").resp_body =~ "fwf-pct-no-effect"
    end
  end


  describe "DELETE /flags/:name" do
    test "it deletes the flag and redirects to the list" do
      {:ok, true} = FunWithFlags.enable :quince
      conn = request!(:delete, "/flags/quince")
      assert 302 = conn.status
      assert ["/flags"] = get_resp_header(conn, "location")
      refute Enum.member?(elem(FunWithFlags.all_flag_names, 1), :quince)
    end

    test "with a namespace, the redirect is prefixed" do
      {:ok, true} = FunWithFlags.enable :quince
      conn = request!(:delete, "/flags/quince", nil, Router.init(namespace: "ns"))
      assert ["/ns/flags"] = get_resp_header(conn, "location")
    end

    # Round 14 (review R4-1): the "Deleted …" banner rides in the session
    # from a real DELETE to the next list render, once. No link can show it.
    test "a real delete shows the banner on the list once, not on reload" do
      {:ok, true} = FunWithFlags.enable :quince
      deleted = session_delete("/flags/quince")
      assert ["/flags"] = get_resp_header(deleted, "location")

      list = session_request(:get, "/flags", session_of(deleted))
      assert list.resp_body =~ ~s{<div class="fwf-banner fwf-banner--info fwf-flash" id="fwf-flash" role="status">}
      assert list.resp_body =~ ~s{<p>Deleted <strong class="fwf-mono">quince</strong>.</p>}

      reload = session_request(:get, "/flags", session_of(list))
      refute reload.resp_body =~ "fwf-flash"
    end

    test "the banner waits for the list: a flag page in between neither shows nor drops it" do
      {:ok, true} = FunWithFlags.enable :quince
      {:ok, true} = FunWithFlags.enable :quince_other
      deleted = session_delete("/flags/quince")
      other = session_request(:get, "/flags/quince_other", session_of(deleted))
      refute other.resp_body =~ "fwf-flash"
      assert session_request(:get, "/flags", session_of(other)).resp_body =~ "Deleted <strong"
    end

    test "a forged link shows no banner, with or without a session" do
      for path <- ["/flags?deleted=payments_kill_switch", "/flags?deleted=x&q=y"] do
        refute request!(:get, path).resp_body =~ "fwf-flash", path
        refute session_request(:get, path, %{}).resp_body =~ "fwf-flash", path
      end
    end

    test "without a session plug a delete still works and nothing is shown" do
      {:ok, true} = FunWithFlags.enable :quince
      conn = request!(:delete, "/flags/quince")
      assert ["/flags"] = get_resp_header(conn, "location")
      refute request!(:get, "/flags").resp_body =~ "fwf-flash"
    end

    test "the banner escapes the name and caps its length" do
      name = :"Ook? <b>Ook!</b>"
      {:ok, true} = FunWithFlags.enable name
      deleted = session_delete("/flags/" <> Templates.url_safe(name))
      body = session_request(:get, "/flags", session_of(deleted)).resp_body
      assert body =~ "Deleted <strong class=\"fwf-mono\">Ook? &lt;b&gt;Ook!&lt;/b&gt;</strong>."

      long = String.duplicate("a", 200)
      {:ok, true} = FunWithFlags.enable String.to_atom(long)
      deleted = session_delete("/flags/" <> long)
      body = session_request(:get, "/flags", session_of(deleted)).resp_body
      assert body =~ ~s{Deleted <strong class="fwf-mono">#{String.duplicate("a", 120)}…</strong>.}
      refute body =~ String.duplicate("a", 121) <> "<"
    end
  end


  describe "PATCH /flags/:name/boolean" do
    test "it toggles the boolean gate and redirects to the flag page" do
      {:ok, false} = FunWithFlags.disable :raspberry
      conn = request!(:patch, "/flags/raspberry/boolean", %{enabled: "true"})
      assert 302 = conn.status
      assert ["/flags/raspberry"] = get_resp_header(conn, "location")
      assert FunWithFlags.enabled?(:raspberry)

      conn = request!(:patch, "/flags/raspberry/boolean", %{enabled: "false"})
      assert ["/flags/raspberry"] = get_resp_header(conn, "location")
      refute FunWithFlags.enabled?(:raspberry)
    end
  end


  describe "actor gates" do
    test "PATCH toggles an actor gate and redirects to its row" do
      {:ok, false} = FunWithFlags.disable :strawberry
      conn = request!(:patch, "/flags/strawberry/actors/user:1", %{enabled: "true"})
      assert 302 = conn.status
      assert ["/flags/strawberry#actor_user:1"] = get_resp_header(conn, "location")
      assert FunWithFlags.enabled?(:strawberry, for: %FunWithFlags.UI.SimpleActor{id: "user:1"})
    end

    test "DELETE clears an actor gate and redirects to the actors card" do
      {:ok, true} = FunWithFlags.enable :strawberry, for_actor: %FunWithFlags.UI.SimpleActor{id: "user:1"}
      conn = request!(:delete, "/flags/strawberry/actors/user:1")
      assert 302 = conn.status
      assert ["/flags/strawberry#actor_gates"] = get_resp_header(conn, "location")
    end

    test "POST adds an actor gate and redirects to its row" do
      {:ok, false} = FunWithFlags.disable :strawberry
      conn = request!(:post, "/flags/strawberry/actors", %{actor_id: "user:2", enabled: "true"})
      assert 302 = conn.status
      assert ["/flags/strawberry#actor_user:2"] = get_resp_header(conn, "location")
    end

    test "POST with an invalid actor ID re-renders the page with the error, the list and the audit section" do
      {:ok, false} = FunWithFlags.disable :strawberry
      {:ok, true} = FunWithFlags.enable :tangerine
      conn = request!(:post, "/flags/strawberry/actors", %{actor_id: " ", enabled: "true"})
      assert 400 = conn.status
      assert String.contains?(conn.resp_body, "The actor ID can&#39;t be blank.") or
               String.contains?(conn.resp_body, "The actor ID can't be blank.")
      assert String.contains?(conn.resp_body, ~s{<a class="fwf-row-link" href="/flags/tangerine">})
      assert String.contains?(conn.resp_body, ~s{<div class="fwf-panel fwf-fade-in" data-name="strawberry"})
      assert String.contains?(conn.resp_body, "Audit logging is not enabled.")
      refute String.contains?(conn.resp_body, "No audit log entries found.")
    end
  end


  describe "actor and group IDs that are URL dot-segments" do
    test "adding an actor '..' or '.' is rejected, and nothing is written" do
      {:ok, false} = FunWithFlags.disable :vanilla

      for id <- ["..", "."] do
        conn = request!(:post, "/flags/vanilla/actors", %{actor_id: id, enabled: "true"})
        assert 400 = conn.status
        assert String.contains?(conn.resp_body, "The actor ID can&#39;t be &#39;.&#39; or &#39;..&#39;.") or
                 String.contains?(conn.resp_body, "The actor ID can't be '.' or '..'.")
      end

      assert [%Gate{type: :boolean}] = FunWithFlags.get_flag(:vanilla).gates
    end

    test "adding a group '..' or '.' is rejected, and nothing is written" do
      {:ok, false} = FunWithFlags.disable :vanilla

      for id <- ["..", "."] do
        conn = request!(:post, "/flags/vanilla/groups", %{group_name: id, enabled: "true"})
        assert 400 = conn.status
        assert String.contains?(conn.resp_body, "The group name can&#39;t be &#39;.&#39; or &#39;..&#39;.")
      end

      assert [%Gate{type: :boolean}] = FunWithFlags.get_flag(:vanilla).gates
    end

    test "an existing '..' or '.' gate never gets a form action that resolves to the flag" do
      {:ok, false} = FunWithFlags.disable :walnut
      {:ok, true} = FunWithFlags.enable :walnut, for_actor: %FunWithFlags.UI.SimpleActor{id: ".."}
      {:ok, true} = FunWithFlags.enable :walnut, for_actor: %FunWithFlags.UI.SimpleActor{id: "."}
      {:ok, true} = FunWithFlags.enable :walnut, for_group: ".."
      {:ok, true} = FunWithFlags.enable :walnut, for_actor: %FunWithFlags.UI.SimpleActor{id: "user:1"}

      for body <- [request!(:get, "/flags/walnut").resp_body, request!(:get, "/flags/walnut/panel").resp_body] do
        # form actions and button formactions alike
        actions = Regex.scan(~r/\s(?:form)?action="([^"]*)"/, body, capture: :all_but_first) |> List.flatten()
        refute Enum.any?(actions, &Regex.match?(~r{/\.\.?$}, &1)), inspect(actions)
        refute Enum.any?(actions, &String.contains?(&1, "/./")), inspect(actions)
        assert Enum.count(actions, &(&1 == "/flags/walnut/actors")) >= 4
        assert Enum.count(actions, &(&1 == "/flags/walnut/groups")) >= 2
        assert String.contains?(body, ~s{<input type="hidden" name="actor_id" value="..">})
        assert String.contains?(body, ~s{<input type="hidden" name="actor_id" value=".">})
        assert String.contains?(body, ~s{<input type="hidden" name="group_name" value="..">})
        # ordinary IDs keep their per-ID URL
        assert String.contains?(body, ~s{formaction="/flags/walnut/actors/user:1"})
      end
    end

    test "clearing an existing '..' actor clears only that gate, not the flag" do
      {:ok, false} = FunWithFlags.disable :walnut
      {:ok, true} = FunWithFlags.enable :walnut, for_actor: %FunWithFlags.UI.SimpleActor{id: ".."}
      {:ok, true} = FunWithFlags.enable :walnut, for_actor: %FunWithFlags.UI.SimpleActor{id: "user:1"}

      conn = request!(:delete, "/flags/walnut/actors", %{actor_id: ".."})
      assert 302 = conn.status
      assert ["/flags/walnut#actor_gates"] = get_resp_header(conn, "location")

      gates = FunWithFlags.get_flag(:walnut).gates
      assert Enum.member?(elem(FunWithFlags.all_flag_names, 1), :walnut)
      assert [%Gate{type: :boolean}, %Gate{type: :actor, for: "user:1"}] = gates
    end

    test "toggling an existing '..' actor and '.' group goes through the body-target routes" do
      {:ok, false} = FunWithFlags.disable :walnut
      {:ok, true} = FunWithFlags.enable :walnut, for_actor: %FunWithFlags.UI.SimpleActor{id: ".."}
      {:ok, true} = FunWithFlags.enable :walnut, for_group: "."

      conn = request!(:patch, "/flags/walnut/actors", %{actor_id: "..", enabled: "false"})
      assert ["/flags/walnut#actor_.."] = get_resp_header(conn, "location")
      refute FunWithFlags.enabled?(:walnut, for: %FunWithFlags.UI.SimpleActor{id: ".."})

      conn = request!(:patch, "/flags/walnut/groups", %{group_name: ".", enabled: "false"})
      assert ["/flags/walnut#group_."] = get_resp_header(conn, "location")
      assert %Gate{type: :group, for: ".", enabled: false} = Enum.find(FunWithFlags.get_flag(:walnut).gates, &(&1.type == :group))

      conn = request!(:delete, "/flags/walnut/groups", %{group_name: "."})
      assert ["/flags/walnut#group_gates"] = get_resp_header(conn, "location")
      assert [%Gate{type: :boolean}, %Gate{type: :actor}] = FunWithFlags.get_flag(:walnut).gates
    end

    test "a body-target request without the ID changes nothing (e.g. an old /actors/. form resolved to /actors)" do
      {:ok, false} = FunWithFlags.disable :walnut
      {:ok, true} = FunWithFlags.enable :walnut, for_actor: %FunWithFlags.UI.SimpleActor{id: "user:1"}
      before = FunWithFlags.get_flag(:walnut)

      for {method, path, params} <- [
            {:delete, "/flags/walnut/actors", %{}},
            {:delete, "/flags/walnut/actors", %{actor_id: ""}},
            {:patch, "/flags/walnut/actors", %{enabled: "true"}},
            {:delete, "/flags/walnut/groups", %{}},
            {:patch, "/flags/walnut/groups", %{group_name: "", enabled: "true"}}
          ] do
        conn = request!(method, path, params)
        assert 400 = conn.status, "#{method} #{path} #{inspect(params)}"
        assert conn.resp_body =~ "can&#39;t be blank" or conn.resp_body =~ "can't be blank"
      end

      assert FunWithFlags.get_flag(:walnut) == before
    end
  end


  describe "page bootstrapping for the client" do
    test "confirm.js is the first script on every page, in the head" do
      {:ok, true} = FunWithFlags.enable :pecan

      for path <- ["/flags", "/flags/pecan", "/flags/missing_pecan", "/new", "/settings", "/audit_logs"] do
        body = request!(:get, path).resp_body
        [head | _] = String.split(body, "</head>", parts: 2)
        assert String.contains?(head, ~s{<script type="text/javascript" src="/assets/confirm.js"></script>}), path
        [_, after_confirm] = String.split(body, ~s{src="/assets/confirm.js"}, parts: 2)
        [before_confirm | _] = String.split(body, ~s{src="/assets/confirm.js"}, parts: 2)
        refute before_confirm =~ ~r/<script[^>]+src=/, path
        assert path not in ["/flags", "/flags/pecan"] or String.contains?(after_confirm, "flags_core.js")
      end
    end

    test "the page names the selected flag in data-selected (it can't be read from a POST URL)" do
      {:ok, false} = FunWithFlags.disable :pecan

      refute request!(:get, "/flags").resp_body =~ "data-selected"
      assert request!(:get, "/flags/pecan").resp_body =~ ~s{data-selected="pecan"}
      assert request!(:get, "/flags/missing_pecan").resp_body =~ ~s{data-selected="missing_pecan"}

      # a validation error renders the page at the POST URL
      conn = request!(:post, "/flags/pecan/actors", %{actor_id: " ", enabled: "true"})
      assert 400 = conn.status
      assert conn.resp_body =~ ~s{data-selected="pecan"}
      conn = request!(:post, "/flags/pecan/percentage", %{percent_type: "time", percent_value: "2"})
      assert 400 = conn.status
      assert conn.resp_body =~ ~s{data-selected="pecan"}
    end

    test "data-selected is escaped" do
      name = :"Ook? <b>Ook!</b>"
      {:ok, true} = FunWithFlags.enable name
      body = request!(:get, "/flags/Ook%3F%20%3Cb%3EOok!%3C%2Fb%3E").resp_body
      assert body =~ ~s{data-selected="Ook? &lt;b&gt;Ook!&lt;/b&gt;"}
    end
  end


  describe "group gates" do
    test "PATCH toggles a group gate and redirects to its row" do
      {:ok, false} = FunWithFlags.disable :ugli
      conn = request!(:patch, "/flags/ugli/groups/beta", %{enabled: "true"})
      assert 302 = conn.status
      assert ["/flags/ugli#group_beta"] = get_resp_header(conn, "location")
    end

    test "DELETE clears a group gate and redirects to the groups card" do
      {:ok, true} = FunWithFlags.enable :ugli, for_group: "beta"
      conn = request!(:delete, "/flags/ugli/groups/beta")
      assert 302 = conn.status
      assert ["/flags/ugli#group_gates"] = get_resp_header(conn, "location")
    end

    test "POST adds a group gate and redirects to its row" do
      {:ok, false} = FunWithFlags.disable :ugli
      conn = request!(:post, "/flags/ugli/groups", %{group_name: "alpha", enabled: "true"})
      assert 302 = conn.status
      assert ["/flags/ugli#group_alpha"] = get_resp_header(conn, "location")
    end

    test "POST with an invalid group name re-renders the page with the error" do
      {:ok, false} = FunWithFlags.disable :ugli
      conn = request!(:post, "/flags/ugli/groups", %{group_name: "a?b", enabled: "true"})
      assert 400 = conn.status
      assert String.contains?(conn.resp_body, "The group name includes invalid characters")
      assert String.contains?(conn.resp_body, ~s{<ul class="fwf-list" id="fwf-list">})
      assert String.contains?(conn.resp_body, "Audit logging is not enabled.")
    end
  end


  describe "DELETE /flags/:name/boolean" do
    test "when the flag exists, it deletes its boolean gate and redirects to the flag page" do
      {:ok, true} = FunWithFlags.enable :frozen_yogurt
      {:ok, true} = FunWithFlags.enable :frozen_yogurt, for_group: "some_group"

      assert %Flag{name: :frozen_yogurt, gates: [%Gate{type: :boolean}, %Gate{type: :group}]} = FunWithFlags.get_flag(:frozen_yogurt)

      conn = request!(:delete, "/flags/frozen_yogurt/boolean")
      assert 302 = conn.status
      assert ["/flags/frozen_yogurt"] = get_resp_header(conn, "location")

      assert %Flag{name: :frozen_yogurt, gates: [%Gate{type: :group}]} = FunWithFlags.get_flag(:frozen_yogurt)
    end
  end


  describe "DELETE /flags/:name/percentage" do
    test "when the flag exists, it deletes its current percentage gate and redirects to the flag page" do
      {:ok, true} = FunWithFlags.enable :pizza, for_percentage_of: {:time, 0.5}
      {:ok, true} = FunWithFlags.enable :pizza, for_group: "some_group"

      assert %Flag{name: :pizza, gates: [%Gate{type: :percentage_of_time, for: 0.5}, %Gate{type: :group}]} = FunWithFlags.get_flag(:pizza)

      conn = request!(:delete, "/flags/pizza/percentage")
      assert 302 = conn.status
      assert ["/flags/pizza"] = get_resp_header(conn, "location")

      assert %Flag{name: :pizza, gates: [%Gate{type: :group}]} = FunWithFlags.get_flag(:pizza)
    end
  end



  describe "POST /flags/:name/percentage" do
    test "with no previous percentage gate it creates a new one, then redirects to the details page" do
      {:ok, false} = FunWithFlags.disable :chocolate

      assert %Flag{name: :chocolate, gates: [%Gate{type: :boolean}]} = FunWithFlags.get_flag(:chocolate)

      conn = request!(:post, "/flags/chocolate/percentage", %{
        percent_type: "time",
        percent_value: "0.5"
      })
      assert 302 = conn.status
      assert ["/flags/chocolate#percentage_gate"] = get_resp_header(conn, "location")

      assert %Flag{name: :chocolate, gates: [
        %Gate{type: :boolean},
        %Gate{type: :percentage_of_time, for: 0.5},
      ]} = FunWithFlags.get_flag(:chocolate)
    end

    test "with a previous percentage gate it replaces it, then redirects to the details page" do
      {:ok, false} = FunWithFlags.disable :chocolate
      {:ok, true} = FunWithFlags.enable :chocolate, for_percentage_of: {:time, 0.99}

      assert %Flag{name: :chocolate, gates: [
        %Gate{type: :boolean},
        %Gate{type: :percentage_of_time, for: 0.99},
      ]} = FunWithFlags.get_flag(:chocolate)

      conn = request!(:post, "/flags/chocolate/percentage", %{
        percent_type: "time",
        percent_value: "0.5"
      })
      assert 302 = conn.status
      assert ["/flags/chocolate#percentage_gate"] = get_resp_header(conn, "location")

      assert %Flag{name: :chocolate, gates: [
        %Gate{type: :boolean},
        %Gate{type: :percentage_of_time, for: 0.5},
      ]} = FunWithFlags.get_flag(:chocolate)
    end


    test "with invalid params, it renders the details page with errors" do
      {:ok, false} = FunWithFlags.disable :chocolate

      conn = request!(:post, "/flags/chocolate/percentage", %{
        percent_type: "time",
        percent_value: " "
      })
      assert 400 = conn.status
      assert is_binary(conn.resp_body)
      assert ["text/html; charset=utf-8"] = get_resp_header(conn, "content-type")
      # error messages are HTML-escaped (round 9)
      assert String.contains?(conn.resp_body, "The percentage value can&#39;t be blank.")
      assert String.contains?(conn.resp_body, ~s{<ul class="fwf-list" id="fwf-list">})
      assert String.contains?(conn.resp_body, "Audit logging is not enabled.")
    end
  end


  # For GET and DELETE
  #
  # A request through a session (Plug.Test's test session), and the session
  # it leaves behind, to carry into the next request.
  defp session_request(method, path, session) do
    conn(method, path)
    |> init_test_session(session)
    |> Router.call(@opts)
  end

  defp session_of(conn), do: conn.private[:plug_session] || %{}

  # A DELETE the way the browser sends it: the flag page sets up the session
  # and its CSRF token, the form posts the token back.
  defp session_delete(path) do
    page = session_request(:get, path, %{})
    [_, token] = Regex.run(~r/name="_csrf_token" value="([^"]+)"/, page.resp_body)

    conn(:delete, path)
    |> init_test_session(session_of(page))
    |> put_req_header("x-csrf-token", token)
    |> Router.call(@opts)
  end

  defp request!(method, path) do
    conn(method, path)
    |> Router.call(@opts)
  end

  defp request!(method, path, nil, opts) do
    conn(method, path)
    |> Router.call(opts)
  end

  # The markup of one list row, by flag name.
  #
  defp row(body, name) do
    [_, rest] = String.split(body, ~s{data-name="#{name}"}, parts: 2)
    [row | _] = String.split(rest, "</li>", parts: 2)
    row
  end

  defp restore_env({app_name, app_env}) do
    if app_name, do: System.put_env("APP_NAME", app_name), else: System.delete_env("APP_NAME")
    if app_env, do: System.put_env("APP_ENV", app_env), else: System.delete_env("APP_ENV")
  end

  # For POST and PATCH
  #
  # Do a little dance to URL-encode the body rather than just
  # passing a Map, because that's what the HTML forms do.
  # Using a map here would require to add the :multipart
  # parser to the Router just for the tests.
  #
  defp request!(method, path, params) when is_map(params) do
    conn(method, path, Plug.Conn.Query.encode(params))
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> Router.call(@opts)
  end
end
