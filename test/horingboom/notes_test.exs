defmodule Horingboom.NotesTest do
  use Horingboom.DataCase, async: true

  alias Horingboom.Notes
  alias Horingboom.Notes.Note

  describe "list_notes/0" do
    test "returns empty list when no notes exist" do
      assert Notes.list_notes() == []
    end

    test "returns all created notes" do
      {:ok, _} = Notes.create_note(%{title: "First", source: "phoenix"})
      {:ok, _} = Notes.create_note(%{title: "Second", source: "django"})

      notes = Notes.list_notes()
      assert length(notes) == 2
      titles = Enum.map(notes, & &1.title)
      assert "First" in titles
      assert "Second" in titles
    end

    test "returns notes from both sources" do
      {:ok, _} = Notes.create_note(%{title: "Phoenix note", source: "phoenix"})
      {:ok, _} = Notes.create_note(%{title: "Django note", source: "django"})

      notes = Notes.list_notes()
      sources = Enum.map(notes, & &1.source)
      assert "phoenix" in sources
      assert "django" in sources
    end
  end

  describe "create_note/1" do
    test "creates a note with valid attrs" do
      assert {:ok, %Note{} = note} =
               Notes.create_note(%{title: "Test", body: "Body", source: "phoenix"})

      assert note.title == "Test"
      assert note.body == "Body"
      assert note.source == "phoenix"
      assert note.id
      assert note.inserted_at
      assert note.updated_at
    end

    test "creates a note without body" do
      assert {:ok, %Note{} = note} = Notes.create_note(%{title: "No body", source: "django"})
      assert note.body == nil
    end

    test "returns error changeset with missing title" do
      assert {:error, %Ecto.Changeset{}} = Notes.create_note(%{source: "phoenix"})
    end

    test "returns error changeset with missing source" do
      assert {:error, %Ecto.Changeset{}} = Notes.create_note(%{title: "No source"})
    end

    test "returns error changeset with invalid source" do
      assert {:error, %Ecto.Changeset{}} =
               Notes.create_note(%{title: "Bad", source: "express"})
    end

    test "works with string keys" do
      assert {:ok, %Note{} = note} =
               Notes.create_note(%{"title" => "String keys", "source" => "phoenix"})

      assert note.title == "String keys"
    end
  end
end
