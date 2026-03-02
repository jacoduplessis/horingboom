defmodule HoringboomWeb.ErrorJSONTest do
  use HoringboomWeb.ConnCase, async: true

  test "renders 404" do
    assert HoringboomWeb.ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
  end

  test "renders 500" do
    assert HoringboomWeb.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end
end
