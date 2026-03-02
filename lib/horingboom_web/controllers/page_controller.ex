defmodule HoringboomWeb.PageController do
  use HoringboomWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
