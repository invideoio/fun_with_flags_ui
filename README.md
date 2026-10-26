# FunWithFlags.UI

[![Mix Tests](https://github.com/tompave/fun_with_flags_ui/workflows/Mix%20Tests/badge.svg)](https://github.com/tompave/fun_with_flags_ui/actions?query=branch%3Amaster)
[![Code Quality](https://github.com/tompave/fun_with_flags_ui/actions/workflows/quality.yml/badge.svg?branch=master)](https://github.com/tompave/fun_with_flags_ui/actions/workflows/quality.yml?query=branch%3Amaster)  
[![Hex.pm](https://img.shields.io/hexpm/v/fun_with_flags_ui.svg)](https://hex.pm/packages/fun_with_flags_ui)

A Web dashboard for the [FunWithFlags](https://github.com/tompave/fun_with_flags) Elixir package.

![Searching flags by actor ID, filtering to partial flags, opening a flag and the shortcut sheet](demo/demo.gif)

Screenshots: [dark](demo/flags-dark.png) · [light](demo/flags-light.png) · [phone](demo/flags-phone.png)


## How to run

`FunWithFlags.UI` is just a plug and it can be run in a number of ways.
It's primarily meant to be embedded in a host Plug application, either Phoenix or another Plug app.

### Mounted in Phoenix

The router plug can be mounted inside the Phoenix router with [`Phoenix.Router.forward/4`](https://hexdocs.pm/phoenix/Phoenix.Router.html#forward/4).

```elixir
defmodule MyPhoenixAppWeb.Router do
  use MyPhoenixAppWeb, :router

  pipeline :mounted_apps do
    plug :accepts, ["html"]
    plug :put_secure_browser_headers
  end

  scope path: "/feature-flags" do
    pipe_through :mounted_apps
    forward "/", FunWithFlags.UI.Router, namespace: "feature-flags"
  end
end
```

Note: There is no need to add `:protect_from_forgery` to the `:mounted_apps` pipeline because this package already implements CSRF protection. In order to enable it, your host application must use the `Plug.Session` plug, which is usually configured in the endpoint module in Phoenix.

### Mounted in another Plug application

Since it's just a plug, it can also be mounted into any other Plug application using [`Plug.Router.forward/2`](https://hexdocs.pm/plug/Plug.Router.html#forward/2).

```elixir
defmodule Another.App do
  use Plug.Router
  forward "/feature-flags", to: FunWithFlags.UI.Router, init_opts: [namespace: "feature-flags"]
end
```

Note: If your plug router uses `Plug.CSRFProtection`, `FunWithFlags.UI.Router` should be added before your CSRF protection plug because it already implements its own CSRF protection. If you declare `FunWithFlags.UI.Router` after, your CSRF plug will likely block GET requests for the JS assets of the dashboard.

### Standalone

Again, because it's just a plug, it can be run [standalone](https://hexdocs.pm/plug/readme.html#supervised-handlers).

If you clone the repository, the library comes with two convenience functions to accomplish this:

```elixir
# Simple, let Cowboy sort out the supervision tree:
{:ok, pid} = FunWithFlags.UI.run_standalone()

# Uses some explicit supervision configuration:
{:ok, pid} = FunWithFlags.UI.run_supervised()
```

These functions come in handy for local development, and are _not_ necessary when embedding the Plug into a host application.

Please note that even though the `FunWithFlags.UI` module implements the `Application` behavior and comes with a proper `start/2` callback, this is not enabled by design and, in fact, the Mixfile doesn't declare an entry module.

If you really need to run it standalone in a reliable manner, you are encouraged to write your own supervision setup.

### Security

For obvious reasons, you don't want to make this web control panel publicly accessible.

The library itself doesn't provide any auth functionality because, as a Plug, it is easier to wrap it into the authentication and authorization logic of the host application.

The easiest thing to do is to protect it with HTTP Basic Auth, provided by Plug itself.

For example, in Phoenix:

```diff
defmodule MyPhoenixAppWeb.Router do
  use MyPhoenixAppWeb, :router
+ import Plug.BasicAuth

  pipeline :mounted_apps do
    plug :accepts, ["html"]
    plug :put_secure_browser_headers
+   plug :basic_auth, username: "foo", password: "bar"
  end

  scope path: "/feature-flags" do
    pipe_through :mounted_apps
    forward "/", FunWithFlags.UI.Router, namespace: "feature-flags"
  end
end
```

## Copying a flag's state

Click **Copy State** in a flag's header to copy a standalone Markdown summary for an agent. It includes the default, every actor and group gate (including collapsed or filtered rows), the percentage rollout, and the evaluation rules. The copied state reflects the loaded flag panel.

## Adding actors and groups

The flag page's add-actor and add-group forms each start with a picker, so you type only the part that varies.

**Actors.** Pick a prefix (`email:`, `workspace:`, …) and type the rest; "Full ID" takes the whole ID. The prefixes are the ones actor gates already use across all flags, most used first, after any you configure:

```elixir
config :fun_with_flags_ui, actor_prefixes: ["workspace", "email", "user"]
```

A pasted whole ID (`email:a@b.c`) moves its prefix into the picker; the last picked prefix is remembered per browser.

**Groups.** The picker lists the group names your `FunWithFlags.Group` implementations match, read from their clauses at compile time. Add one line to each implementation:

```elixir
defimpl FunWithFlags.Group, for: MyApp.Workspace do
  use FunWithFlags.UI.GroupCatalog,
    hints: %{
      "country_group:" => {MyApp.CountryGroups, :names, []},
      "created_at:gt:" => "unix timestamp (seconds)"
    }

  def in?(%{bucket: b}, "a0"), do: b == :a0
  def in?(%{bucket: b}, group) when group in ~w(a b c d), do: ...
  def in?(ws, "country_group:" <> group), do: ...
  def in?(_, _), do: false
end
```

String literals (also joined with `<>`) and `when group in [...]` guards are exact groups: pick and add. Literals followed by a variable (`"country_group:" <> group`) are patterns: pick, then type the value. Private 2-arity helpers the implementation delegates to are read too. A new clause shows up after the next compile. `hints` give a pattern's value a placeholder (a string) or suggested values (a list, or an `{m, f, a}` called when the page renders). "Custom…" takes any name.

Group names on gates that no clause matches are listed separately and marked "not in code" on the flag page: they match nobody, usually a typo. Without any implementation using `GroupCatalog`, the picker lists only the group names gates already use, and nothing is marked.

## Audit Logging

When [audit logging](https://github.com/tompave/fun_with_flags#audit-logging) is configured in `fun_with_flags`, the web dashboard automatically records all flag changes with the user who made them.

The user identifier is extracted from an HTTP request header (configurable, defaults to `x-user-id`). Your host application or reverse proxy should set this header based on the authenticated user.

```elixir
config :fun_with_flags, :audit_logs,
  repo: MyApp.Repo,
  user_id_header: "X-User-Id"
```

No additional configuration is needed in the UI — it reads the audit log settings from the core `fun_with_flags` configuration.

The flags page also uses that header to show "signed in as …" and the "Mine" filter, which lists the flags with an actor gate whose ID is the viewer's email or ends in `:` + email (e.g. `email:ana@example.com`), case-insensitively. That only works if the header carries the user's **email**: if your host or proxy puts an opaque user ID there, "Mine" will always be empty. It is a display filter, not authorization.

## Caveats

While the base `fun_with_flags` library is quite relaxed in terms of valid flag names, group names and actor identifers, this web dashboard extension applies some more restrictive rules.
The reason is that all `fun_with_flags` cares about is that some flag and group names can be represented as an Elixir Atom, while actor IDs are just strings. Since you can use that API in your code, the library will only check that the parameters have the right type.

Things change on the web, however. Think about the binary `"Ook? Ook!"`. In code, it can be accepted as a valid flag name:

```elixir
{:ok, true} = FunWithFlags.enable(:"Ook? Ook!", for_group: :"weird, huh?")
```

On the web, however, the question mark makes working with URLs a bit tricky: unencoded, in `http://localhost:8080/flags/Ook?%20Ook!` the flag name would be `Ook` and the rest a query string. The dashboard percent-encodes names and IDs as path segments (`/flags/Ook%3F%20Ook!`), so flags like this created in code can still be viewed and edited.

Still, this library enforces some stricter rules when creating flags and groups from the dashboard. Blank values are not allowed, `?` neither, and flag names must match `/^w+$/`.


## Development

The tests need Redis on `localhost:6379`:

```
mix test
mix credo
node --test 'test/js/*.test.js'   # the flags page's search/filter/sort logic (priv/static/flags_core.js)
```

### Preview harness

`mix test` and the standalone server use Redis persistence, where flags have no creation date and there is no audit log. `dev/preview` is a separate, dev-only Mix project that serves the dashboard from this checkout against a scratch Postgres database with Ecto persistence and audit logs, mounted under `/internal/feature-flags` like a host app, with a deterministic seed of ~300 made-up flags (actors, groups, percentages, a few flags with 200+ actors, creation dates over two years, audit entries by `@example.com` users). It is not part of the package.

```
cd dev/preview && FWF_DEV_DATABASE_URL=ecto://postgres:postgres@localhost:5432/fwf_ui_dev mix setup && FWF_DEV_DATABASE_URL=ecto://postgres:postgres@localhost:5432/fwf_ui_dev PORT=9090 FWF_DEV_VIEWER_EMAIL=ana@example.com mix preview.server
```

Then open http://localhost:9090/ (press `?` for the keyboard shortcuts). `mix setup` creates and migrates the database (with the migrations shipped in `fun_with_flags`) and seeds it; `mix preview.seed` re-seeds (it truncates the flags and audit log tables, so point `FWF_DEV_DATABASE_URL` at a database of its own). Other env vars: `FWF_DEV_VIEWER_EMAIL` fakes the viewer header (the audit log's user ID header, which also drives the "Mine" filter and "signed in as"), and `APP_NAME` / `APP_ENV` show the header badge.


## Credits

- Icons: [Hugeicons](https://hugeicons.com) free icons (`@hugeicons/core-free-icons` 4.3.5, MIT), vendored as one SVG sprite in `priv/static/icons/hugeicons.svg` (licence in `priv/static/icons/LICENSE-hugeicons.md`; rebuilt with `dev/icons/build_sprite.js`).
- Font: [Inter](https://rsms.me/inter/) (SIL Open Font License 1.1), `priv/static/fonts/InterVariable.woff2` (licence in `priv/static/fonts/LICENSE-Inter-OFL.txt`).

The dashboard loads nothing from other origins, so it works under a `default-src 'self'` Content-Security-Policy. The preview harness sends such a policy by default (`FWF_DEV_CSP=off|strict` to change it).

## Installation

The package can be installed by adding `fun_with_flags_ui` to your list of dependencies in `mix.exs`.  
It requires [`fun_with_flags`](https://hex.pm/packages/fun_with_flags), see its [installation documentation](https://github.com/tompave/fun_with_flags#installation) for more details.

```elixir
def deps do
  [{:fun_with_flags_ui, "~> 1.1"}]
end
```
