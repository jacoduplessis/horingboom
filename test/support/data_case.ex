defmodule Horingboom.DataCase do
  @moduledoc """
  This module defines the test case to be used by tests
  that require setting up a database connection.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Horingboom.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Horingboom.DataCase
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Horingboom.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

    :ok
  end
end
