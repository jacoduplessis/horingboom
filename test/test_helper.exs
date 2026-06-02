# `mix test` runs unit tests only.
# `INTEGRATION=true mix test` runs integration tests only — they share the
# Postgres notes table with Django (which bypasses the Ecto sandbox), so they
# can't safely interleave with sandbox-isolated unit tests.
if System.get_env("INTEGRATION") == "true" do
  ExUnit.start(exclude: [:test], include: [:integration])
else
  ExUnit.start(exclude: [:integration])
end
Ecto.Adapters.SQL.Sandbox.mode(Horingboom.Repo, :manual)
