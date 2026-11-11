# Horingboom

A proof-of-concept running an Elixir/Phoenix app alongside a Python/Django app on the **same BEAM node**, connected via [hornbeam](https://hex.pm/packages/hornbeam). Both runtimes share a Postgres database and in-memory ETS state.

Hornbeam embeds a Python interpreter directly in the Erlang VM through a NIF, so there's no HTTP overhead or serialization boundary between the two runtimes. Django views can read and write ETS tables, call registered Elixir functions, and use pub/sub — all in-process.

## How it works

```
┌────────────────────────────────────────────────────────────┐
│                     BEAM VM (OTP 28)                       │
│                                                            │
│              ┌──────────────────────────┐                  │
│         ┌──▶ │   Bandit :4000           │ ◀──┐             │
│         │    │   Phoenix endpoint plugs │    │             │
│         │    └──────────┬───────────────┘    │             │
│         │               │ /django/*          │             │
│         │    router ┌───┴───┐                │             │
│         │           ▼       ▼                │             │
│  ┌──────┴──────┐  ┌──────────────────┐       │             │
│  │   Phoenix   │  │ DjangoPlug       │       │             │
│  │   router    │  │ (WSGI bridge)    │       │             │
│  │             │  │      │           │       │             │
│  │  Ecto +     │  │ Django WSGI app  │       │             │
│  │  Postgrex   │  │ via erlang_python│       │             │
│  │             │  │ NIF (Python 3.14)│       │             │
│  └──────┬──────┘  └────────┬─────────┘       │             │
│         │                  │                 │             │
│         │   ┌──────────────┘                 │             │
│         │   │                                │             │
│         ▼   ▼                                │             │
│  ┌──────────────────────────────────────┐    │             │
│  │         Shared ETS tables            │ ───┘             │
│  │  hornbeam_erlang.state_get/set/incr  │                  │
│  │  erlang.call (→ registered Elixir fn)│                  │
│  └──────────────────────────────────────┘                  │
│         │   │                                              │
│         ▼   ▼                                              │
│  ┌──────────────────────────────────────┐                  │
│  │        Postgres (shared)             │                  │
│  │  Phoenix writes via Ecto/Postgrex    │                  │
│  │  Django writes via psycopg           │                  │
│  └──────────────────────────────────────┘                  │
└────────────────────────────────────────────────────────────┘
```

**Single port (4000).** Phoenix's Bandit listener fronts everything. `HoringboomWeb.DjangoPlug` sits in the endpoint just before `Plug.Parsers` (Django needs the raw body), serves `/django/*` from Django, and passes everything else on to the Phoenix router. Django requests get Phoenix's request id and telemetry on the way.

**`DjangoPlug`** does what hornbeam's own `hornbeam_handler` does, starting from a `Plug.Conn`. It reads the body into a `py_buffer`, builds the request tuple of `hornbeam_request:build_wsgi_tuple/2`, calls `hornbeam_wsgi_worker.handle_request_tuple`, and turns the messages Python sends back into `send_resp` or `send_chunked`. That protocol is internal to hornbeam, which is why `mix.exs` pins hornbeam by commit: re-check it before bumping.

**`HornbeamServer`** brings up the Python runtime and registers Elixir callbacks. It calls `:hornbeam.start/2` with `bind: "127.0.0.1:0"` and immediately runs `:hornbeam_listener.stop_service/0` — hornbeam always starts its own (livery) listener, but we throw it away. On shutdown it calls `:hornbeam.stop/0`. Order in `application.ex` matters: HornbeamServer must come before `HoringboomWeb.Endpoint` so Python is up before requests arrive.

**Postgres** is shared. Phoenix uses Ecto/Postgrex, Django uses psycopg, and they read/write the same `notes` table.

## Endpoints

| URL | What it demonstrates |
|---|---|
| `http://localhost:4000` | Phoenix landing page with links to all endpoints |
| `http://localhost:4000/api/notes` | List notes from Phoenix (Ecto/Postgrex) |
| `POST http://localhost:4000/api/notes` | Create a note from Phoenix (source="phoenix") |
| `http://localhost:4000/api/state` | Read all shared ETS state from Phoenix |
| `PUT http://localhost:4000/api/state/:key` | Write a shared ETS key from Phoenix |
| `http://localhost:4000/django/notes/` | List notes from Django (psycopg) |
| `POST http://localhost:4000/django/notes/` | Create a note from Django (source="django") |
| `http://localhost:4000/django/` | Page-view counter using `hornbeam_erlang.state_incr` (ETS) |
| `http://localhost:4000/django/shared-state/` | Read/write shared ETS state from Python |
| `http://localhost:4000/django/call-elixir/` | Call registered Elixir functions from Python (pass `?name=Yourname`) |
| `http://localhost:4000/django/info/` | Python runtime info |
| `http://localhost:4000/django/stream/` | `StreamingHttpResponse`, sent by Phoenix as a chunked response |
| `GET http://localhost:4000/django/ecto-notes/` | List notes via Django ORM routed through Ecto's Postgrex pool (proof-of-concept) |
| `POST http://localhost:4000/django/ecto-notes/` | Create note via Django ORM routed through Ecto |
| `POST http://localhost:4000/django/ecto-tx-demo/?action=commit\|raise` | Two inserts in `transaction.atomic(using='ecto')`; commit persists both, raise rolls back both |

## Prerequisites

- Erlang/OTP 28
- Elixir 1.19+
- [uv](https://docs.astral.sh/uv/) 0.9+
- cmake (for compiling the erlang_python NIF)
- PostgreSQL

## Setup

Install Python 3.14 and sync the Django virtualenv:

```sh
uv python install 3.14
cd python/django_app && uv sync && cd ../..
```

Fetch Elixir dependencies and compile. The erlang_python NIF must be built against the same Python 3.14 that `PYTHONHOME` points at below; `PYTHON_CONFIG` tells its CMake which one:

```sh
PYTHON_CONFIG="$(uv python find 3.14)-config" mix setup
```

If cmake still picked up the wrong Python (check the cmake output for `Python3 version`), clear its cache and rebuild just the NIF:

```sh
rm -rf deps/erlang_python/_build/cmake
PYTHON_CONFIG="$(uv python find 3.14)-config" mix deps.compile erlang_python --force
```

Create the database and run migrations:

```sh
mix ecto.setup
```

## Running

`PYTHONHOME` must point to the Python installation so the embedded interpreter can find its standard library at startup. `PYTHON_THREAD_STACK_SIZE` prevents stack overflow in the embedded Python when running on BEAM scheduler threads:

```sh
PYTHONHOME=$(uv python find 3.14 | sed 's|/bin/python3.14||') PYTHON_THREAD_STACK_SIZE=16777216 mix phx.server
```

Then open:

- [http://localhost:4000](http://localhost:4000) — Phoenix
- [http://localhost:4000/django/](http://localhost:4000/django/) — Django via hornbeam (same listener)

Try the shared database:

```sh
# Create a note from Phoenix
curl -X POST http://localhost:4000/api/notes -H 'Content-Type: application/json' -d '{"title": "From Phoenix"}'

# Create a note from Django
curl -X POST http://localhost:4000/django/notes/ -H 'Content-Type: application/json' -d '{"title": "From Django"}'

# Both show up in either runtime
curl http://localhost:4000/api/notes
curl http://localhost:4000/django/notes/
```

## Testing

Unit tests (Phoenix controllers, Ecto schemas, contexts) — fast, no Python boot:

```sh
PYTHONHOME=$(uv python find 3.14 | sed 's|/bin/python3.14||') \
PYTHON_THREAD_STACK_SIZE=16777216 \
mix test
```

`PYTHONHOME` is needed even for unit tests because the `erlang_python` OTP application (a dep of hornbeam) starts unconditionally and the embedded interpreter needs to find its stdlib.

Integration tests boot Django via hornbeam, bring up Phoenix's real Bandit listener on the test port (4002), and make real HTTP calls through it — the same path the dev/prod app uses. They run **on their own** (not interleaved with unit tests) because Django's psycopg bypasses the Ecto sandbox and the suite TRUNCATEs the shared `notes` table:

```sh
INTEGRATION=true \
DATABASE_NAME=horingboom_test \
PYTHONHOME=$(uv python find 3.14 | sed 's|/bin/python3.14||') \
PYTHON_THREAD_STACK_SIZE=33554432 \
mix test
```

`INTEGRATION=true` flips `test_helper.exs` to include only `@moduletag :integration` tests and enables both `start_hornbeam` and the endpoint's `server` flag in `config/test.exs`. Without it, `mix test` runs only unit tests and skips integration.

CI runs both suites via GitHub Actions (`.github/workflows/ci.yml`).

## Proof of concept: Django ORM over Ecto

`api/hornbeam_ecto/` is a custom Django database backend that ships SQL to Elixir
via `erlang.call("ecto_query", sql, params)` instead of opening its own psycopg
connection. The Elixir side (`Horingboom.HornbeamServer.ecto_query/2`) runs the
SQL through `Ecto.Adapters.SQL.query/3`, so Django shares Phoenix's Postgrex
connection pool.

- `engine = 'api.hornbeam_ecto'` (registered as the `'ecto'` DB in `settings.py`)
- The cursor converts `%s` placeholders to `$1`-style and tags non-primitive
  param/result values (`datetime`, `date`, `time`, `decimal`) as
  `{"__type__": ..., "value": ...}` so they survive the erlang_python boundary
- Use it: `Note.objects.using("ecto").all()`, `.filter(...)`, `.create(...)`
- The `/django/ecto-notes/` endpoint exercises both SELECT (with WHERE
  binding via `?source=...`) and INSERT...RETURNING

**Transactions** are supported via a long-lived worker process. Ecto's own
transactions rely on `DBConnection` stashing the checked-out connection in
the **process dictionary**, so any query from that same Erlang process
inside `Repo.transaction/1` reuses the bound connection. To extend that
across the NIF boundary, `ecto_tx_begin` spawns a worker that parks itself
inside `Horingboom.Repo.transaction(fn -> tx_loop() end)` and processes
`{:query, ...}` / `{:commit, ...}` / `{:rollback, ...}` messages. Every
query runs in that worker, so they all share the bound connection. The
worker exits normally on commit and calls `Repo.rollback/1` on rollback or
idle timeout (60s).

Django wiring: `_set_autocommit(False)` (called by `transaction.atomic` on
enter) calls `ecto_tx_begin` and stores the `tx_id` on the connection;
`commit()` / `rollback()` (called on exit) tear it down. While `tx_id` is
set, `cursor.execute` routes through `ecto_tx_query` instead of
`ecto_query`. `transaction.atomic(using='ecto')` just works — see
`/django/ecto-tx-demo/`.

**Remaining limits.** No savepoints, so nested `transaction.atomic()` will
fail. Type marshalling is minimal (datetime/date/time/decimal tagged maps
plus primitives). `cursor.description` doesn't carry real PG type codes —
fine for the ORM but breaks anything that inspects type OIDs. Subclassing
the PG backend means we still depend on psycopg being installed (Django
imports it eagerly to pick up adapter maps).

## Workarounds

**`PYTHONHOME` required at startup.** The erlang_python NIF calls `Py_InitializeFromConfig` with a default `PyConfig` that doesn't set `home`. Since the host process is `beam.smp` (not a Python executable), the interpreter can't locate its standard library without `PYTHONHOME` in the environment. This must be set before the BEAM starts — setting it in `config/runtime.exs` is too late because `erlang_python` loads as a dependency before the app boots.

**`PYTHON_THREAD_STACK_SIZE` needed for CPython 3.14.** BEAM scheduler threads have smaller stacks than Python expects. Without this, the embedded interpreter hits "Unrecoverable stack overflow" during Django initialization. Use 16MB (`16777216`) for development and 32MB (`33554432`) for tests.

**`subprocess.Popen` is sandboxed.** erlang_python (3.x and later) installs a PEP 578 audit hook that blocks `subprocess.Popen`, `os.system`, `os.popen`, `os.fork`, and `os.exec*`/`os.spawn*` — fork/exec would corrupt the BEAM runtime. Avoid `platform.platform()` and `platform.python_implementation()` (they shell out to `uname`); read `sys.platform` and `sys.implementation.name` instead.

**Bodyless requests still get a `py_buffer`.** Hornbeam marks bodyless requests with the atom `empty`, but erlang_python (3.x and later) hands atoms to Python as `str`, and hornbeam's WSGI worker only recognises `b'empty'` — so Django would get the string as `wsgi.input`. `DjangoPlug` always passes a closed (possibly empty) buffer instead, so `deps/hornbeam` needs no patch.

## Project structure

```
horingboom/
├── .github/
│   └── workflows/
│       └── ci.yml              # GitHub Actions (unit + integration tests)
├── config/
│   ├── config.exs              # Ecto repos config
│   ├── dev.exs                 # Repo database config
│   ├── test.exs                # Test database, sandbox pool
│   └── runtime.exs             # Port config, prod secrets
├── lib/
│   ├── horingboom/
│   │   ├── application.ex      # Supervision tree (Repo, HornbeamServer)
│   │   ├── hornbeam_server.ex  # Starts hornbeam, registers Elixir functions
│   │   ├── repo.ex             # Ecto.Repo
│   │   ├── notes.ex            # Notes context
│   │   └── notes/
│   │       └── note.ex         # Ecto schema
│   └── horingboom_web/
│       ├── endpoint.ex         # Plug pipeline; DjangoPlug before Plug.Parsers
│       ├── django_plug.ex      # Serves /django/* through hornbeam's WSGI worker
│       ├── router.ex           # /api/notes, /api/state routes
│       └── controllers/
│           ├── notes_controller.ex  # Notes JSON API
│           ├── state_controller.ex  # ETS state JSON API
│           └── page_html/
│               └── home.html.heex   # Landing page
├── priv/
│   └── repo/
│       └── migrations/         # Ecto migrations (notes table)
├── python/
│   └── django_app/             # uv-managed, Python 3.14
│       ├── demo/
│       │   ├── settings.py     # Postgres config (DATABASE_NAME env var)
│       │   ├── urls.py
│       │   └── wsgi.py
│       └── api/
│           ├── models.py       # Note model (managed=False)
│           └── views.py        # Views using hornbeam_erlang + erlang + psycopg
├── test/
│   ├── support/
│   │   ├── conn_case.ex        # Phoenix.ConnCase with Ecto sandbox
│   │   ├── data_case.ex        # Ecto DataCase for context tests
│   │   └── integration_case.ex # Boots HornbeamServer, truncates between tests
│   ├── integration/
│   │   ├── django_test.exs     # Django endpoint tests (HTTP via Req)
│   │   ├── django_plug_test.exs    # WSGI bridge: paths, bodies, headers, streaming
│   │   └── cross_runtime_test.exs  # Cross-runtime ETS + Postgres tests
│   └── horingboom/             # Unit tests (schemas, contexts, controllers)
└── mix.exs                     # hornbeam, ecto_sql, postgrex deps
```

## Stack

| Layer | Technology | Version |
|---|---|---|
| VM | Erlang/OTP | 28 |
| Web (Elixir) | Phoenix + Bandit | 1.8.4 / 1.12 |
| Database (Elixir) | Ecto + Postgrex | 3.13 |
| Bridge | hornbeam | main @ `19f8993` (unreleased, post-1.4.1) |
| HTTP (hornbeam's, stopped at boot) | livery | 0.12.1 |
| NIF | erlang_python | 5.0.1 |
| Web (Python) | Django | 6.0.2 |
| Database (Python) | psycopg | 3.3 |
| Python runtime | CPython | 3.14 (3.14.10 at time of writing) |
| Python tooling | uv | 0.9.7 |
| Database | PostgreSQL | 17 |
