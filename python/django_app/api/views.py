import json
import sys
import platform

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
    """Show execution mode and system info."""
    return JsonResponse({
        "message": "Python runtime info inside hornbeam",
        "python_version": sys.version,
        "platform": platform.platform(),
        "implementation": platform.python_implementation(),
        "executable": sys.executable,
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
