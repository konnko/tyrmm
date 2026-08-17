defmodule Tyrmm.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      TyrmmWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:tyrmm, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Tyrmm.PubSub},
      TyrmmWeb.Presence,
      Tyrmm.Lobbies,
      # Start to serve requests, typically the last entry
      TyrmmWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Tyrmm.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    TyrmmWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
