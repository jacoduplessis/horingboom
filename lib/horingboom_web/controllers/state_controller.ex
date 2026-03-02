defmodule HoringboomWeb.StateController do
  use HoringboomWeb, :controller

  def index(conn, _params) do
    keys = :hornbeam_state.keys()

    state =
      keys
      |> Enum.map(fn key -> {key, :hornbeam_state.get(key)} end)
      |> Enum.into(%{})

    json(conn, %{state: state})
  end

  def update(conn, %{"key" => key, "value" => value}) do
    :hornbeam_state.set(key, value)

    json(conn, %{key: key, value: value, source: "phoenix"})
  end
end
