import Config

# Configure your database
#
# Integration tests run Django (via hornbeam) which connects to Postgres via
# psycopg. Django reads DATABASE_NAME from os.environ (see demo/settings.py).
# Pass DATABASE_NAME=horingboom_test when running integration tests so both
# Ecto and Django use the same database.
config :horingboom, Horingboom.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "horingboom_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

# INTEGRATION=true brings up hornbeam (Python + Django) and runs Phoenix's
# real HTTP listener so integration tests can hit the same single-port setup
# the dev/prod app uses. Unit tests don't need either — they use Plug.Test.
integration? = System.get_env("INTEGRATION") == "true"

config :horingboom, start_hornbeam: integration?

config :horingboom, HoringboomWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4012],
  secret_key_base: "ULijfrlDzBKVtDsApA/RJWkzDP2TaU3KZgaYQLZnAuyhO3uuU04co3oc93Hq1/Xm",
  server: integration?

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
