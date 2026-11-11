defmodule LiveryPlug.Conn do
  @moduledoc """
  `Plug.Conn.Adapter` over a livery request.

  Livery handlers normally *return* a `#livery_resp{}` that livery then
  writes. Plug is imperative (`send_resp/3`, `send_chunked/2` + `chunk/2`), so
  this adapter writes through the livery adapter of the request directly —
  `livery:emit/3` for whole responses, `send_headers`/`send_data` for chunked
  ones — and `LiveryPlug.Handler` hands livery the `taken_over` sentinel when
  the pipeline returns. Everything runs in livery's per-request process.
  """

  @behaviour Plug.Conn.Adapter

  require Logger

  @file_chunk 65_536

  @doc "Builds the `%Plug.Conn{}` for a livery request."
  def conn(req, server_port) do
    payload = %{
      req: req,
      adapter: :livery_req.adapter(req),
      stream: :livery_req.stream(req),
      method: :livery_req.method(req),
      body: initial_body(:livery_req.body(req)),
      upgrade: nil,
      server_port: server_port
    }

    scheme = :livery_req.scheme(req)
    {host, port} = host_and_port(req, scheme, server_port)
    {remote_ip, _} = peer(req)

    uri = %URI{
      scheme: scheme,
      host: host,
      port: port,
      # livery keeps only the percent-decoded path; Plug expects the raw one.
      # Re-encoding is lossy for an encoded "/" (%2F) — see the report.
      path: URI.encode(:livery_req.path(req)),
      query: :livery_req.query(req)
    }

    Plug.Conn.Adapter.conn(
      {__MODULE__, payload},
      payload.method,
      uri,
      remote_ip,
      :livery_req.headers(req)
    )
  end

  defp peer(req) do
    case :livery_req.peer(req) do
      :undefined -> {{127, 0, 0, 1}, 0}
      peer -> peer
    end
  end

  defp initial_body(:empty), do: :done
  defp initial_body({:buffered, data}), do: {:buffered, IO.iodata_to_binary(data)}
  defp initial_body({:stream, reader}), do: {:stream, reader, ""}

  defp host_and_port(req, scheme, server_port) do
    authority =
      case :livery_req.header("host", req) do
        :undefined -> :livery_req.authority(req)
        host -> host
      end

    default = server_port || if(scheme == "https", do: 443, else: 80)

    case authority do
      "" ->
        {"localhost", default}

      _ ->
        case URI.parse("//" <> authority) do
          %URI{host: host, port: nil} -> {host, default}
          %URI{host: host, port: port} -> {host, port}
        end
    end
  end

  ## Responses

  @impl true
  def send_resp(%{method: "HEAD"} = payload, status, headers, body) do
    # h2/h3 refuse a body on a HEAD stream; h1 drops it. Send headers only.
    headers = put_new_header(headers, "content-length", Integer.to_string(IO.iodata_length(body)))
    emit(payload, status, headers, :empty)
    sent(payload)
  end

  def send_resp(payload, status, headers, body) do
    emit(payload, status, headers, {:full, body})
    sent(payload)
  end

  @impl true
  def send_file(payload, status, headers, path, 0, :all) do
    emit(payload, status, headers, {:file, path, :undefined})
    sent(payload)
  end

  # livery's ranged file body adds its own content-range, which Plug callers
  # (Plug.Static) have already set, so stream ranges here.
  def send_file(payload, status, headers, path, offset, length) do
    length = if length == :all, do: File.stat!(path).size - offset, else: length
    headers = put_new_header(headers, "content-length", Integer.to_string(length))

    with :ok <- send_headers(payload, status, headers, length == 0) do
      File.open!(path, [:read, :raw, :binary], &stream_file(payload, &1, offset, length))
    end

    sent(payload)
  end

  defp stream_file(_payload, _io, _offset, 0), do: :ok

  defp stream_file(payload, io, offset, remaining) do
    {:ok, data} = :file.pread(io, offset, min(remaining, @file_chunk))
    left = remaining - byte_size(data)

    case send_data(payload, data, left == 0) do
      :ok -> stream_file(payload, io, offset + byte_size(data), left)
      error -> error
    end
  end

  @impl true
  def send_chunked(payload, status, headers) do
    send_headers(payload, status, headers, false)
    sent(payload)
  end

  @impl true
  def chunk(payload, body) do
    case send_data(payload, body, false) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Plug no longer sets conn.owner, so the adapter tells the request process
  # a response went out (Phoenix's render_errors and LiveryPlug.Handler check).
  defp sent(payload) do
    send(self(), Plug.Conn.Adapter.already_sent())
    {:ok, nil, payload}
  end

  @doc "Ends a chunked response once the pipeline has returned."
  def finish_chunked(payload), do: send_data(payload, "", true)

  defp emit(payload, status, headers, body) do
    case :livery.emit(payload.adapter, payload.stream, :livery_resp.new(status, headers, body)) do
      :ok -> :ok
      {:error, reason} -> Logger.debug("livery emit failed: #{inspect(reason)}")
    end
  end

  defp send_headers(payload, status, headers, end_stream?) do
    payload.adapter.send_headers(payload.stream, status, headers, %{end_stream: end_stream?})
  end

  defp send_data(payload, data, end_stream?) do
    payload.adapter.send_data(payload.stream, data, %{end_stream: end_stream?})
  end

  defp put_new_header(headers, name, value) do
    if List.keymember?(headers, name, 0), do: headers, else: [{name, value} | headers]
  end

  ## Request body

  @impl true
  def read_req_body(payload, opts) do
    length = Keyword.get(opts, :length, 8_000_000)
    timeout = Keyword.get(opts, :read_timeout, 15_000)

    case payload.body do
      :done ->
        {:ok, "", payload}

      {:buffered, data} when byte_size(data) <= length ->
        {:ok, data, %{payload | body: :done}}

      {:buffered, data} ->
        <<part::binary-size(^length), rest::binary>> = data
        {:more, part, %{payload | body: {:buffered, rest}}}

      {:stream, reader, pending} ->
        read_stream(payload, reader, pending, length, timeout)
    end
  end

  defp read_stream(payload, reader, acc, length, _timeout) when byte_size(acc) >= length do
    <<part::binary-size(^length), rest::binary>> = acc
    {:more, part, %{payload | body: {:stream, reader, rest}}}
  end

  defp read_stream(payload, reader, acc, length, timeout) do
    case :livery_body.read(reader, timeout) do
      {:ok, chunk, reader} ->
        read_stream(payload, reader, acc <> IO.iodata_to_binary(chunk), length, timeout)

      {:done, _reader} ->
        {:ok, acc, %{payload | body: :done}}

      {:error, reason, _reader} ->
        {:error, reason}
    end
  end

  ## Everything else

  @impl true
  def inform(payload, status, headers) do
    case :livery_req.inform(
           status,
           Enum.map(headers, fn {k, v} -> {to_string(k), v} end),
           payload.req
         ) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Recorded here; LiveryPlug.Handler performs it once the pipeline returns,
  # the way Bandit does.
  @impl true
  def upgrade(payload, :websocket, args), do: {:ok, %{payload | upgrade: {:websocket, args}}}
  def upgrade(_payload, _protocol, _args), do: {:error, :not_supported}

  @impl true
  def push(_payload, _path, _headers), do: {:error, :not_supported}

  @impl true
  def get_peer_data(payload) do
    {address, port} = peer(payload.req)
    %{address: address, port: port, ssl_cert: nil}
  end

  # livery_req exposes no local address; report the listener port.
  @impl true
  def get_sock_data(payload), do: %{address: {0, 0, 0, 0}, port: payload.server_port}

  @impl true
  def get_ssl_data(payload) do
    case :livery_req.tls(payload.req) do
      :undefined -> nil
      info -> info
    end
  end

  @impl true
  def get_http_protocol(payload) do
    case :livery_req.protocol(payload.req) do
      :h1 -> :"HTTP/1.1"
      :h2 -> :"HTTP/2"
      :h3 -> :"HTTP/3"
    end
  end
end
