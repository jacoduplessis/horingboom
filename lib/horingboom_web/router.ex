defmodule HoringboomWeb.Router do
  use HoringboomWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {HoringboomWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", HoringboomWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  scope "/api", HoringboomWeb do
    pipe_through :api

    get "/notes", NotesController, :index
    post "/notes", NotesController, :create

    get "/state", StateController, :index
    put "/state/:key", StateController, :update
  end
end
