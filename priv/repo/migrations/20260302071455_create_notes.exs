defmodule Horingboom.Repo.Migrations.CreateNotes do
  use Ecto.Migration

  def change do
    create table(:notes) do
      add :title, :string, null: false
      add :body, :text
      add :source, :string, null: false

      timestamps(type: :utc_datetime)
    end
  end
end
