defmodule LiveryPlug.WebSockHandler do
  @moduledoc """
  `ws_handler` (erlang_ws, used by `livery_ws`) that runs a `WebSock` module.

  The session runs in its own `ws_session` process, not the request process
  the Plug pipeline ran in (cowboy and Bandit keep the same process).
  """

  @behaviour :ws_handler

  @doc "livery_ws upgrade opts for a WebSock module, its state and WebSock options."
  def opts(websock, state, websock_opts) do
    base = %{websock: {websock, state}}

    Enum.reduce(websock_opts, base, fn
      {:timeout, timeout}, acc -> Map.put(acc, :idle_timeout, timeout)
      {:compress, compress}, acc -> Map.put(acc, :compress, compress)
      {:max_frame_size, size}, acc -> Map.put(acc, :max_frame_size, size)
      _, acc -> acc
    end)
  end

  @impl true
  def init(_req, %{websock: {websock, state}}), do: websock.init(state) |> reply(websock)

  @impl true
  def handle_in({:text, data}, {websock, state}),
    do: websock.handle_in({data, opcode: :text}, state) |> reply(websock)

  def handle_in({:binary, data}, {websock, state}),
    do: websock.handle_in({data, opcode: :binary}, state) |> reply(websock)

  def handle_in({opcode, data}, {websock, state}) when opcode in [:ping, :pong] do
    if function_exported?(websock, :handle_control, 2) do
      websock.handle_control({data, opcode: opcode}, state) |> reply(websock)
    else
      {:ok, {websock, state}}
    end
  end

  def handle_in(_close, {websock, state}), do: {:stop, :normal, {websock, state}}

  @impl true
  def handle_info(message, {websock, state}),
    do: websock.handle_info(message, state) |> reply(websock)

  @impl true
  def terminate(reason, {websock, state}) do
    if function_exported?(websock, :terminate, 2),
      do: websock.terminate(websock_reason(reason), state)

    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp reply({:ok, state}, websock), do: {:ok, {websock, state}}
  defp reply({:push, frames, state}, websock), do: {:reply, frames, {websock, state}}
  defp reply({:reply, _status, frames, state}, websock), do: {:reply, frames, {websock, state}}
  defp reply({:stop, reason, state}, websock), do: {:stop, reason, {websock, state}}
  # ws_handler can't send a close code with stop; the session closes with 1000.
  defp reply({:stop, reason, _close_detail, state}, websock),
    do: {:stop, reason, {websock, state}}

  defp reply({:stop, reason, _close_detail, _frames, state}, websock),
    do: {:stop, reason, {websock, state}}

  defp websock_reason({:remote, _code, _reason}), do: :remote
  defp websock_reason(:remote), do: :remote
  defp websock_reason(:normal), do: :normal
  defp websock_reason(:shutdown), do: :shutdown
  defp websock_reason(:timeout), do: :timeout
  defp websock_reason(other), do: {:error, other}
end
