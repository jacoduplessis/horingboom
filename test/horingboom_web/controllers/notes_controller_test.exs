defmodule HoringboomWeb.NotesControllerTest do
  use HoringboomWeb.ConnCase

  alias Horingboom.Notes

  describe "GET /api/notes" do
    test "returns empty list when no notes", %{conn: conn} do
      conn = get(conn, ~p"/api/notes")
      assert json_response(conn, 200) == %{"notes" => []}
    end

    test "returns all notes", %{conn: conn} do
      {:ok, _} = Notes.create_note(%{title: "First", body: "body1", source: "phoenix"})
      {:ok, _} = Notes.create_note(%{title: "Second", source: "django"})

      conn = get(conn, ~p"/api/notes")
      %{"notes" => notes} = json_response(conn, 200)

      assert length(notes) == 2
      titles = Enum.map(notes, & &1["title"])
      assert "First" in titles
      assert "Second" in titles
    end

    test "notes include all expected fields", %{conn: conn} do
      {:ok, _} = Notes.create_note(%{title: "Full", body: "content", source: "phoenix"})

      conn = get(conn, ~p"/api/notes")
      %{"notes" => [note]} = json_response(conn, 200)

      assert note["title"] == "Full"
      assert note["body"] == "content"
      assert note["source"] == "phoenix"
      assert note["id"]
      assert note["inserted_at"]
      assert note["updated_at"]
    end

    test "returns all notes from both sources", %{conn: conn} do
      {:ok, _} = Notes.create_note(%{title: "From Phoenix", source: "phoenix"})
      {:ok, _} = Notes.create_note(%{title: "From Django", source: "django"})

      conn = get(conn, ~p"/api/notes")
      %{"notes" => notes} = json_response(conn, 200)

      assert length(notes) == 2
      sources = Enum.map(notes, & &1["source"])
      assert "phoenix" in sources
      assert "django" in sources
    end
  end

  describe "POST /api/notes" do
    test "creates a note with valid params", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/notes", %{title: "New note", body: "Hello"})

      %{"note" => note} = json_response(conn, 201)
      assert note["title"] == "New note"
      assert note["body"] == "Hello"
      assert note["source"] == "phoenix"
      assert note["id"]
    end

    test "always sets source to phoenix", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/notes", %{title: "Test", source: "django"})

      %{"note" => note} = json_response(conn, 201)
      # Controller overrides source to "phoenix"
      assert note["source"] == "phoenix"
    end

    test "creates note without body", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/notes", %{title: "No body"})

      %{"note" => note} = json_response(conn, 201)
      assert note["title"] == "No body"
      assert note["body"] == nil
    end

    test "returns 422 with missing title", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/notes", %{body: "no title"})

      assert json_response(conn, 422)
    end

    test "returns validation errors", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/notes", %{body: "no title"})

      %{"errors" => errors} = json_response(conn, 422)
      assert errors["title"]
    end

    test "persists the note to the database", %{conn: conn} do
      conn
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/notes", %{title: "Persisted"})

      assert [note] = Notes.list_notes()
      assert note.title == "Persisted"
      assert note.source == "phoenix"
    end
  end
end
