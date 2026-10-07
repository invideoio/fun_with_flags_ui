defmodule Preview.MixProject do
  use Mix.Project

  # A dev-only harness: runs the dashboard from this checkout against a
  # scratch Postgres database with Ecto persistence and audit logs, the
  # setup the real host apps use. It is its own Mix project so that none
  # of this reaches the package or the library's deps.
  #
  # See the "Preview harness" section of the README.

  def project do
    [
      app: :preview,
      version: "0.1.0",
      elixir: "~> 1.16",
      start_permanent: false,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Preview.Application, []}
    ]
  end

  defp deps do
    [
      {:fun_with_flags_ui, path: "../.."},
      {:ecto_sql, "~> 3.10"},
      {:postgrex, ">= 0.17.0"},
      {:plug_cowboy, "~> 2.6"},
      # the audit log stores its data as a JSON map
      {:jason, "~> 1.4"}
    ]
  end

  @migrations "deps/fun_with_flags/priv/ecto_repo/migrations"

  defp aliases do
    [
      setup: ["deps.get", "ecto.create", "ecto.migrate --migrations-path #{@migrations}", "preview.seed"],
      "preview.reset": ["ecto.drop", "ecto.create", "ecto.migrate --migrations-path #{@migrations}", "preview.seed"]
    ]
  end
end
