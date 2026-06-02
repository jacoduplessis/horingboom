defmodule Horingboom.IntegrationCase do
  @moduledoc """
  Test case for integration tests that need hornbeam/Django running.

  Phoenix and Django share a single cowboy listener (HornbeamServer injects
  /django/[...] into the endpoint dispatch at boot). These tests just hit
  the Phoenix endpoint with real HTTP and rely on the app having booted
  with `INTEGRATION=true`, which enables both `start_hornbeam` and the
  endpoint's `server` flag.

  Run with:

      INTEGRATION=true PYTHONHOME=... PYTHON_THREAD_STACK_SIZE=16777216 mix test

  Django uses its own psycopg connection (not the Ecto sandbox), so these
  tests truncate shared tables directly and must run serially.
  """

  use ExUnit.CaseTemplate

  # Matches config/test.exs.
  @port 4002

  using do
    quote do
      @django_url "http://127.0.0.1:#{unquote(@port)}"
    end
  end

  setup_all do
    unless System.get_env("INTEGRATION") == "true" do
      raise """
      Integration tests require INTEGRATION=true so hornbeam and the Phoenix
      listener are both started. See @moduledoc on Horingboom.IntegrationCase.
      """
    end

    Ecto.Adapters.SQL.Sandbox.mode(Horingboom.Repo, :auto)
    wait_for_django!()
    :ok
  end

  setup _tags do
    Horingboom.Repo.query!("TRUNCATE notes RESTART IDENTITY")
    :hornbeam_state.clear()
    :ok
  end

  defp wait_for_django!(retries \\ 50) do
    case Req.get("http://127.0.0.1:#{@port}/django/info/") do
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
