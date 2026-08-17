defmodule TyrmmWeb.LobbyLiveTest do
  use TyrmmWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tyrmm.Lobbies

  defp sim_player(id, name) do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    :ok = Lobbies.register(id, pid)
    :ok = Lobbies.set_name(id, name)
    {id, pid}
  end

  defp cleanup(ids) do
    on_exit(fn ->
      Enum.each(ids, fn id ->
        Lobbies.leave_lobby(id)
        Lobbies.close_lobby(id)
      end)
    end)
  end

  test "renders the lobby list and auto-assigns a random callsign", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")

    assert html =~ "On site"
    assert html =~ "Lobbies"

    # once connected, a random callsign is assigned and shown in the identity bar
    assert render(view) =~ "Callsign"
    assert render(view) =~ ~r/value="[A-Z][a-z]+[A-Z][a-z]+\d\d"/
  end

  test "players can rename to any name", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    html =
      view |> form("form[phx-submit=set_name]", %{"name" => "xX_slayer_Xx"}) |> render_submit()

    assert html =~ "xX_slayer_Xx"
  end

  test "hosting: lobby appears, code visible to host only, host can't double-book", %{conn: conn} do
    cleanup(["outsider_h"])

    {:ok, view, _html} = live(conn, "/")
    view |> form("form[phx-submit=set_name]", %{"name" => "Host"}) |> render_submit()

    html =
      view
      |> form("form[phx-submit=create_lobby]", %{"code" => "abc123", "region" => "na"})
      |> render_submit()

    # host sees the room UI with the normalized code
    assert html =~ "Your lobby"
    assert html =~ "ABC123"

    # outsiders see the lobby but not the code
    sim_player("outsider_h", "Outsider")
    lobby = Enum.find(Lobbies.snapshot("outsider_h").lobbies, &(&1.host == "Host"))
    assert lobby.code == nil
    assert lobby.seats == 1

    # one hosted lobby per player
    {:ok, _} = Lobbies.create_lobby("outsider_h", "MINE99", :na)

    assert {:error, "you already host a lobby"} =
             Lobbies.create_lobby("outsider_h", "MINE98", :na)

    render_click(view, "close_lobby")
  end

  test "joining by code and by list; seat rules enforced", %{conn: _conn} do
    ids = ["l_host", "l_friend", "l_walkin", "l_other"]
    cleanup(ids)
    for id <- ids, do: sim_player(id, id)

    {:ok, _} =
      Lobbies.create_lobby("l_host", "LOB01", :eu, open?: true, description: "come on in")

    # by code (case-insensitive); wrong code rejected
    assert {:error, "no lobby with that code"} = Lobbies.join_lobby("l_friend", "NOPE99")
    assert :ok = Lobbies.join_lobby("l_friend", "lob01")
    assert Lobbies.snapshot("l_friend").lobby.code == "LOB01"

    # from the list, no code, because it's open
    lobby = Enum.find(Lobbies.snapshot("l_walkin").lobbies, &(&1.host == "l_host"))
    assert lobby.open and lobby.description == "come on in"
    assert :ok = Lobbies.join_open_lobby("l_walkin", lobby.id)

    # one lobby per player, in any role
    assert {:error, _} = Lobbies.join_lobby("l_friend", "LOB01")
    assert {:error, _} = Lobbies.create_lobby("l_friend", "MINE01", :na)
    assert {:error, _} = Lobbies.join_lobby("l_host", "LOB01")

    # closed lobbies need the code
    {:ok, _} = Lobbies.create_lobby("l_other", "SHUT01", :na)
    shut = Enum.find(Lobbies.snapshot("l_walkin").lobbies, &(&1.host == "l_other"))

    assert {:error, "this lobby needs its code to join"} =
             Lobbies.join_open_lobby("l_walkin", shut.id)

    # leaving frees the seat
    :ok = Lobbies.leave_lobby("l_walkin")
    assert Lobbies.snapshot("l_walkin").lobby == nil
    assert Lobbies.snapshot("l_host").lobby.seats == 2
  end

  test "an invite link takes a seat and cleans the URL", %{conn: conn} do
    cleanup(["lnk_host"])
    sim_player("lnk_host", "LinkHost")
    {:ok, _} = Lobbies.create_lobby("lnk_host", "LINK01", :na)

    {:ok, view, _html} = live(conn, "/join/link01")
    assert render(view) =~ "you have a seat"
    assert render(view) =~ "LINK01"
  end

  test "an invite link with a dead code just shows the error", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/join/NOPE99")
    assert render(view) =~ "no lobby with that code"
    refute render(view) =~ "you have a seat"
  end

  test "a lobby caps at 16 seats", %{conn: _conn} do
    ids = for i <- 1..17, do: "cap_#{i}"
    cleanup(ids)
    for id <- ids, do: sim_player(id, id)

    [host | rest] = ids
    {:ok, _} = Lobbies.create_lobby(host, "CAP16", :na)
    {fits, [last]} = Enum.split(rest, 15)

    for id <- fits, do: :ok = Lobbies.join_lobby(id, "CAP16")
    assert Lobbies.snapshot(host).lobby.full
    assert {:error, "lobby is full"} = Lobbies.join_lobby(last, "CAP16")
  end

  test "chat and map votes are for seated players only", %{conn: conn} do
    cleanup(["c_outsider", "c_seated"])

    {:ok, view, _html} = live(conn, "/")
    view |> form("form[phx-submit=set_name]", %{"name" => "ChatHost"}) |> render_submit()

    view
    |> form("form[phx-submit=create_lobby]", %{"code" => "CHAT01", "region" => "na"})
    |> render_submit()

    sim_player("c_outsider", "COutsider")
    lobby = Enum.find(Lobbies.snapshot("c_outsider").lobbies, &(&1.host == "ChatHost"))

    assert {:error, "only players seated in this lobby can use its chat"} =
             Lobbies.send_chat("c_outsider", lobby.id, "let me in")

    assert {:error, "only seated players can vote on the map"} =
             Lobbies.vote_map("c_outsider", lobby.id, "Ravine")

    # outsiders don't even receive the messages in their snapshot
    sim_player("c_seated", "CSeated")
    :ok = Lobbies.join_lobby("c_seated", "CHAT01")
    :ok = Lobbies.send_chat("c_seated", lobby.id, "glhf")
    assert [%{body: "glhf"}] = Lobbies.snapshot("c_seated").lobby.messages

    outsider_view = Enum.find(Lobbies.snapshot("c_outsider").lobbies, &(&1.id == lobby.id))
    assert outsider_view.messages == []

    # votes: change and unvote; leaver's vote goes with them
    :ok = Lobbies.vote_map("c_seated", lobby.id, "Ravine")
    :ok = Lobbies.vote_map("c_seated", lobby.id, "Scorch")
    assert Lobbies.snapshot("c_seated").lobby.vote.tally == %{"Scorch" => 1}
    assert {:error, "unknown map"} = Lobbies.vote_map("c_seated", lobby.id, "Moon Base")

    :ok = Lobbies.leave_lobby("c_seated")
    after_leave = Enum.find(Lobbies.snapshot("c_outsider").lobbies, &(&1.id == lobby.id))
    assert after_leave.vote.tally == %{}

    # host chats from the LiveView
    html =
      view
      |> form("form[phx-submit=send_chat]", %{"lobby_id" => lobby.id, "body" => "welcome"})
      |> render_submit()

    assert html =~ "welcome"
    render_click(view, "close_lobby")
  end

  test "only the host can change or clear the description", %{conn: _conn} do
    ids = ["d_host", "d_friend"]
    cleanup(ids)
    for id <- ids, do: sim_player(id, id)

    {:ok, _} = Lobbies.create_lobby("d_host", "DESC01", :na, description: "old text")
    :ok = Lobbies.join_lobby("d_friend", "DESC01")

    assert {:error, "you don't host a lobby"} = Lobbies.set_description("d_friend", "hijacked")

    assert :ok = Lobbies.set_description("d_host", "new text")
    assert Lobbies.snapshot("d_friend").lobby.description == "new text"

    assert {:error, _} = Lobbies.set_description("d_host", String.duplicate("x", 121))

    assert :ok = Lobbies.set_description("d_host", "   ")
    assert Lobbies.snapshot("d_friend").lobby.description == nil
  end

  test "ready check: host starts, everyone must confirm, timeout fails it", %{conn: _conn} do
    ids = ["r_host", "r_a", "r_b"]
    cleanup(ids)
    for id <- ids, do: sim_player(id, id)

    {:ok, _} = Lobbies.create_lobby("r_host", "READY1", :na)
    :ok = Lobbies.join_lobby("r_a", "READY1")
    :ok = Lobbies.join_lobby("r_b", "READY1")

    # only the host can start one; no readying without a check
    assert {:error, "you don't host a lobby"} = Lobbies.start_ready_check("r_a")
    assert {:error, "no ready check is running"} = Lobbies.ready_up("r_a")

    :ok = Lobbies.start_ready_check("r_host")
    assert {:error, "a ready check is already running"} = Lobbies.start_ready_check("r_host")

    # nobody is pre-readied — the host has to confirm like everyone else
    check = Lobbies.snapshot("r_a").lobby.ready_check
    assert check.status == :running
    assert check.ready_count == 0
    refute check.me_ready

    # the seat list carries per-player check state for the chip colors
    assert [%{ready: false, connected: true, you: true} | _] =
             Lobbies.snapshot("r_host").lobby.players

    :ok = Lobbies.ready_up("r_a")
    :ok = Lobbies.ready_up("r_b")
    assert Lobbies.snapshot("r_host").lobby.ready_check.status == :running

    assert %{name: "r_a", ready: true} =
             Enum.find(Lobbies.snapshot("r_host").lobby.players, &(&1.name == "r_a"))

    :ok = Lobbies.ready_up("r_host")
    assert Lobbies.snapshot("r_host").lobby.ready_check.status == :passed

    # a fresh check that times out fails
    :ok = Lobbies.start_ready_check("r_host")
    send(Process.whereis(Lobbies), {:ready_check_timeout, Lobbies.snapshot("r_host").lobby.id})
    assert Lobbies.snapshot("r_host").lobby.ready_check.status == :failed
  end

  test "ready check passes when the last unready player leaves", %{conn: _conn} do
    ids = ["rl_host", "rl_a", "rl_b"]
    cleanup(ids)
    for id <- ids, do: sim_player(id, id)

    {:ok, _} = Lobbies.create_lobby("rl_host", "READY2", :eu)
    :ok = Lobbies.join_lobby("rl_a", "READY2")
    :ok = Lobbies.join_lobby("rl_b", "READY2")
    :ok = Lobbies.start_ready_check("rl_host")
    :ok = Lobbies.ready_up("rl_host")
    :ok = Lobbies.ready_up("rl_a")

    :ok = Lobbies.leave_lobby("rl_b")
    assert Lobbies.snapshot("rl_host").lobby.ready_check.status == :passed
  end

  test "auto ready check starts when the lobby fills", %{conn: _conn} do
    ids = for i <- 1..16, do: "ar_#{i}"
    cleanup(ids)
    for id <- ids, do: sim_player(id, id)

    [host | rest] = ids
    # can be enabled right at creation, and toggled later by the host only
    {:ok, _} = Lobbies.create_lobby(host, "AUTO16", :na, auto_ready?: true)
    assert Lobbies.snapshot(host).lobby.auto_ready
    :ok = Lobbies.set_auto_ready(host, false)
    refute Lobbies.snapshot(host).lobby.auto_ready
    :ok = Lobbies.set_auto_ready(host, true)
    assert {:error, "you don't host a lobby"} = Lobbies.set_auto_ready(hd(rest), true)

    {first, [last]} = Enum.split(rest, 14)
    for id <- first, do: :ok = Lobbies.join_lobby(id, "AUTO16")
    assert Lobbies.snapshot(host).lobby.ready_check == nil

    :ok = Lobbies.join_lobby(last, "AUTO16")
    check = Lobbies.snapshot(host).lobby.ready_check
    assert check.status == :running
    # auto-started: nobody is ready yet, host included
    assert check.ready_count == 0
  end

  test "the host can flip a lobby between gathering and in game", %{conn: _conn} do
    ids = ["s_host", "s_friend"]
    cleanup(ids)
    for id <- ids, do: sim_player(id, id)

    {:ok, _} = Lobbies.create_lobby("s_host", "STAT01", :na)
    :ok = Lobbies.join_lobby("s_friend", "STAT01")
    assert Lobbies.snapshot("s_friend").lobby.status == :gathering

    # members can't flip it, the host can — and everyone sees it in the list
    assert {:error, "you don't host a lobby"} = Lobbies.set_status("s_friend", :in_game)
    assert {:error, "unknown lobby status"} = Lobbies.set_status("s_host", :warmup)
    assert :ok = Lobbies.set_status("s_host", :in_game)

    lobby = Lobbies.snapshot("s_friend").lobby
    assert lobby.status == :in_game

    assert :ok = Lobbies.set_status("s_host", :gathering)
    assert Lobbies.snapshot("s_friend").lobby.status == :gathering
  end

  test "the host can toggle free-to-join on an existing lobby", %{conn: _conn} do
    ids = ["t_host", "t_friend", "t_walkin"]
    cleanup(ids)
    for id <- ids, do: sim_player(id, id)

    {:ok, _} = Lobbies.create_lobby("t_host", "TOGL01", :na)
    :ok = Lobbies.join_lobby("t_friend", "TOGL01")
    lobby = Lobbies.snapshot("t_host").lobby
    refute lobby.open

    # members can't flip it, the host can
    assert {:error, "you don't host a lobby"} = Lobbies.set_open("t_friend", true)
    assert :ok = Lobbies.set_open("t_host", true)

    assert Lobbies.snapshot("t_walkin").lobbies
           |> Enum.find(&(&1.id == lobby.id))
           |> Map.get(:open)

    # now list-joinable; closing it again blocks the next walk-in
    assert :ok = Lobbies.join_open_lobby("t_walkin", lobby.id)
    :ok = Lobbies.leave_lobby("t_walkin")
    assert :ok = Lobbies.set_open("t_host", false)

    assert {:error, "this lobby needs its code to join"} =
             Lobbies.join_open_lobby("t_walkin", lobby.id)
  end
end
