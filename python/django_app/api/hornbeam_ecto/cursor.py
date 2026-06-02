"""Django cursor that proxies SQL through erlang.call("ecto_query", ...).

The Elixir side runs the SQL via Ecto.Adapters.SQL.query/3, so Django shares
the Phoenix app's Postgrex connection pool instead of opening its own psycopg
connection. PoC only: autocommit, no transactions, basic type marshalling.
"""

import re
from datetime import date, datetime, time
from decimal import Decimal
from uuid import UUID

import erlang


# Django/psycopg generates SQL with %s placeholders; Postgrex wants $1, $2, ...
_PARAM_RE = re.compile(r"%s")


def _convert_placeholders(sql: str) -> str:
    counter = [0]

    def repl(_match):
        counter[0] += 1
        return f"${counter[0]}"

    return _PARAM_RE.sub(repl, sql)


def _encode_param(value):
    """Python -> tagged map (for non-primitive types Erlang can't infer)."""
    if value is None or isinstance(value, (bool, int, float, str, bytes)):
        return value
    if isinstance(value, datetime):
        # isoformat with offset works for both naive and aware
        return {"__type__": "datetime", "value": value.isoformat()}
    if isinstance(value, date):
        return {"__type__": "date", "value": value.isoformat()}
    if isinstance(value, time):
        return {"__type__": "time", "value": value.isoformat()}
    if isinstance(value, Decimal):
        return {"__type__": "decimal", "value": str(value)}
    if isinstance(value, UUID):
        return str(value)
    if isinstance(value, (list, tuple)):
        return [_encode_param(v) for v in value]
    return value


def _decode_value(value):
    """Tagged map -> Python (mirror of _encode_param for results)."""
    if isinstance(value, dict) and "__type__" in value:
        t = value["__type__"]
        v = value["value"]
        if t == "datetime":
            return datetime.fromisoformat(v)
        if t == "date":
            return date.fromisoformat(v)
        if t == "time":
            return time.fromisoformat(v)
        if t == "decimal":
            return Decimal(v)
    return value


class Connection:
    """Stand-in for psycopg's connection — Django pokes at this directly.

    `tx_id` is set when the Elixir side has spawned a worker that's parked
    inside Horingboom.Repo.transaction/1; while it's set, the cursor routes
    every execute through that worker so the queries share its connection.
    """

    def __init__(self):
        self.closed = False
        self.autocommit = True
        self.tx_id = None

    def cursor(self):
        return Cursor(self)

    def close(self):
        if self.tx_id:
            # Best-effort: abandon any open tx so the Erlang worker doesn't leak
            try:
                erlang.call("ecto_tx_rollback", self.tx_id)
            except Exception:
                pass
            self.tx_id = None
        self.closed = True

    def begin(self):
        if self.tx_id is None:
            result = erlang.call("ecto_tx_begin")
            if not result.get("ok"):
                raise RuntimeError(f"ecto_tx_begin failed: {result.get('error')}")
            self.tx_id = result["tx_id"]

    def commit(self):
        if self.tx_id is None:
            return
        result = erlang.call("ecto_tx_commit", self.tx_id)
        self.tx_id = None
        if not result.get("ok"):
            raise RuntimeError(f"ecto_tx_commit failed: {result.get('error')}")

    def rollback(self):
        if self.tx_id is None:
            return
        result = erlang.call("ecto_tx_rollback", self.tx_id)
        self.tx_id = None
        if not result.get("ok"):
            raise RuntimeError(f"ecto_tx_rollback failed: {result.get('error')}")


class Cursor:
    """DB-API 2.0 cursor proxying through erlang.call("ecto_query", ...)."""

    # Django's postgresql.operations.last_executed_query pokes cursor._query
    # (a psycopg3 attribute). Falsy stub keeps it on the str-rendering branch.
    _query = None

    def __init__(self, connection: Connection):
        self.connection = connection
        self.description = None
        self.rowcount = -1
        self.arraysize = 100
        self._rows: list = []
        self._index = 0
        self.closed = False

    def execute(self, sql, params=None):
        params = list(params) if params else []
        encoded = [_encode_param(p) for p in params]
        pg_sql = _convert_placeholders(sql)

        if self.connection.tx_id is not None:
            result = erlang.call(
                "ecto_tx_query", self.connection.tx_id, pg_sql, encoded
            )
        else:
            result = erlang.call("ecto_query", pg_sql, encoded)

        if not result.get("ok"):
            raise RuntimeError(f"Ecto error: {result.get('error')}")

        cols = result.get("columns") or []
        rows = result.get("rows") or []

        # psycopg's description is a 7-tuple; Django only reliably reads .name.
        self.description = [
            (col, None, None, None, None, None, None) for col in cols
        ]
        self._rows = [tuple(_decode_value(v) for v in row) for row in rows]
        self.rowcount = result.get("num_rows", len(self._rows))
        self._index = 0
        return self

    def executemany(self, sql, seq_of_params):
        for params in seq_of_params:
            self.execute(sql, params)

    def fetchone(self):
        if self._index >= len(self._rows):
            return None
        row = self._rows[self._index]
        self._index += 1
        return row

    def fetchmany(self, size=None):
        size = size or self.arraysize
        out = []
        for _ in range(size):
            row = self.fetchone()
            if row is None:
                break
            out.append(row)
        return out

    def fetchall(self):
        out = self._rows[self._index :]
        self._index = len(self._rows)
        return out

    def close(self):
        self.closed = True
        self._rows = []
        self._index = 0

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()

    def __iter__(self):
        return self

    def __next__(self):
        row = self.fetchone()
        if row is None:
            raise StopIteration
        return row
