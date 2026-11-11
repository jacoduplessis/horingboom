defmodule Horingboom.Integration.LiveryAdapterTest.WsClient do
  @moduledoc false
  # erlang_ws client handler that forwards frames to the test process.
  @behaviour :ws_handler

  @impl true
  def init(_req, %{parent: parent}), do: {:ok, parent}

  @impl true
  def handle_in(frame, parent) do
    send(parent, {:ws_in, frame})
    {:ok, parent}
  end

  @impl true
  def handle_info({:send, frame}, parent), do: {:reply, frame, parent}
end

defmodule Horingboom.Integration.LiveryAdapterTest do
  use Horingboom.IntegrationCase

  @moduletag :integration

  @robots Path.expand("../../priv/static/robots.txt", __DIR__)

  test "chunked response streams every chunk" do
    resp = Req.get!("#{@django_url}/probe/chunked")

    assert resp.status == 200
    assert resp.body == "chunk1\nchunk2\nchunk3\n"
    assert Req.Response.get_header(resp, "transfer-encoding") == ["chunked"]
  end

  test "large request body is read across many read_body calls" do
    body = :crypto.strong_rand_bytes(3_000_000)

    %{status: 200, body: echo} =
      Req.post!("#{@django_url}/probe/echo",
        body: body,
        headers: [{"content-type", "application/octet-stream"}]
      )

    assert echo["bytes"] == byte_size(body)
    assert echo["sha256"] == Base.encode16(:crypto.hash(:sha256, body), case: :lower)
  end

  # Req drops content-length from decoded responses and returns a 1xx as the
  # final response, so these read the wire.
  defp raw_get(path) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", 4012, [:binary, active: false])

    :ok =
      :gen_tcp.send(
        socket,
        "GET #{path} HTTP/1.1\r\nhost: 127.0.0.1:4012\r\nconnection: close\r\n\r\n"
      )

    recv_all(socket, "")
  end

  defp recv_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} -> recv_all(socket, acc <> data)
      {:error, :closed} -> acc
    end
  end

  test "static files go out whole through livery's file body" do
    robots = File.read!(@robots)
    [head, body] = "/robots.txt" |> raw_get() |> String.split("\r\n\r\n", parts: 2)

    assert head =~ "HTTP/1.1 200 OK"
    assert head =~ "content-length: #{byte_size(robots)}"
    assert body == robots
  end

  test "ranged send_file sends exactly the requested bytes" do
    [head, body] =
      "/probe/file?offset=2&length=5" |> raw_get() |> String.split("\r\n\r\n", parts: 2)

    assert head =~ "content-length: 5"
    refute head =~ "content-range"
    assert body == binary_part(File.read!(@robots), 2, 5)
  end

  test "inform sends a 103 before the final response" do
    response = raw_get("/probe/inform")

    assert response =~
             ~r{\AHTTP/1.1 103 Early Hints\r\nlink: </images/logo.svg>; rel=preload\r\n\r\nHTTP/1.1 200 OK}

    assert response =~ "after early hints"
  end

  test "an error page sent before a re-raise is not followed by livery's own 500" do
    response = raw_get("/probe/boom")

    assert response =~ "HTTP/1.1 500"
    refute response =~ "internal server error"
  end

  test "peer, protocol, host and raw query reach the conn" do
    %{body: body} = Req.get!("#{@django_url}/probe/peer?a=1&b=x%20y")

    assert body["address"] == "127.0.0.1"
    assert is_integer(body["port"]) and body["port"] > 0
    assert body["protocol"] == "HTTP/1.1"
    assert body["host"] == "127.0.0.1"
    assert body["port_from_host"] == 4012
    assert body["request_path"] == "/probe/peer"
    assert body["query"] == "a=1&b=x%20y"
  end

  test "HEAD answers headers only, with the GET body's length" do
    get = Req.get!("#{@django_url}/api/notes", decode_body: false)
    head = Req.head!("#{@django_url}/api/notes")

    assert head.status == 200
    assert head.body == ""
    assert Req.Response.get_header(head, "content-length") == ["#{byte_size(get.body)}"]
  end

  test "an error page sent before a re-raise is the only response on the connection" do
    for _ <- 1..3 do
      assert %{status: 500} = Req.get!("#{@django_url}/probe/boom", retry: false)
      assert %{status: 200, body: %{"notes" => []}} = Req.get!("#{@django_url}/api/notes")
    end
  end

  test "Django still gets bodies over hornbeam's 64 KB streaming threshold" do
    big = String.duplicate("x", 200_000)

    %{status: 201, body: %{"note" => note}} =
      Req.post!("#{@django_url}/django/notes/", json: %{title: "big", body: big})

    assert byte_size(note["body"]) == 200_000
  end

  describe "LiveView socket over livery_ws" do
    setup do
      {:ok, client} =
        :ws_client.connect("ws://127.0.0.1:4012/live/websocket?vsn=2.0.0", %{
          handler: Horingboom.Integration.LiveryAdapterTest.WsClient,
          handler_opts: %{parent: self()}
        })

      %{client: client}
    end

    test "heartbeat round-trips through WebSock handle_in", %{client: client} do
      send(client, {:send, {:text, ~s([null,"1","phoenix","heartbeat",{}])}})

      assert_receive {:ws_in, {:text, reply}}, 2_000

      assert Jason.decode!(reply) == [
               nil,
               "1",
               "phoenix",
               "phx_reply",
               %{"status" => "ok", "response" => %{}}
             ]
    end

    test "a channel process's reply arrives through WebSock handle_info", %{client: client} do
      send(
        client,
        {:send,
         {:text,
          ~s(["1","1","lv:probe","phx_join",{"url":"http://127.0.0.1:4012/","session":"bogus"}])}}
      )

      assert_receive {:ws_in, {:text, reply}}, 2_000
      assert ["1", "1", "lv:probe", "phx_reply", %{"status" => "error"}] = Jason.decode!(reply)
    end
  end
end
