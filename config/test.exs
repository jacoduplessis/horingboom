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

# Don't start hornbeam/Python in test — tests for the Phoenix side only
config :horingboom, start_hornbeam: false

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :horingboom, HoringboomWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "ULijfrlDzBKVtDsApA/RJWkzDP2TaU3KZgaYQLZnAuyhO3uuU04co3oc93Hq1/Xm",
  server: false

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
