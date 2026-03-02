defmodule Horingboom.Notes.Note do
  use Ecto.Schema
  import Ecto.Changeset

  schema "notes" do
    field :title, :string
    field :body, :string
    field :source, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(note, attrs) do
    note
    |> cast(attrs, [:title, :body, :source])
    |> validate_required([:title, :source])
    |> validate_inclusion(:source, ["phoenix", "django"])
  end
end
