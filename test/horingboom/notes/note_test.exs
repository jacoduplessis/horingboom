defmodule Horingboom.Notes.NoteTest do
  use Horingboom.DataCase, async: true

  alias Horingboom.Notes.Note

  describe "changeset/2" do
    test "valid with title and source" do
      changeset = Note.changeset(%Note{}, %{title: "Hello", source: "phoenix"})
      assert changeset.valid?
    end

    test "valid with title, body, and source" do
      changeset = Note.changeset(%Note{}, %{title: "Hello", body: "World", source: "django"})
      assert changeset.valid?
    end

    test "invalid without title" do
      changeset = Note.changeset(%Note{}, %{source: "phoenix"})
      refute changeset.valid?
      assert %{title: ["can't be blank"]} = errors_on(changeset)
    end

    test "invalid without source" do
      changeset = Note.changeset(%Note{}, %{title: "Hello"})
      refute changeset.valid?
      assert %{source: ["can't be blank"]} = errors_on(changeset)
    end

    test "invalid with bad source" do
      changeset = Note.changeset(%Note{}, %{title: "Hello", source: "rails"})
      refute changeset.valid?
      assert %{source: ["is invalid"]} = errors_on(changeset)
    end

    test "accepts phoenix source" do
      changeset = Note.changeset(%Note{}, %{title: "Test", source: "phoenix"})
      assert changeset.valid?
    end

    test "accepts django source" do
      changeset = Note.changeset(%Note{}, %{title: "Test", source: "django"})
      assert changeset.valid?
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
