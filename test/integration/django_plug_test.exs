defmodule Horingboom.Integration.DjangoPlugTest do
  use Horingboom.IntegrationCase

  @moduletag :integration

  describe "requests" do
    test "PATH_INFO is percent-decoded before Django routes it" do
      assert %{status: 200} = Req.get!("#{@django_url}/django/%69nfo/")
    end

    test "a body over hornbeam's 64KB streaming threshold reaches Django intact" do
      body = String.duplicate("x", 200_000)

      %{status: 201, body: resp} =
        Req.post!("#{@django_url}/django/notes/", json: %{title: "big", body: body})

      assert resp["note"]["body"] == body
    end
  end

  describe "responses" do
    test "Django's status and headers pass through" do
      %{status: 405, headers: headers} = Req.put!("#{@django_url}/django/notes/")

      assert headers["allow"] == ["GET, POST"]
    end

    test "a streaming response is sent chunked" do
      %{status: 200, body: body, headers: headers} = Req.get!("#{@django_url}/django/stream/")

      assert body == "chunk 0\nchunk 1\nchunk 2\n"
      assert headers["transfer-encoding"] == ["chunked"]
    end

    test "Django requests go through the Phoenix endpoint pipeline" do
      %{headers: headers} = Req.get!("#{@django_url}/django/info/")

      assert [_request_id] = headers["x-request-id"]
    end
  end
end
