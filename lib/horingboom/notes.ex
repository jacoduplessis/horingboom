defmodule Horingboom.Notes do
  import Ecto.Query

  alias Horingboom.Repo
  alias Horingboom.Notes.Note

  def list_notes do
    Note |> order_by(desc: :inserted_at) |> Repo.all()
  end

  def create_note(attrs) do
    %Note{}
    |> Note.changeset(attrs)
    |> Repo.insert()
  end
end
