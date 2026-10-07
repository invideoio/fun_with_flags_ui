defmodule Preview.Application do
  @moduledoc false
  use Application

  # Only the repo: the HTTP listener is started by `mix preview.server`,
  # so `mix preview.seed` can run while a server is up.
  #
  def start(_type, _args) do
    Supervisor.start_link([Preview.Repo], strategy: :one_for_one, name: Preview.Supervisor)
  end
end
