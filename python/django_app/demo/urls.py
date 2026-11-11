from django.urls import path

from api import views

urlpatterns = [
    path("django/", views.index, name="index"),
    path("django/shared-state/", views.shared_state, name="shared_state"),
    path("django/call-elixir/", views.call_elixir, name="call_elixir"),
    path("django/info/", views.info, name="info"),
    path("django/stream/", views.stream, name="stream"),
    path("django/notes/", views.notes, name="notes"),
    path("django/ecto-notes/", views.ecto_notes, name="ecto_notes"),
    path("django/ecto-tx-demo/", views.ecto_tx_demo, name="ecto_tx_demo"),
]
