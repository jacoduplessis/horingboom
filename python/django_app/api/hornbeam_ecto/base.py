"""Django DB engine that routes queries through Ecto via the hornbeam NIF.

Subclasses django.db.backends.postgresql.base.DatabaseWrapper to inherit all
the PG-specific operations (SQL generation, features, type map) and only
swaps the connection layer for one that proxies cursor.execute through
erlang.call("ecto_query", ...). See api/hornbeam_ecto/cursor.py.

PoC scope: autocommit only, no transactions, basic type marshalling.
"""

from django.db.backends.postgresql.base import (
    DatabaseWrapper as PGDatabaseWrapper,
)

from .cursor import Connection


class DatabaseWrapper(PGDatabaseWrapper):
    display_name = "PostgreSQL (via hornbeam/Ecto)"

    def get_connection_params(self):
        # No connection params needed — Ecto already has its pool configured
        # on the Elixir side. We return an empty dict so the parent class's
        # validation doesn't trip on missing NAME etc.
        return {}

    def get_new_connection(self, conn_params):
        return Connection()

    def init_connection_state(self):
        # Skip parent's psycopg-specific session setup (SET TIMEZONE etc.).
        # Ecto's connections already have whatever session state Phoenix set.
        pass

    def create_cursor(self, name=None):
        # Ignore name (no server-side cursors in this PoC).
        return self.connection.cursor()

    def _set_autocommit(self, autocommit):
        # Django flips this when entering/leaving transaction.atomic():
        #   atomic.__enter__  -> set_autocommit(False) -> begin Ecto tx
        #   atomic.__exit__   -> commit() or rollback() (handled on Connection)
        #                      -> set_autocommit(True) -> tx already over, noop
        if self.connection is None:
            return
        if autocommit:
            # Leaving manual mode. If a tx is still open it means commit/
            # rollback wasn't called; safest to roll back rather than leak.
            if self.connection.tx_id is not None:
                self.connection.rollback()
        else:
            self.connection.begin()

    def is_usable(self):
        return self.connection is not None and not self.connection.closed

    def _close(self):
        if self.connection is not None:
            self.connection.close()
