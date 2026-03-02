defmodule HoringboomWeb.PageControllerTest do
  use HoringboomWeb.ConnCase

  test "GET / renders the home page", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Horingboom PoC"
  end

  test "home page mentions shared Postgres", %{conn: conn} do
    conn = get(conn, ~p"/")
    body = html_response(conn, 200)
    assert body =~ "Shared Postgres"
    assert body =~ "notes"
  end

  test "home page links to notes endpoints", %{conn: conn} do
    conn = get(conn, ~p"/")
    body = html_response(conn, 200)
    assert body =~ "/api/notes"
    assert body =~ "/django/notes/"
  end

  test "home page links to state endpoints", %{conn: conn} do
    conn = get(conn, ~p"/")
    body = html_response(conn, 200)
    assert body =~ "/api/state"
    assert body =~ "/django/shared-state/"
  end

  test "home page shows Django endpoints", %{conn: conn} do
    conn = get(conn, ~p"/")
    body = html_response(conn, 200)
    assert body =~ "/django/"
    assert body =~ "/django/call-elixir/"
    assert body =~ "/django/info/"
  end

  test "home page shows runtime versions", %{conn: conn} do
    conn = get(conn, ~p"/")
    body = html_response(conn, 200)
    assert body =~ "Elixir"
    assert body =~ "Python 3.14"
    assert body =~ "hornbeam"
  end
end
