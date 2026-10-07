defmodule Mix.Tasks.Preview.Server do
  @shortdoc "Serves the dashboard against the preview database"
  @moduledoc """
  Serves the dashboard on http://localhost:$PORT (default 9090).

      PORT=9091 FWF_DEV_VIEWER_EMAIL=ana@example.com mix preview.server

  Env: PORT, FWF_DEV_VIEWER_EMAIL (fakes the viewer header),
  APP_NAME / APP_ENV (the header badge), FWF_DEV_DATABASE_URL.
  """
  use Mix.Task

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")
    port = String.to_integer(System.get_env("PORT", "9090"))
    {:ok, _} = Plug.Cowboy.http(Preview.Router, [], port: port)
    Mix.shell().info("FunWithFlags.UI preview on http://localhost:#{port}#{Preview.Router.mount()}/flags")

    unless IEx.started?(), do: Process.sleep(:infinity)
  end
end
