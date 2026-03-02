defmodule Horingboom.HornbeamServer do
  use GenServer
  require Logger

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    django_path = Path.expand("../../python/django_app", __DIR__)
    venv_path = Path.join(django_path, ".venv")

    Logger.info("Starting hornbeam with Django app at #{django_path}")

    :hornbeam.start("demo.wsgi:application", %{
      bind: "127.0.0.1:8001",
      workers: 2,
      worker_class: :wsgi,
      venv: venv_path,
      pythonpath: [django_path]
    })

    :hornbeam.register_function("system_info", fn _args ->
      %{
        otp_release: :erlang.system_info(:otp_release) |> to_string(),
        elixir_version: System.version(),
        node: Node.self() |> to_string(),
        schedulers: :erlang.system_info(:schedulers)
      }
    end)

    :hornbeam.register_function("greeting", fn [name] ->
      "Hello #{name}, from Elixir #{System.version()} on the BEAM!"
    end)

    Logger.info("Hornbeam started — Django available at http://127.0.0.1:8001/django/")

    {:ok, %{}}
  end
end
