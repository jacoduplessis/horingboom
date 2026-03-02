defmodule Horingboom.IntegrationCase do
  @moduledoc """
  Test case for integration tests that need hornbeam/Django running.

  These tests start HornbeamServer (which boots Django on port 8001)
  and use Req to make real HTTP calls. They are excluded by default
  and run with `mix test --include integration`.

  Django uses its own psycopg connection (not the Ecto sandbox), so
  these tests truncate shared tables directly and must run serially.

  Requires PYTHONHOME and PYTHON_THREAD_STACK_SIZE to be set.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @django_url "http://127.0.0.1:8001"
    end
  end

  setup_all do
    # Put the Repo in auto mode so we can query without manual checkout.
    Ecto.Adapters.SQL.Sandbox.mode(Horingboom.Repo, :auto)

    # Start HornbeamServer once for the module.
    # hornbeam.start can take 15s+ with Python 3.14, so we give it
    # a generous timeout for the GenServer init to complete.
    case GenServer.whereis(Horingboom.HornbeamServer) do
      nil ->
        {:ok, pid} =
          GenServer.start_link(Horingboom.HornbeamServer, [],
            name: Horingboom.HornbeamServer,
            timeout: 60_000
          )

        wait_for_django!()
        %{hornbeam_pid: pid}

      _pid ->
        wait_for_django!()
        %{hornbeam_pid: nil}
    end
  end

  setup _tags do
    # Django uses its own psycopg connection, not the Ecto sandbox,
    # so we truncate the shared table directly to get a clean slate.
    Horingboom.Repo.query!("TRUNCATE notes RESTART IDENTITY")

    # Clean ETS state between tests
    :hornbeam_state.clear()

    :ok
  end

  defp wait_for_django!(retries \\ 50) do
    case Req.get("http://127.0.0.1:8001/django/info/") do
      {:ok, %{status: 200}} ->
        :ok

      _ when retries > 0 ->
        Process.sleep(200)
        wait_for_django!(retries - 1)

      other ->
        raise "Django did not become ready: #{inspect(other)}"
    end
  end
end
