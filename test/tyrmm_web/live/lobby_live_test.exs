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

  # the generated site code of the lobby this player hosts (joins go through it)
  defp site_code(host_id), do: Lobbies.snapshot(host_id).lobby.code

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
      |> form("form[phx-submit=create_lobby]", %{"game_code" => "abc123", "region" => "na"})
      |> render_submit()

    # host sees the room UI with the normalized game code and an invite button,
    # but the site lobby ID itself is never displayed (it only rides the link)
    assert html =~ "Your lobby"
    assert html =~ "ABC123"
    assert html =~ "Copy join link"

    lobby_id_code =
      :sys.get_state(Lobbies).lobbies
      |> Map.values()
      |> Enum.find(&(&1.game_code == "ABC123"))
      |> Map.fetch!(:code)

    assert html =~ "/join/#{lobby_id_code}"
    refute html =~ ">#{lobby_id_code}<"

    # outsiders see the lobby but neither code
    sim_player("outsider_h", "Outsider")
    lobby = Enum.find(Lobbies.snapshot("outsider_h").lobbies, &(&1.host == "Host"))
    assert lobby.code == nil
    assert lobby.game_code == nil
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

    code = site_code("l_host")

    # by site code (case-insensitive); wrong code rejected
    assert {:error, "no lobby with that code"} = Lobbies.join_lobby("l_friend", "NOPE99")
    assert :ok = Lobbies.join_lobby("l_friend", String.downcase(code))
    assert Lobbies.snapshot("l_friend").lobby.code == code
    # seated players also see the in-game code
    assert Lobbies.snapshot("l_friend").lobby.game_code == "LOB01"

    # from the list, no code, because it's open
    lobby = Enum.find(Lobbies.snapshot("l_walkin").lobbies, &(&1.host == "l_host"))
    assert lobby.open and lobby.description == "come on in"
    assert :ok = Lobbies.join_open_lobby("l_walkin", lobby.id)

    # one lobby per player, in any role
    assert {:error, _} = Lobbies.join_lobby("l_friend", code)
    assert {:error, _} = Lobbies.create_lobby("l_friend", "MINE01", :na)
    assert {:error, _} = Lobbies.join_lobby("l_host", code)

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

    {:ok, view, _html} = live(conn, "/join/#{String.downcase(site_code("lnk_host"))}")
    assert render(view) =~ "you have a seat"
    # seated members see the in-game code
    assert render(view) =~ "LINK01"
  end

  test "an invite link with a dead code just shows the error", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/join/NOPE99")
    assert render(view) =~ "no lobby with that code"
    refute render(view) =~ "you have a seat"
  end

  test "members are told why the lobby vanished when the host drops", %{conn: conn} do
    cleanup(["gone_host"])
    {_id, host_pid} = sim_player("gone_host", "GoneHost")
    {:ok, _} = Lobbies.create_lobby("gone_host", "GONE01", :na)

    {:ok, view, _html} = live(conn, "/join/#{site_code("gone_host")}")
    assert render(view) =~ "you have a seat"

    # kill the host's process, then skip the grace wait by firing the timer msg
    Process.exit(host_pid, :kill)
    :sys.get_state(Lobbies)
    send(Process.whereis(Lobbies), {:drop_player, "gone_host"})
    :sys.get_state(Lobbies)

    html = render(view)
    assert html =~ "the host disconnected — lobby closed"
    refute html =~ "you have a seat"
  end

  test "a host with two tabs open survives closing one of them", %{conn: _conn} do
    cleanup(["tabby"])
    {_id, tab1} = sim_player("tabby", "Tabby")
    tab2 = spawn(fn -> Process.sleep(:infinity) end)
    :ok = Lobbies.register("tabby", tab2)

    {:ok, _} = Lobbies.create_lobby("tabby", "TABS01", :na)

    # closing one tab must not start the disconnect countdown
    Process.exit(tab2, :kill)
    :sys.get_state(Lobbies)
    assert %{lobby: %{players: [%{connected: true}]}} = Lobbies.snapshot("tabby")

    # losing the last tab does
    Process.exit(tab1, :kill)
    :sys.get_state(Lobbies)
    assert %{lobby: %{players: [%{connected: false}]}} = Lobbies.snapshot("tabby")

    send(Process.whereis(Lobbies), {:drop_player, "tabby"})
    :sys.get_state(Lobbies)
    assert Lobbies.snapshot("tabby").lobby == nil

    # the player entry goes with the grace timer — localStorage brings the
    # callsign back on reconnect, so server state stays bounded
    refute Map.has_key?(:sys.get_state(Lobbies).players, "tabby")
  end

  test "the host can kick a member, who is told about it", %{conn: conn} do
    cleanup(["k_host", "k_other"])
    sim_player("k_host", "KickHost")
    sim_player("k_other", "KOther")
    {:ok, _} = Lobbies.create_lobby("k_host", "KICK01", :na)
    :ok = Lobbies.join_lobby("k_other", site_code("k_host"))

    # the LiveView under test takes the third seat
    {:ok, view, _html} = live(conn, "/join/#{site_code("k_host")}")
    assert render(view) =~ "you have a seat"

    victim_id =
      Lobbies.snapshot("k_host").lobby.players
      |> Enum.find(&(&1.name not in ["KickHost", "KOther"]))
      |> Map.fetch!(:id)

    # only the host can kick, and only actual members
    assert {:error, "you don't host a lobby"} = Lobbies.kick_player("k_other", victim_id)

    assert {:error, "that player isn't seated in your lobby"} =
             Lobbies.kick_player("k_host", "nobody")

    :ok = Lobbies.kick_player("k_host", victim_id)
    :sys.get_state(Lobbies)

    html = render(view)
    assert html =~ "the host removed you from the lobby"
    refute html =~ "you have a seat"
    assert Lobbies.snapshot("k_host").lobby.seats == 2
  end

  test "a lobby caps at 16 seats", %{conn: _conn} do
    ids = for i <- 1..17, do: "cap_#{i}"
    cleanup(ids)
    for id <- ids, do: sim_player(id, id)

    [host | rest] = ids
    {:ok, _} = Lobbies.create_lobby(host, "CAP16", :na)
    code = site_code(host)
    {fits, [last]} = Enum.split(rest, 15)

    for id <- fits, do: :ok = Lobbies.join_lobby(id, code)
    assert Lobbies.snapshot(host).lobby.full
    assert {:error, "lobby is full"} = Lobbies.join_lobby(last, code)
  end

  test "chat and map votes are for seated players only", %{conn: conn} do
    cleanup(["c_outsider", "c_seated"])

    {:ok, view, _html} = live(conn, "/")
    view |> form("form[phx-submit=set_name]", %{"name" => "ChatHost"}) |> render_submit()

    view
    |> form("form[phx-submit=create_lobby]", %{"game_code" => "CHAT01", "region" => "na"})
    |> render_submit()

    sim_player("c_outsider", "COutsider")
    lobby = Enum.find(Lobbies.snapshot("c_outsider").lobbies, &(&1.host == "ChatHost"))

    assert {:error, "only players seated in this lobby can use its chat"} =
             Lobbies.send_chat("c_outsider", lobby.id, "let me in")

    assert {:error, "only seated players can vote on the map"} =
             Lobbies.vote_map("c_outsider", lobby.id, "Ravine")

    # outsiders don't even receive the messages in their snapshot
    # (the host is the LiveView, so pull the site code straight from state)
    sim_player("c_seated", "CSeated")
    :ok = Lobbies.join_lobby("c_seated", :sys.get_state(Lobbies).lobbies[lobby.id].code)
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
    :ok = Lobbies.join_lobby("d_friend", site_code("d_host"))

    assert {:error, "you don't host a lobby"} = Lobbies.set_description("d_friend", "hijacked")

    assert :ok = Lobbies.set_description("d_host", "new text")
    assert Lobbies.snapshot("d_friend").lobby.description == "new text"

    assert {:error, _} = Lobbies.set_description("d_host", String.duplicate("x", 121))

    assert :ok = Lobbies.set_description("d_host", "   ")
    assert Lobbies.snapshot("d_friend").lobby.description == nil
  end

  test "site lobby ID and in-game code are separate; the game code comes later", %{conn: _conn} do
    ids = ["c_host", "c_friend", "c_other"]
    cleanup(ids)
    for id <- ids, do: sim_player(id, id)

    # no game code up front — the site ID is generated regardless
    {:ok, _} = Lobbies.create_lobby("c_host", "", :na)
    assert {:error, _} = Lobbies.create_lobby("c_other", "oops!", :na)

    mine = Lobbies.snapshot("c_host").lobby
    assert mine.code =~ ~r/^[A-Z2-9]{6}$/
    assert mine.game_code == nil

    # blank join input never matches; the site ID does
    assert {:error, "no lobby with that code"} = Lobbies.join_lobby("c_friend", "")
    assert :ok = Lobbies.join_lobby("c_friend", mine.code)

    # only the host sets the game code, and only to something valid
    assert {:error, "you don't host a lobby"} = Lobbies.set_game_code("c_friend", "LATER1")
    assert {:error, _} = Lobbies.set_game_code("c_host", "no")

    assert :ok = Lobbies.set_game_code("c_host", "later1")
    assert Lobbies.snapshot("c_friend").lobby.game_code == "LATER1"

    # changing the game code never touches the site ID or seated players
    assert :ok = Lobbies.set_game_code("c_host", "LATER2")
    assert Lobbies.snapshot("c_friend").lobby.code == mine.code

    # and it can be cleared back to none (room closed, new one coming)
    assert :ok = Lobbies.set_game_code("c_host", "  ")
    assert Lobbies.snapshot("c_friend").lobby.game_code == nil
  end

  test "ready check: host starts, everyone must confirm, timeout fails it", %{conn: _conn} do
    ids = ["r_host", "r_a", "r_b"]
    cleanup(ids)
    for id <- ids, do: sim_player(id, id)

    {:ok, _} = Lobbies.create_lobby("r_host", "READY1", :na)
    :ok = Lobbies.join_lobby("r_a", site_code("r_host"))
    :ok = Lobbies.join_lobby("r_b", site_code("r_host"))

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
    # a passed check starts the game automatically
    assert Lobbies.snapshot("r_host").lobby.status == :in_game

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
    :ok = Lobbies.join_lobby("rl_a", site_code("rl_host"))
    :ok = Lobbies.join_lobby("rl_b", site_code("rl_host"))
    :ok = Lobbies.start_ready_check("rl_host")
    :ok = Lobbies.ready_up("rl_host")
    :ok = Lobbies.ready_up("rl_a")

    :ok = Lobbies.leave_lobby("rl_b")
    assert Lobbies.snapshot("rl_host").lobby.ready_check.status == :passed
    assert Lobbies.snapshot("rl_host").lobby.status == :in_game
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

    code = site_code(host)
    {first, [last]} = Enum.split(rest, 14)
    for id <- first, do: :ok = Lobbies.join_lobby(id, code)
    assert Lobbies.snapshot(host).lobby.ready_check == nil

    :ok = Lobbies.join_lobby(last, code)
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
    :ok = Lobbies.join_lobby("s_friend", site_code("s_host"))
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
    :ok = Lobbies.join_lobby("t_friend", site_code("t_host"))
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
