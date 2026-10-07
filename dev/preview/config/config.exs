import Config

config :preview, ecto_repos: [Preview.Repo]

# Your own scratch database. Never point this at a database you care about:
# `mix preview.seed` truncates the flags and audit log tables.
config :preview, Preview.Repo,
  url: System.get_env("FWF_DEV_DATABASE_URL", "ecto://postgres:postgres@localhost:5432/fwf_ui_dev"),
  pool_size: 5,
  log: false

config :fun_with_flags, :persistence,
  adapter: FunWithFlags.Store.Persistent.Ecto,
  repo: Preview.Repo

config :fun_with_flags, :audit_logs, repo: Preview.Repo

# Single node, no Redis: read straight from Postgres.
config :fun_with_flags, :cache, enabled: false
config :fun_with_flags, :cache_bust_notifications, enabled: false

config :logger, level: :info
