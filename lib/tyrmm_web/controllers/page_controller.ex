defmodule TyrmmWeb.PageController do
  use TyrmmWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
