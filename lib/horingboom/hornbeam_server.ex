defmodule Horingboom.HornbeamServer do
  use GenServer
  require Logger

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @tx_table :ecto_tx_workers
  # If Python abandons a transaction (process crash, network drop), the worker
  # would otherwise hold its Ecto connection forever. Auto-rollback after this
  # many ms of silence.
  @tx_idle_timeout 60_000

  @impl true
  def init(_) do
    django_path = Path.expand("../../python/django_app", __DIR__)
    venv_path = Path.join(django_path, ".venv")

    :ets.new(@tx_table, [:named_table, :public, :set])

    Logger.info("Starting hornbeam with Django app at #{django_path}")

    :hornbeam.start("demo.wsgi:application", %{
      bind: "127.0.0.1:8001",
      num_contexts: 2,
      worker_class: :wsgi,
      venv: venv_path,
      pythonpath: [django_path]
    })

    :hornbeam.register_function("system_info", fn _args ->
      %{
        otp_release: :erlang.system_info(:otp_release) |> to_string(),
        elixir_version: System.version(),
        node: Node.self() |> to_string(),
        schedulers: :erlang.system_info(:schedulers)
      }
    end)

    :hornbeam.register_function("greeting", fn [name] ->
      "Hello #{name}, from Elixir #{System.version()} on the BEAM!"
    end)

    :hornbeam.register_function("ecto_query", fn [sql, params] ->
      Horingboom.HornbeamServer.ecto_query(sql, params)
    end)

    :hornbeam.register_function("ecto_tx_begin", fn _args ->
      Horingboom.HornbeamServer.ecto_tx_begin()
    end)

    :hornbeam.register_function("ecto_tx_query", fn [tx_id, sql, params] ->
      Horingboom.HornbeamServer.ecto_tx_query(tx_id, sql, params)
    end)

    :hornbeam.register_function("ecto_tx_commit", fn [tx_id] ->
      Horingboom.HornbeamServer.ecto_tx_commit(tx_id)
    end)

    :hornbeam.register_function("ecto_tx_rollback", fn [tx_id] ->
      Horingboom.HornbeamServer.ecto_tx_rollback(tx_id)
    end)

    Logger.info("Hornbeam started — Django available at http://127.0.0.1:8001/django/")

    {:ok, %{}}
  end

  # Bridge: run SQL through Horingboom.Repo so Django's ORM can share Ecto's
  # connection pool. Tagged maps round-trip non-primitive types (datetimes,
  # decimals) since erlang_python only carries primitives + maps natively.
  def ecto_query(sql, params) do
    try do
      decoded = Enum.map(params, &decode_param/1)

      case Ecto.Adapters.SQL.query(Horingboom.Repo, sql, decoded) do
        {:ok, %{columns: cols, rows: rows, num_rows: n}} ->
          %{
            "ok" => true,
            "columns" => cols || [],
            "rows" => encode_rows(rows),
            "num_rows" => n
          }

        {:error, err} ->
          %{"ok" => false, "error" => Exception.message(err)}
      end
    rescue
      e -> %{"ok" => false, "error" => Exception.message(e)}
    end
  end

  defp decode_param(%{"__type__" => "datetime", "value" => iso}) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> dt
      _ -> NaiveDateTime.from_iso8601!(iso)
    end
  end

  defp decode_param(%{"__type__" => "date", "value" => iso}), do: Date.from_iso8601!(iso)
  defp decode_param(%{"__type__" => "time", "value" => iso}), do: Time.from_iso8601!(iso)
  defp decode_param(%{"__type__" => "decimal", "value" => s}), do: Decimal.new(s)
  defp decode_param(v), do: v

  defp encode_value(%DateTime{} = v), do: %{"__type__" => "datetime", "value" => DateTime.to_iso8601(v)}

  defp encode_value(%NaiveDateTime{} = v),
    do: %{"__type__" => "datetime", "value" => NaiveDateTime.to_iso8601(v)}

  defp encode_value(%Date{} = v), do: %{"__type__" => "date", "value" => Date.to_iso8601(v)}
  defp encode_value(%Time{} = v), do: %{"__type__" => "time", "value" => Time.to_iso8601(v)}
  defp encode_value(%Decimal{} = v), do: %{"__type__" => "decimal", "value" => Decimal.to_string(v)}
  defp encode_value(v), do: v

  # Wrap each row as a tuple. A pure list of small integers gets optimized to
  # STRING_EXT in the Erlang external term format, which erlang_python then
  # decodes as a Python str — so `[42]` from `RETURNING id` would arrive as
  # `"*"`. Tuples skip that optimization.
  defp encode_rows(nil), do: []

  defp encode_rows(rows) do
    Enum.map(rows, fn row ->
      row |> Enum.map(&encode_value/1) |> List.to_tuple()
    end)
  end

  # --- Transactions ---
  #
  # Ecto's transactions work by storing the checked-out connection in the
  # process dictionary; any query from inside Repo.transaction/1 reuses it.
  # To extend that across the NIF boundary we spawn a worker that *stays*
  # inside Repo.transaction/1 and processes query messages, so every
  # Ecto.Adapters.SQL.query call runs in the same process that owns the
  # checked-out connection.

  def ecto_tx_begin do
    parent = self()
    tx_id = :erlang.unique_integer([:positive]) |> Integer.to_string()

    worker =
      spawn(fn ->
        Horingboom.Repo.transact(
          fn ->
            send(parent, {:tx_ready, tx_id})
            tx_loop(tx_id)
          end,
          timeout: :infinity
        )

        :ets.delete(@tx_table, tx_id)
      end)

    receive do
      {:tx_ready, ^tx_id} ->
        :ets.insert(@tx_table, {tx_id, worker})
        %{"ok" => true, "tx_id" => tx_id}
    after
      5_000 ->
        Process.exit(worker, :kill)
        %{"ok" => false, "error" => "tx start timeout"}
    end
  end

  def ecto_tx_query(tx_id, sql, params) do
    with_worker(tx_id, fn worker ->
      ref = make_ref()
      decoded = Enum.map(params, &decode_param/1)
      send(worker, {:query, sql, decoded, self(), ref})

      receive do
        {:tx_query_result, ^ref, {:ok, %{columns: cols, rows: rows, num_rows: n}}} ->
          %{
            "ok" => true,
            "columns" => cols || [],
            "rows" => encode_rows(rows),
            "num_rows" => n
          }

        {:tx_query_result, ^ref, {:error, err}} ->
          %{"ok" => false, "error" => Exception.message(err)}
      after
        30_000 -> %{"ok" => false, "error" => "tx query timeout"}
      end
    end)
  end

  def ecto_tx_commit(tx_id) do
    with_worker(tx_id, fn worker ->
      ref = make_ref()
      send(worker, {:commit, self(), ref})

      receive do
        {:tx_committed, ^ref} -> %{"ok" => true}
      after
        5_000 -> %{"ok" => false, "error" => "commit timeout"}
      end
    end)
  end

  def ecto_tx_rollback(tx_id) do
    with_worker(tx_id, fn worker ->
      ref = make_ref()
      send(worker, {:rollback, self(), ref})

      receive do
        {:tx_rolled_back, ^ref} -> %{"ok" => true}
      after
        5_000 -> %{"ok" => false, "error" => "rollback timeout"}
      end
    end)
  end

  defp with_worker(tx_id, fun) do
    case :ets.lookup(@tx_table, tx_id) do
      [{^tx_id, worker}] -> fun.(worker)
      [] -> %{"ok" => false, "error" => "unknown transaction #{tx_id}"}
    end
  end

  # transact/2 commits on {:ok, _} and rolls back on {:error, _}, so the
  # commit/rollback messages from Python translate directly to those tuples
  # — no explicit Repo.rollback/1 needed.
  defp tx_loop(tx_id) do
    receive do
      {:query, sql, params, from, ref} ->
        result = Ecto.Adapters.SQL.query(Horingboom.Repo, sql, params)
        send(from, {:tx_query_result, ref, result})
        tx_loop(tx_id)

      {:commit, from, ref} ->
        send(from, {:tx_committed, ref})
        {:ok, :committed}

      {:rollback, from, ref} ->
        send(from, {:tx_rolled_back, ref})
        {:error, :user_requested}
    after
      @tx_idle_timeout ->
        {:error, :idle_timeout}
    end
  end
end
