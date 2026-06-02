import json
import sys

from django.db import transaction
from django.http import JsonResponse
from django.views.decorators.csrf import csrf_exempt
from django.views.decorators.http import require_http_methods

from hornbeam_erlang import state_incr, state_get, state_set
import erlang

from api.models import Note


def index(request):
    """Hello from Django, with ETS page-view counter."""
    views = state_incr(f"views:{request.path}")
    return JsonResponse({
        "message": "Hello from Django, running inside the BEAM via hornbeam!",
        "path": request.path,
        "view_count": views,
    })


def shared_state(request):
    """Read/write shared ETS state, demonstrating cross-runtime shared memory."""
    # Write a value from Django
    state_set("django:demo_key", {"written_by": "Django", "python_version": sys.version})

    # Read it back
    value = state_get("django:demo_key")

    # Increment a shared counter
    counter = state_incr("shared:counter")

    return JsonResponse({
        "message": "Shared ETS state between Elixir and Python",
        "written_value": value,
        "shared_counter": counter,
    })


def call_elixir(request):
    """Call registered Elixir functions from Python."""
    name = request.GET.get("name", "World")

    system_info = erlang.call("system_info")
    greeting = erlang.call("greeting", name)

    return JsonResponse({
        "message": "Called registered Elixir functions from Python",
        "system_info": system_info,
        "greeting": greeting,
    })


def info(request):
    """Show execution mode and system info.

    erlang_python 3.x sandboxes subprocess.Popen (fork() would corrupt the
    Erlang VM), so we read platform info from sys.* attributes instead of
    platform.platform() / platform.python_implementation().
    """
    return JsonResponse({
        "message": "Python runtime info inside hornbeam",
        "python_version": sys.version,
        "platform": sys.platform,
        "implementation": sys.implementation.name,
        "executable": sys.executable,
    })


@csrf_exempt
@require_http_methods(["GET", "POST"])
def ecto_notes(request):
    """Same as notes(), but routed through the hornbeam_ecto backend.

    Demonstrates Django's ORM driving Ecto's Postgrex connection pool via the
    NIF instead of psycopg.
    """
    if request.method == "GET":
        qs = Note.objects.using("ecto").all()
        # Demo: WHERE binding via the proxied cursor when ?source=... is passed.
        source_filter = request.GET.get("source")
        if source_filter:
            qs = qs.filter(source=source_filter)
        all_notes = qs.order_by("-inserted_at")[:10]
        return JsonResponse({
            "via": "ecto",
            "filter_source": source_filter,
            "notes": [
                {
                    "id": n.id,
                    "title": n.title,
                    "body": n.body,
                    "source": n.source,
                    "inserted_at": n.inserted_at.isoformat() if n.inserted_at else None,
                    "updated_at": n.updated_at.isoformat() if n.updated_at else None,
                }
                for n in all_notes
            ]
        })

    data = json.loads(request.body)
    note = Note.objects.using("ecto").create(
        title=data["title"],
        body=data.get("body", ""),
        source="django-ecto",
    )
    return JsonResponse({
        "via": "ecto",
        "note": {
            "id": note.id,
            "title": note.title,
            "body": note.body,
            "source": note.source,
            "inserted_at": note.inserted_at.isoformat() if note.inserted_at else None,
            "updated_at": note.updated_at.isoformat() if note.updated_at else None,
        }
    }, status=201)


@csrf_exempt
@require_http_methods(["POST"])
def ecto_tx_demo(request):
    """Insert two notes inside `transaction.atomic(using='ecto')`.

    ?action=commit  -> both rows persist
    ?action=raise   -> raise inside the block; both inserts roll back

    The Ecto-side worker holds the connection until commit/rollback, so the
    second INSERT sees the first one's data within the same transaction.
    """
    action = request.GET.get("action", "commit")

    titles_before = [
        n.title
        for n in Note.objects.using("ecto").filter(source="tx-demo").order_by("id")
    ]

    inserted = []
    try:
        with transaction.atomic(using="ecto"):
            a = Note.objects.using("ecto").create(
                title="tx-a", body="first", source="tx-demo"
            )
            inserted.append(a.id)

            # Read-your-own-write: the second statement runs inside the same
            # Ecto transaction worker, so it sees row `a` (and would see it
            # even before commit since they share the connection).
            seen_inside = list(
                Note.objects.using("ecto")
                .filter(source="tx-demo")
                .values_list("title", flat=True)
            )

            b = Note.objects.using("ecto").create(
                title="tx-b", body="second", source="tx-demo"
            )
            inserted.append(b.id)

            if action == "raise":
                raise RuntimeError("demo rollback")
    except RuntimeError as e:
        outcome = f"rolled back: {e}"
    else:
        outcome = "committed"
        seen_inside = seen_inside  # populated above

    titles_after = [
        n.title
        for n in Note.objects.using("ecto").filter(source="tx-demo").order_by("id")
    ]

    return JsonResponse({
        "via": "ecto",
        "action": action,
        "outcome": outcome,
        "inserted_ids": inserted,
        "titles_before": titles_before,
        "seen_inside_tx": seen_inside if action == "commit" else None,
        "titles_after": titles_after,
    })


@csrf_exempt
@require_http_methods(["GET", "POST"])
def notes(request):
    """List or create notes in the shared Postgres database."""
    if request.method == "GET":
        all_notes = Note.objects.all().order_by("-inserted_at")
        return JsonResponse({
            "notes": [
                {
                    "id": n.id,
                    "title": n.title,
                    "body": n.body,
                    "source": n.source,
                    "inserted_at": n.inserted_at.isoformat() if n.inserted_at else None,
                    "updated_at": n.updated_at.isoformat() if n.updated_at else None,
                }
                for n in all_notes
            ]
        })

    # POST
    data = json.loads(request.body)
    note = Note.objects.create(
        title=data["title"],
        body=data.get("body", ""),
        source="django",
    )
    return JsonResponse({
        "note": {
            "id": note.id,
            "title": note.title,
            "body": note.body,
            "source": note.source,
            "inserted_at": note.inserted_at.isoformat() if note.inserted_at else None,
            "updated_at": note.updated_at.isoformat() if note.updated_at else None,
        }
    }, status=201)
