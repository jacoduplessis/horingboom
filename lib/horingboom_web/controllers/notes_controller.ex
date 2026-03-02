defmodule HoringboomWeb.NotesController do
  use HoringboomWeb, :controller

  alias Horingboom.Notes

  def index(conn, _params) do
    notes =
      Notes.list_notes()
      |> Enum.map(&note_to_map/1)

    json(conn, %{notes: notes})
  end

  def create(conn, params) do
    case Notes.create_note(Map.put(params, "source", "phoenix")) do
      {:ok, note} ->
        conn
        |> put_status(:created)
        |> json(%{note: note_to_map(note)})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  defp note_to_map(note) do
    %{
      id: note.id,
      title: note.title,
      body: note.body,
      source: note.source,
      inserted_at: note.inserted_at,
      updated_at: note.updated_at
    }
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
