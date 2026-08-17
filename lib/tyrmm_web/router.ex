defmodule TyrmmWeb.Router do
  use TyrmmWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {TyrmmWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :ensure_player_id
  end

  scope "/", TyrmmWeb do
    pipe_through :browser

    live "/", LobbyLive
    live "/join/:code", LobbyLive
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:tyrmm, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: TyrmmWeb.Telemetry
    end
  end

  defp ensure_player_id(conn, _opts) do
    if get_session(conn, :player_id) do
      conn
    else
      player_id = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
      put_session(conn, :player_id, player_id)
    end
  end
end
