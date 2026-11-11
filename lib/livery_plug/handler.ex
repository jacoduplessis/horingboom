defmodule LiveryPlug.Handler do
  @moduledoc """
  livery handler that runs a Plug in livery's per-request process.

  `LiveryPlug.Conn` writes the response while the pipeline runs, so what this
  returns to livery is the `taken_over` sentinel (with the real status, for
  livery's metrics), a WebSocket upgrade, or — if the plug raised before
  sending anything — the exception, which livery turns into a 500.
  """

  require Logger

  def handle(req, plug, plug_opts, server_port) do
    conn = LiveryPlug.Conn.conn(req, server_port)

    try do
      plug.call(conn, plug_opts)
    catch
      kind, reason ->
        # Phoenix's render_errors (and Plug.Debugger) send the error page and
        # then re-raise. livery would answer a crash with a second 500 on the
        # same stream, so once a response is out, log and stop here.
        receive do
          {:plug_conn, :sent} ->
            log_after_send(kind, reason, __STACKTRACE__)
            taken_over(500)
        after
          0 -> :erlang.raise(kind, reason, __STACKTRACE__)
        end
    else
      conn -> finish(req, conn)
    end
  end

  defp finish(req, %Plug.Conn{state: :upgraded, adapter: {_, %{upgrade: {:websocket, args}}}}) do
    {websock, websock_state, opts} = args

    :livery_ws.upgrade(
      req,
      LiveryPlug.WebSockHandler,
      LiveryPlug.WebSockHandler.opts(websock, websock_state, opts)
    )
  end

  defp finish(_req, %Plug.Conn{state: :chunked, status: status, adapter: {_, payload}}) do
    LiveryPlug.Conn.finish_chunked(payload)
    taken_over(status)
  end

  defp finish(_req, %Plug.Conn{state: state, status: status}) when state in [:sent, :file] do
    taken_over(status)
  end

  defp finish(_req, %Plug.Conn{state: state}) do
    raise "Plug did not send a response (conn state: #{inspect(state)})"
  end

  defp taken_over(status), do: :livery_resp.new(status, [], :taken_over)

  defp log_after_send(kind, reason, stacktrace) do
    exception = Exception.normalize(kind, reason, stacktrace)

    if Plug.Exception.status(exception) >= 500 do
      Logger.error(Exception.format(kind, exception, stacktrace))
    end
  end
end
