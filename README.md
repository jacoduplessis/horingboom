# Horingboom

A proof-of-concept running an Elixir/Phoenix app alongside a Python/Django app on the **same BEAM node**, connected via [hornbeam](https://hex.pm/packages/hornbeam). Both runtimes share a Postgres database and in-memory ETS state.

Hornbeam embeds a Python interpreter directly in the Erlang VM through a NIF, so there's no HTTP overhead or serialization boundary between the two runtimes. Django views can read and write ETS tables, call registered Elixir functions, and use pub/sub — all in-process.

## How it works

```
┌───────────────────────────────────────────────────────┐
│                    BEAM VM (OTP 28)                    │
│                                                       │
│  ┌─────────────┐          ┌────────────────────┐      │
│  │   Phoenix   │          │     hornbeam       │      │
│  │  :4000      │          │  (cowboy :8001)    │      │
│  │             │          │        │           │      │
│  │  Ecto +     │          │  Django WSGI app   │      │
│  │  Postgrex   │          │  via erlang_python │      │
│  │             │          │  NIF (Python 3.14) │      │
│  └──────┬──────┘          └────────┬───────────┘      │
│         │                          │                  │
│         │    ┌─────────────────────┘                  │
│         │    │                                        │
│         ▼    ▼                                        │
│  ┌──────────────────────────────────────┐             │
│  │         Shared ETS tables            │             │
│  │  hornbeam_erlang.state_get/set/incr  │             │
│  │  erlang.call (→ registered Elixir fn)│             │
│  └──────────────────────────────────────┘             │
│         │    │                                        │
│         ▼    ▼                                        │
│  ┌──────────────────────────────────────┐             │
│  │        Postgres (shared)             │             │
│  │  Phoenix writes via Ecto/Postgrex    │             │
│  │  Django writes via psycopg           │             │
│  └──────────────────────────────────────┘             │
└───────────────────────────────────────────────────────┘
```

**Phoenix** (port 4000) serves the landing page and JSON API endpoints for notes and shared ETS state.

**hornbeam** (port 8001) runs the Django WSGI app inside the BEAM. Django views import `hornbeam_erlang` for ETS state operations and the `erlang` module to call registered Elixir functions — no network calls, just NIF function calls.

**Postgres** is shared between both runtimes. Phoenix uses Ecto/Postgrex and Django uses psycopg to read and write the same `notes` table.

The `HornbeamServer` GenServer starts hornbeam in the Phoenix supervision tree, activates the Django venv, and registers Elixir functions that Django can call.

## Endpoints

| URL | What it demonstrates |
|---|---|
| `http://localhost:4000` | Phoenix landing page with links to all endpoints |
| `http://localhost:4000/api/notes` | List notes from Phoenix (Ecto/Postgrex) |
| `POST http://localhost:4000/api/notes` | Create a note from Phoenix (source="phoenix") |
| `http://localhost:4000/api/state` | Read all shared ETS state from Phoenix |
| `PUT http://localhost:4000/api/state/:key` | Write a shared ETS key from Phoenix |
| `http://localhost:8001/django/notes/` | List notes from Django (psycopg) |
| `POST http://localhost:8001/django/notes/` | Create a note from Django (source="django") |
| `http://localhost:8001/django/` | Page-view counter using `hornbeam_erlang.state_incr` (ETS) |
| `http://localhost:8001/django/shared-state/` | Read/write shared ETS state from Python |
| `http://localhost:8001/django/call-elixir/` | Call registered Elixir functions from Python (pass `?name=Yourname`) |
| `http://localhost:8001/django/info/` | Python runtime info |

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

Fetch Elixir dependencies and compile:

```sh
mix setup
```

The erlang_python NIF must be compiled against Python 3.14. If cmake picks up the wrong Python (check the cmake output for `Python3 version`), rebuild it manually:

```sh
cd deps/erlang_python && rm -rf _build/cmake && mkdir -p _build/cmake && cd _build/cmake
PYTHON_ROOT=$(uv python find 3.14 | sed 's|/bin/python3.14||')
cmake ../../c_src \
  -DPython3_EXECUTABLE="$PYTHON_ROOT/bin/python3.14" \
  -DPython3_INCLUDE_DIR="$PYTHON_ROOT/include/python3.14" \
  -DPython3_LIBRARY="$PYTHON_ROOT/lib/libpython3.14.dylib"
cmake --build .
cd ../../../..
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
- [http://localhost:8001/django/](http://localhost:8001/django/) — Django via hornbeam

Try the shared database:

```sh
# Create a note from Phoenix
curl -X POST http://localhost:4000/api/notes -H 'Content-Type: application/json' -d '{"title": "From Phoenix"}'

# Create a note from Django
curl -X POST http://localhost:8001/django/notes/ -H 'Content-Type: application/json' -d '{"title": "From Django"}'

# Both show up in either runtime
curl http://localhost:4000/api/notes
curl http://localhost:8001/django/notes/
```

## Testing

Unit tests (Phoenix controllers, Ecto schemas, contexts):

```sh
mix test
```

Integration tests boot Django via hornbeam and make real HTTP calls. They require `PYTHONHOME`, `PYTHON_THREAD_STACK_SIZE`, and `DATABASE_NAME` so Django's psycopg connects to the test database:

```sh
DATABASE_NAME=horingboom_test \
PYTHONHOME=$(uv python find 3.14 | sed 's|/bin/python3.14||') \
PYTHON_THREAD_STACK_SIZE=33554432 \
mix test --include integration
```

Integration tests are excluded by default (`@moduletag :integration`) and run serially. The `setup` callback truncates shared tables between tests since Django's psycopg bypasses the Ecto sandbox.

CI runs both suites via GitHub Actions (`.github/workflows/ci.yml`).

## Workarounds

**`PYTHONHOME` required at startup.** The erlang_python NIF calls `Py_InitializeFromConfig` with a default `PyConfig` that doesn't set `home`. Since the host process is `beam.smp` (not a Python executable), the interpreter can't locate its standard library without `PYTHONHOME` in the environment. This must be set before the BEAM starts — setting it in `config/runtime.exs` is too late because `erlang_python` loads as a dependency before the app boots.

**`PYTHON_THREAD_STACK_SIZE` needed for CPython 3.14.** BEAM scheduler threads have smaller stacks than Python expects. Without this, the embedded interpreter hits "Unrecoverable stack overflow" during Django initialization. Use 16MB (`16777216`) for development and 32MB (`33554432`) for tests.

**`hornbeam_erlang.call()` not wired up.** The Python-side `hornbeam_erlang.call(name)` routes through a `hornbeam_callbacks` bridge function that isn't registered as a py_callback. The `hornbeam_erlang.state_keys()` function has the same issue. Use the `erlang` module directly to call registered functions, and avoid `state_keys()`:

```python
# Instead of: from hornbeam_erlang import call
import erlang
result = erlang.call("my_function", arg1, arg2)

# State operations that DO work via hornbeam_erlang:
from hornbeam_erlang import state_get, state_set, state_incr, state_decr, state_delete
```

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
│   │   └── cross_runtime_test.exs  # Cross-runtime ETS + Postgres tests
│   └── horingboom/             # Unit tests (schemas, contexts, controllers)
└── mix.exs                     # hornbeam, ecto_sql, postgrex deps
```

## Stack

| Layer | Technology | Version |
|---|---|---|
| VM | Erlang/OTP | 28 |
| Web (Elixir) | Phoenix | 1.8.4 |
| Database (Elixir) | Ecto + Postgrex | 3.13 |
| Bridge | hornbeam | 1.4.1 |
| NIF | erlang_python | 1.8.1 |
| Web (Python) | Django | 6.0.2 |
| Database (Python) | psycopg | 3.3 |
| Python runtime | CPython | 3.14.0 |
| Python tooling | uv | 0.9.7 |
| Database | PostgreSQL | 17 |
