defmodule HoringboomWeb.DjangoPlug do
  @moduledoc """
  Serves `/django/*` by running the Django WSGI app in hornbeam's Python
  contexts, from the Phoenix request process.

  Since its move to livery, hornbeam only exposes WSGI through its own
  listener, whose handler takes a `livery_req`. This plug does what
  `handle_wsgi/2` in `deps/hornbeam/src/hornbeam_handler.erl` does, starting
  from a `Plug.Conn`: build the request tuple of
  `hornbeam_request:build_wsgi_tuple/2`, call
  `hornbeam_wsgi_worker.handle_request_tuple` and turn the messages Python
  sends back into a response. None of that is public API, so re-check those
  files (and `priv/hornbeam_wsgi_worker.py`) before bumping hornbeam.

  It must run before `Plug.Parsers`, which would otherwise consume the body.
  """

  @behaviour Plug

  import Plug.Conn
  require Logger

  @hop_by_hop ~w(connection keep-alive proxy-authenticate proxy-authorization te trailers transfer-encoding upgrade)

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: ["django" | _]} = conn, _opts) do
    conn |> serve() |> halt()
  end

  def call(conn, _opts), do: conn

  defp serve(conn) do
    config = :hornbeam_config.get_config()

    with {:ok, path_info} <- path_info(conn),
         {:ok, buffer, conn} <- buffer_body(conn) do
      run_wsgi(conn, config, buffer, wsgi_request(conn, path_info))
    else
      {:error, reason} ->
        Logger.warning("Django request rejected: #{inspect(reason)}")
        conn |> put_resp_content_type("text/plain") |> send_resp(400, "Bad Request")
    end
  end

  defp run_wsgi(conn, config, buffer, request) do
    {relay, ref} = start_relay()

    try do
      case :py_nif.context_call(
             :hornbeam_context_pool.get_context_ref(),
             "hornbeam_wsgi_worker",
             "handle_request_tuple",
             [relay, buffer, config.app_module, config.app_callable, request],
             %{}
           ) do
        # "error" means Python already sent {"error", reason}.
        {:ok, done} when done in ["done", "error"] -> await_response(conn, ref, config.timeout)
        {:error, reason} -> internal_error(conn, reason)
      end
    after
      stop_relay(relay, ref)
    end
  end

  # Python replies with untagged messages to whichever pid it is given. A Plug
  # adapter may serve several requests from one process (Bandit does, per
  # keep-alive connection), so a reply that outlives its request would be read
  # as the next one's response. A throwaway relay tags every message with a ref
  # only this request matches.
  defp start_relay do
    parent = self()
    ref = make_ref()

    relay =
      spawn(fn ->
        monitor = Process.monitor(parent)
        relay_loop(parent, ref, monitor)
      end)

    {relay, ref}
  end

  defp relay_loop(parent, ref, monitor) do
    receive do
      {:DOWN, ^monitor, :process, _, _} ->
        :ok

      message ->
        send(parent, {ref, message})
        relay_loop(parent, ref, monitor)
    end
  end

  # The relay's messages to us are ordered before its DOWN, so once DOWN is in
  # nothing tagged with ref can still arrive.
  defp stop_relay(relay, ref) do
    monitor = Process.monitor(relay)
    Process.exit(relay, :kill)

    receive do
      {:DOWN, ^monitor, :process, _, _} -> :ok
    end

    flush(ref)
  end

  defp flush(ref) do
    receive do
      {^ref, _} -> flush(ref)
    after
      0 -> :ok
    end
  end

  defp await_response(conn, ref, timeout) do
    receive do
      {^ref, {"response", status, headers, body}} ->
        conn |> put_django_headers(headers) |> send_resp(status_code(status), body)

      {^ref, {"start_response", status, headers}} ->
        conn
        |> put_django_headers(headers)
        |> send_chunked(status_code(status))
        |> stream_chunks(ref, timeout)

      {^ref, {"error", reason}} ->
        internal_error(conn, reason)
    after
      timeout -> internal_error(conn, :timeout)
    end
  end

  # Headers are already sent, so errors from here on can only end the stream.
  defp stream_chunks(conn, ref, timeout) do
    receive do
      {^ref, {"chunk", data}} ->
        case chunk(conn, data) do
          {:ok, conn} -> stream_chunks(conn, ref, timeout)
          {:error, :closed} -> conn
        end

      {^ref, "done"} ->
        conn

      {^ref, {"error", reason}} ->
        Logger.error("Django response stream failed: #{inspect(reason)}")
        conn
    after
      timeout ->
        Logger.error("Django response stream timed out")
        conn
    end
  end

  defp internal_error(conn, reason) do
    Logger.error("Django request failed: #{inspect(reason)}")
    conn |> put_resp_content_type("text/plain") |> send_resp(500, "Internal Server Error")
  end

  # Mirrors hornbeam_request:build_wsgi_tuple/2.
  defp wsgi_request(conn, path_info) do
    {headers, content_type, content_length} = wsgi_headers(conn.req_headers)
    %{address: _, port: peer_port} = get_peer_data(conn)

    {
      conn.method,
      # SCRIPT_NAME stays empty: demo/urls.py routes include the django/ prefix.
      "",
      path_info,
      conn.query_string,
      headers,
      content_type,
      content_length,
      # The body travels in the py_buffer.
      nil,
      {conn.host, conn.port},
      {conn.remote_ip |> :inet.ntoa() |> to_string(), peer_port},
      to_string(conn.scheme),
      to_string(get_http_protocol(conn)),
      :hornbeam_lifespan.get_state()
    }
  end

  # PEP 3333 wants PATH_INFO percent-decoded, as a str whose code points are
  # the raw bytes (Django re-encodes it as latin-1, then decodes UTF-8).
  # erlang_python decodes binaries as UTF-8, so widen each byte first.
  defp path_info(conn) do
    {:ok, conn.request_path |> URI.decode() |> :unicode.characters_to_binary(:latin1, :utf8)}
  rescue
    ArgumentError -> {:error, :malformed_path}
  end

  # Mirrors hornbeam_request:convert_headers_wsgi/1.
  defp wsgi_headers(req_headers) do
    Enum.reduce(req_headers, {%{}, nil, nil}, fn
      {"content-type", value}, {acc, _, length} ->
        {acc, value, length}

      {"content-length", value}, {acc, type, _} ->
        {acc, type, value}

      {name, value}, {acc, type, length} ->
        key = "HTTP_" <> (name |> String.upcase() |> String.replace("-", "_"))
        {Map.update(acc, key, value, &(&1 <> ", " <> value)), type, length}
    end)
  end

  # The whole body goes into the buffer, closed, before Python starts, so a
  # Django read never waits on us. Bodyless requests get an empty buffer too:
  # hornbeam's marker for them, the atom `empty`, reaches Python as a str its
  # worker doesn't recognise (it checks b'empty'), and Django would get the
  # str as wsgi.input.
  defp buffer_body(conn) do
    {:ok, buffer} = :py_buffer.new(content_length(conn))
    result = copy_body(conn, buffer)
    :ok = :py_buffer.close(buffer)

    with {:ok, conn} <- result, do: {:ok, buffer, conn}
  end

  defp copy_body(conn, buffer) do
    case read_body(conn) do
      {:ok, data, conn} ->
        write_chunk(buffer, data)
        {:ok, conn}

      {:more, data, conn} ->
        write_chunk(buffer, data)
        copy_body(conn, buffer)

      {:error, reason} ->
        {:error, {:body_read_failed, reason}}
    end
  end

  defp write_chunk(_buffer, ""), do: :ok
  defp write_chunk(buffer, data), do: :ok = :py_buffer.write(buffer, data)

  defp content_length(conn) do
    with [value] <- get_req_header(conn, "content-length"),
         {length, ""} <- Integer.parse(value) do
      length
    else
      _ -> :undefined
    end
  end

  # Django's headers replace Phoenix defaults of the same name (cache-control)
  # but may repeat among themselves (set-cookie), which put_resp_header can't do.
  defp put_django_headers(conn, headers) do
    headers =
      headers
      |> Enum.map(&header_pair/1)
      |> Enum.reject(fn {name, _} -> name in @hop_by_hop end)

    headers
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> Enum.reduce(conn, &delete_resp_header(&2, &1))
    |> prepend_resp_headers(headers)
  end

  defp header_pair({name, value}),
    do: {name |> to_string() |> String.downcase(), to_string(value)}

  defp header_pair([name, value]), do: header_pair({name, value})

  defp status_code(code) when is_integer(code), do: code

  defp status_code(status) when is_binary(status) do
    status |> String.split(" ", parts: 2) |> hd() |> String.to_integer()
  end
end
