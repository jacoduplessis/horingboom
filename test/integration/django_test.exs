defmodule Horingboom.Integration.DjangoTest do
  use Horingboom.IntegrationCase

  @moduletag :integration

  describe "GET /django/" do
    test "returns hello message with view count" do
      %{status: 200, body: body} = Req.get!("#{@django_url}/django/")

      assert body["message"] =~ "Hello from Django"
      assert body["path"] == "/django/"
      assert is_integer(body["view_count"])
    end
  end

  describe "GET /django/info/" do
    test "returns Python runtime info" do
      %{status: 200, body: body} = Req.get!("#{@django_url}/django/info/")

      assert body["message"] =~ "Python runtime info"
      assert body["python_version"] =~ "3.14"
      assert body["implementation"] == "CPython"
      assert body["platform"]
    end

    test "executable is not a standalone Python" do
      %{body: body} = Req.get!("#{@django_url}/django/info/")

      # On macOS the embedded interpreter reports beam.smp as the executable;
      # on Linux it may resolve to the Python binary via PYTHONHOME.
      # Either way it should NOT be empty.
      assert body["executable"]
    end
  end

  describe "GET /django/call-elixir/" do
    test "calls registered Elixir functions" do
      %{status: 200, body: body} = Req.get!("#{@django_url}/django/call-elixir/")

      assert body["message"] =~ "Called registered Elixir functions"
      assert body["greeting"] =~ "Hello World, from Elixir"
      assert body["system_info"]["otp_release"]
      assert body["system_info"]["elixir_version"] == System.version()
    end

    test "passes name parameter to greeting" do
      %{body: body} = Req.get!("#{@django_url}/django/call-elixir/?name=Django")

      assert body["greeting"] =~ "Hello Django"
    end
  end

  describe "GET /django/shared-state/" do
    test "writes and reads ETS state from Django" do
      %{status: 200, body: body} = Req.get!("#{@django_url}/django/shared-state/")

      assert body["message"] =~ "Shared ETS state"
      assert body["written_value"]["written_by"] == "Django"
      assert is_integer(body["shared_counter"])
    end

    test "Django-written state is visible from Elixir" do
      Req.get!("#{@django_url}/django/shared-state/")

      value = :hornbeam_state.get("django:demo_key")
      assert value["written_by"] == "Django"
    end
  end

  describe "GET /django/notes/" do
    test "returns empty notes list" do
      %{status: 200, body: body} = Req.get!("#{@django_url}/django/notes/")

      assert body["notes"] == []
    end
  end

  describe "POST /django/notes/" do
    test "creates a note with source=django" do
      %{status: 201, body: body} =
        Req.post!("#{@django_url}/django/notes/",
          json: %{title: "Django note", body: "hello"}
        )

      note = body["note"]
      assert note["title"] == "Django note"
      assert note["body"] == "hello"
      assert note["source"] == "django"
      assert note["id"]
      assert note["inserted_at"]
    end

    test "created note appears in GET" do
      Req.post!("#{@django_url}/django/notes/", json: %{title: "Visible"})

      %{body: body} = Req.get!("#{@django_url}/django/notes/")
      titles = Enum.map(body["notes"], & &1["title"])
      assert "Visible" in titles
    end
  end
end
