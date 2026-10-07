defmodule Preview.Router do
  @moduledoc """
  A stand-in for a host app: a cookie session and body parsing upstream (so
  CSRF protection works as in the real hosts), an optional fake viewer
  header, and the dashboard mounted under a namespace, like the services
  mount it.
  """
  use Plug.Router

  @mount "/internal/feature-flags"

  plug :put_secret_key_base

  plug Plug.Session,
    store: :cookie,
    key: "_fwf_preview",
    signing_salt: "fwf-preview-salt"

  # Phoenix endpoints parse the body before the router. The dashboard's CSRF
  # check runs before its own Plug.Parsers, so it relies on this.
  plug Plug.Parsers, parsers: [:urlencoded, :multipart], length: 10_000_000
  plug Plug.MethodOverride

  plug :fake_viewer
  plug :csp
  plug :match
  plug :dispatch

  get "/" do
    conn
    |> put_resp_header("location", @mount <> "/flags")
    |> send_resp(302, "")
  end

  forward @mount, to: FunWithFlags.UI.Router, init_opts: [namespace: String.trim_leading(@mount, "/")]

  match _ do
    send_resp(conn, 404, "not found")
  end

  def mount, do: @mount

  defp put_secret_key_base(conn, _opts) do
    put_in(conn.secret_key_base, String.duplicate("fwf-preview-not-a-secret-", 4))
  end

  # Sends the Content-Security-Policy one of the real hosts sends
  # (iv-pro-copilot-v45, CopilotWeb.Router @csp_header) by default, so the
  # preview renders under the same rules (icons sprite, font, scripts).
  # FWF_DEV_CSP=strict: no inline scripts or styles at all; =off: no CSP.
  @copilot_csp "default-src 'self' blob: data:; " <>
                 "script-src 'self' 'unsafe-inline' 'unsafe-eval' blob: https://cdn.jsdelivr.net; " <>
                 "style-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net https://fonts.googleapis.com; " <>
                 "font-src 'self' data: https://fonts.gstatic.com; " <>
                 "img-src 'self' data: blob: https: http:; " <>
                 "media-src 'self' blob: data: https: http: *; " <>
                 "worker-src 'self' blob: data:; " <>
                 "connect-src 'self' wss: ws: https: http: blob: data:; " <>
                 "frame-ancestors 'none'; " <>
                 "base-uri 'self'; " <>
                 "form-action 'self'; " <>
                 "frame-src 'self' blob: data:"

  defp csp(conn, _opts) do
    case System.get_env("FWF_DEV_CSP", "copilot") do
      "off" -> conn
      "strict" -> put_resp_header(conn, "content-security-policy", "default-src 'self'; script-src 'self'; style-src 'self'; form-action 'self'; base-uri 'self'; frame-ancestors 'none'")
      _ -> put_resp_header(conn, "content-security-policy", @copilot_csp)
    end
  end

  # The real hosts put the signed-in user's email in a header (the one the
  # audit log reads). FWF_DEV_VIEWER_EMAIL fakes it.
  #
  defp fake_viewer(conn, _opts) do
    case System.get_env("FWF_DEV_VIEWER_EMAIL") do
      email when is_binary(email) and email != "" ->
        put_req_header(conn, FunWithFlags.Config.audit_log_user_id_header(), email)

      _ ->
        conn
    end
  end
end
