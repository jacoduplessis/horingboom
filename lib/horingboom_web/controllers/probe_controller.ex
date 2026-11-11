defmodule HoringboomWeb.ProbeController do
  @moduledoc false
  # Exercises each Plug.Conn.Adapter callback for the livery adapter tests.

  use HoringboomWeb, :controller

  def chunked(conn, _params) do
    conn = send_chunked(conn, 200)

    Enum.reduce(1..3, conn, fn i, conn ->
      {:ok, conn} = chunk(conn, "chunk#{i}\n")
      conn
    end)
  end

  def echo_body(conn, _params) do
    {body, conn} = read_all(conn, [])

    json(conn, %{
      bytes: byte_size(body),
      sha256: Base.encode16(:crypto.hash(:sha256, body), case: :lower)
    })
  end

  defp read_all(conn, acc) do
    case read_body(conn, length: 100_000, read_length: 10_000) do
      {:ok, data, conn} -> {IO.iodata_to_binary(Enum.reverse([data | acc])), conn}
      {:more, data, conn} -> read_all(conn, [data | acc])
    end
  end

  def file(conn, %{"offset" => offset, "length" => length}) do
    path = Application.app_dir(:horingboom, "priv/static/robots.txt")
    send_file(conn, 200, path, String.to_integer(offset), String.to_integer(length))
  end

  def inform(conn, _params) do
    conn
    |> inform!(103, [{"link", "</images/logo.svg>; rel=preload"}])
    |> text("after early hints")
  end

  def peer(conn, _params) do
    peer = get_peer_data(conn)

    json(conn, %{
      address: peer.address |> :inet.ntoa() |> to_string(),
      port: peer.port,
      protocol: get_http_protocol(conn),
      host: conn.host,
      port_from_host: conn.port,
      request_path: conn.request_path,
      query: conn.query_string
    })
  end

  def boom(_conn, _params), do: raise("probe boom")
end
