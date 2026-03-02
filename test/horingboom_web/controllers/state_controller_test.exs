defmodule HoringboomWeb.StateControllerTest do
  use HoringboomWeb.ConnCase

  # hornbeam_state uses a named ETS table; we create one for testing
  # since hornbeam isn't running in the test environment.
  setup do
    table =
      if :ets.whereis(:hornbeam_state_table) == :undefined do
        :ets.new(:hornbeam_state_table, [:named_table, :public, :set])
      else
        :ets.delete_all_objects(:hornbeam_state_table)
        :hornbeam_state_table
      end

    on_exit(fn ->
      if :ets.whereis(:hornbeam_state_table) != :undefined do
        :ets.delete_all_objects(:hornbeam_state_table)
      end
    end)

    {:ok, table: table}
  end

  describe "GET /api/state" do
    test "returns empty state when no keys set", %{conn: conn} do
      conn = get(conn, ~p"/api/state")
      assert json_response(conn, 200) == %{"state" => %{}}
    end

    test "returns all state keys and values", %{conn: conn} do
      :hornbeam_state.set("key1", "value1")
      :hornbeam_state.set("key2", 42)

      conn = get(conn, ~p"/api/state")
      %{"state" => state} = json_response(conn, 200)

      assert state["key1"] == "value1"
      assert state["key2"] == 42
    end
  end

  describe "PUT /api/state/:key" do
    test "sets a string value", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put(~p"/api/state/greeting", %{value: "hello"})

      response = json_response(conn, 200)
      assert response["key"] == "greeting"
      assert response["value"] == "hello"
      assert response["source"] == "phoenix"

      # Verify it's actually in ETS
      assert :hornbeam_state.get("greeting") == "hello"
    end

    test "sets a numeric value", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put(~p"/api/state/count", %{value: 42})

      response = json_response(conn, 200)
      assert response["value"] == 42
      assert :hornbeam_state.get("count") == 42
    end

    test "overwrites existing value", %{conn: conn} do
      :hornbeam_state.set("key", "old")

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put(~p"/api/state/key", %{value: "new"})

      assert json_response(conn, 200)["value"] == "new"
      assert :hornbeam_state.get("key") == "new"
    end

    test "value appears in subsequent GET", %{conn: conn} do
      conn
      |> put_req_header("content-type", "application/json")
      |> put(~p"/api/state/test_key", %{value: "test_value"})

      conn = get(build_conn(), ~p"/api/state")
      %{"state" => state} = json_response(conn, 200)
      assert state["test_key"] == "test_value"
    end
  end
end
