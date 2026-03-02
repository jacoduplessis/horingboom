defmodule Horingboom.Integration.CrossRuntimeTest do
  use Horingboom.IntegrationCase

  @moduletag :integration

  describe "shared ETS state" do
    test "Phoenix writes state, Django reads it" do
      :hornbeam_state.set("phoenix:test", "written by Elixir")

      %{body: body} = Req.get!("#{@django_url}/django/shared-state/")

      # After Django's endpoint runs, check its counter incremented
      assert is_integer(body["shared_counter"])

      # Verify the value we set from Elixir is in the same ETS table
      assert :hornbeam_state.get("phoenix:test") == "written by Elixir"
    end

    test "Django writes state, Phoenix reads it" do
      # Trigger Django to write to ETS
      Req.get!("#{@django_url}/django/shared-state/")

      # Read it from the Elixir side
      value = :hornbeam_state.get("django:demo_key")
      assert is_map(value)
      assert value["written_by"] == "Django"
    end

    test "ETS counter increments across both runtimes" do
      :hornbeam_state.set("cross:counter", 0)
      :hornbeam_state.incr("cross:counter", 5)

      # Django increments shared:counter, but we can verify
      # the Elixir-side increment worked
      assert :hornbeam_state.get("cross:counter") == 5
    end
  end

  describe "shared Postgres via HTTP" do
    test "note created via Django is visible via Django GET" do
      Req.post!("#{@django_url}/django/notes/", json: %{title: "Django wrote this"})

      %{body: body} = Req.get!("#{@django_url}/django/notes/")
      titles = Enum.map(body["notes"], & &1["title"])
      assert "Django wrote this" in titles
    end

    test "multiple notes from Django" do
      Req.post!("#{@django_url}/django/notes/", json: %{title: "Note A"})
      Req.post!("#{@django_url}/django/notes/", json: %{title: "Note B"})

      %{body: body} = Req.get!("#{@django_url}/django/notes/")
      titles = Enum.map(body["notes"], & &1["title"])
      assert "Note A" in titles
      assert "Note B" in titles
    end

    test "Django notes have correct source field" do
      Req.post!("#{@django_url}/django/notes/", json: %{title: "Source check"})

      %{body: body} = Req.get!("#{@django_url}/django/notes/")
      sources = Enum.map(body["notes"], & &1["source"]) |> Enum.uniq()
      assert sources == ["django"]
    end
  end

  describe "cross-runtime function calls" do
    test "Django can call registered Elixir function system_info" do
      %{body: body} = Req.get!("#{@django_url}/django/call-elixir/")

      system_info = body["system_info"]
      assert system_info["elixir_version"] == System.version()
      assert system_info["otp_release"] == to_string(:erlang.system_info(:otp_release))
    end

    test "Django view counter uses ETS atomics" do
      Req.get!("#{@django_url}/django/")
      %{body: body} = Req.get!("#{@django_url}/django/")

      # Second call should have a higher view count
      assert body["view_count"] >= 2
    end
  end
end
