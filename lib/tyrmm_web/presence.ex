defmodule TyrmmWeb.Presence do
  @moduledoc """
  Tracks who is currently on the site (the lobby page).
  """

  use Phoenix.Presence,
    otp_app: :tyrmm,
    pubsub_server: Tyrmm.PubSub

  @topic "lobby:presence"

  def topic, do: @topic

  def track_player(pid, player_id), do: track(pid, @topic, player_id, %{})

  def online_count, do: @topic |> list() |> map_size()
end
