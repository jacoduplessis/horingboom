defmodule Horingboom.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        HoringboomWeb.Telemetry,
        Horingboom.Repo,
        {DNSCluster, query: Application.get_env(:horingboom, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Horingboom.PubSub}
      ] ++
        hornbeam_children() ++
        [
          # Start to serve requests, typically the last entry
          HoringboomWeb.Endpoint
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Horingboom.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  defp hornbeam_children do
    if Application.get_env(:horingboom, :start_hornbeam, true) do
      [Horingboom.HornbeamServer]
    else
      []
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    HoringboomWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
