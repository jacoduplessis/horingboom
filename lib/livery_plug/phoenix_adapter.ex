defmodule LiveryPlug.PhoenixAdapter do
  @moduledoc """
  Phoenix endpoint adapter that serves the endpoint over livery.

      config :my_app, MyAppWeb.Endpoint,
        adapter: LiveryPlug.PhoenixAdapter,
        http: [ip: {127, 0, 0, 1}, port: 4000]

  Extra `:http` keys:

    * `:livery_routes` — livery router entries (`{method | :_, pattern, fun/1}`)
      matched before the endpoint, which serves everything else.
    * `:livery_config` — listener config, readable by those handlers through
      `livery_req:config/1`.

  HTTP only for now; `:https` and HTTP/2-3 are not wired up.
  """

  require Logger

  def child_specs(endpoint, config) do
    for {scheme, default_port} <- [http: 4000], opts = config[scheme] do
      port = opts |> Keyword.get(:port, default_port) |> to_port()
      ip = Keyword.get(opts, :ip, {127, 0, 0, 1})

      {plug, plug_opts} =
        if config[:code_reloader] do
          {Phoenix.Endpoint.SyncCodeReloadPlug, {endpoint, []}}
        else
          {endpoint, []}
        end

      plug_opts = plug.init(plug_opts)
      phoenix = fn req -> LiveryPlug.Handler.handle(req, plug, plug_opts, port) end

      routes =
        Keyword.get(opts, :livery_routes, []) ++ [{:_, "/", phoenix}, {:_, "/*path", phoenix}]

      service = %{
        http: %{port: port, ip: ip, config: Keyword.get(opts, :livery_config, %{})},
        router: :livery_router.compile(routes)
      }

      %{
        id: {__MODULE__, endpoint, scheme},
        start: {__MODULE__, :start_link, [endpoint, scheme, ip, port, service]},
        type: :worker
      }
    end
  end

  @doc false
  def start_link(endpoint, scheme, ip, port, service) do
    case :livery.start_service(service) do
      {:ok, pid} ->
        Logger.info(
          "Running #{inspect(endpoint)} with livery #{Application.spec(:livery, :vsn)} at " <>
            "#{:inet.ntoa(ip)}:#{port} (#{scheme})"
        )

        {:ok, pid}

      {:error, reason} = error ->
        Logger.error(
          "#{inspect(endpoint)} failed to start livery on port #{port}: #{inspect(reason)}"
        )

        error
    end
  end

  defp to_port(port) when is_integer(port), do: port
  defp to_port(port) when is_binary(port), do: String.to_integer(port)
  defp to_port({:system, env}), do: env |> System.get_env() |> String.to_integer()
end
