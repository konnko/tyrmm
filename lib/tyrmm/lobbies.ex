defmodule Tyrmm.Lobbies do
  @moduledoc """
  In-memory lobby directory for custom games.

  A host picks a region (`:na` or `:eu`) and optionally pastes the in-game
  room code (`game_code`, addable later with `set_game_code/2`). Every lobby
  also gets a generated site code (`code`) that identifies it here: players
  take one of the 16 seats (host included) by typing it or opening an invite
  link — or, for free-to-join lobbies, straight from the lobby list. Seated
  players share both codes, a chat, and a map vote.

  Everything lives in this GenServer — no database. State is bounded by
  concurrent players: entries are deleted when the disconnect grace runs out,
  and the browser's localStorage restores the callsign on return.
  """

  use GenServer

  @lobby_size 16
  @disconnect_grace_ms 30_000
  @chat_history 50
  @ready_check_timeout_ms 30_000
  @ready_result_ttl_ms 15_000
  @code_format ~r/^[a-zA-Z0-9]{4,12}$/
  @regions [:na, :eu]
  @statuses [:gathering, :in_game]
  @topic "lobbies"

  @maps [
    "Divide",
    "Fields",
    "Ravine",
    "Scorch",
    "Wind Valley",
    "Prototype: Dunes",
    "Prototype: Expanse",
    "Prototype: Ikarus Only",
    "Prototype: Ruins",
    "Sandbox"
  ]

  @name_adjectives ~w(Iron Swift Crimson Silent Vivid Rogue Solar Frost Neon Ember
                      Static Lucky Feral Ghost Turbo Prime Blaze Shadow Nova Hyper)
  @name_nouns ~w(Falcon Viper Otter Lynx Raven Mantis Wolf Drake Puma Heron
                 Cobra Badger Moth Orca Jackal Bison Sparrow Gecko Panther Stag)

  ## Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def topic, do: @topic
  def lobby_size, do: @lobby_size
  def maps, do: @maps

  @doc "Register a player's LiveView process so disconnects clean up their state."
  def register(player_id, pid \\ self()) do
    GenServer.call(__MODULE__, {:register, player_id, pid})
  end

  def set_name(player_id, name) do
    GenServer.call(__MODULE__, {:set_name, player_id, name})
  end

  @doc """
  Opens a lobby. The site code identifying it here is always generated;
  `game_code` is the in-game room code and may be `nil` or blank when the
  host hasn't made the room yet — added later with `set_game_code/2`.
  Options: `open?: true` makes it joinable straight from the lobby list (no
  code needed), `auto_ready?: true` starts a ready check when the lobby
  fills, `description:` is free text shown in the list.
  """
  def create_lobby(player_id, game_code, region, opts \\ []) do
    GenServer.call(__MODULE__, {:create_lobby, player_id, game_code, region, opts})
  end

  @doc "Set (or change, or clear with empty text) the in-game room code of the lobby you host."
  def set_game_code(player_id, game_code) do
    GenServer.call(__MODULE__, {:set_game_code, player_id, game_code})
  end

  def close_lobby(player_id) do
    GenServer.call(__MODULE__, {:close_lobby, player_id})
  end

  @doc "Toggle whether the lobby you host is free to join from the list."
  def set_open(player_id, open?) do
    GenServer.call(__MODULE__, {:set_open, player_id, open?})
  end

  @doc "Set the status of the lobby you host (`:gathering` or `:in_game`)."
  def set_status(player_id, status) do
    GenServer.call(__MODULE__, {:set_status, player_id, status})
  end

  @doc "Toggle whether a ready check starts automatically when the lobby fills."
  def set_auto_ready(player_id, auto?) do
    GenServer.call(__MODULE__, {:set_auto_ready, player_id, auto?})
  end

  @doc "Start a ready check in the lobby you host. Everyone, host included, must confirm."
  def start_ready_check(player_id) do
    GenServer.call(__MODULE__, {:start_ready_check, player_id})
  end

  @doc "Mark yourself ready in your lobby's running ready check."
  def ready_up(player_id) do
    GenServer.call(__MODULE__, {:ready_up, player_id})
  end

  @doc "Update (or clear, with empty text) the description of the lobby you host."
  def set_description(player_id, description) do
    GenServer.call(__MODULE__, {:set_description, player_id, description})
  end

  @doc "Take a seat in a lobby by pasting its site code."
  def join_lobby(player_id, code) do
    GenServer.call(__MODULE__, {:join_lobby, player_id, code})
  end

  @doc "Take a seat in a free-to-join lobby straight from the lobby list."
  def join_open_lobby(player_id, lobby_id) do
    GenServer.call(__MODULE__, {:join_open_lobby, player_id, lobby_id})
  end

  def leave_lobby(player_id) do
    GenServer.call(__MODULE__, {:leave_lobby, player_id})
  end

  @doc "Remove a member from the lobby you host. They can rejoin (no ban)."
  def kick_player(player_id, member_id) do
    GenServer.call(__MODULE__, {:kick_player, player_id, member_id})
  end

  def send_chat(player_id, lobby_id, body) do
    GenServer.call(__MODULE__, {:send_chat, player_id, lobby_id, body})
  end

  @doc "Vote for a map (seated players only). Voting the same map again unvotes."
  def vote_map(player_id, lobby_id, map) do
    GenServer.call(__MODULE__, {:vote_map, player_id, lobby_id, map})
  end

  @doc "Personalized view of the lobby list for one player."
  def snapshot(player_id) do
    GenServer.call(__MODULE__, {:snapshot, player_id})
  end

  ## Server

  @impl true
  def init(_opts) do
    state = %{
      # player_id => %{name, pids: %{pid => monitor_ref}} — one entry per open tab
      players: %{},
      # player_id => grace timer ref, set when their process goes down
      disconnected: %{},
      # lobby_id => lobby
      lobbies: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:register, player_id, pid}, _from, state) do
    state =
      case Map.pop(state.disconnected, player_id) do
        {nil, disconnected} ->
          %{state | disconnected: disconnected}

        {timer, disconnected} ->
          Process.cancel_timer(timer)
          %{state | disconnected: disconnected}
      end

    player = Map.get(state.players, player_id, %{name: nil, pids: %{}})

    # a player may have several tabs open — track and monitor every one
    pids =
      if Map.has_key?(player.pids, pid) do
        player.pids
      else
        Map.put(player.pids, pid, Process.monitor(pid))
      end

    # first visit gets a random callsign; the browser then persists it in
    # localStorage and replays it on reconnect (the CallsignStore hook)
    name = player.name || random_name(state)
    players = Map.put(state.players, player_id, %{name: name, pids: pids})
    # broadcast so a reconnecting player's seat chip stops showing as dropped
    {:reply, :ok, broadcast(%{state | players: players})}
  end

  def handle_call({:set_name, player_id, name}, _from, state) do
    name = name |> to_string() |> String.trim()

    cond do
      not Map.has_key?(state.players, player_id) ->
        {:reply, {:error, "not connected"}, state}

      name == "" or String.length(name) > 24 ->
        {:reply, {:error, "name must be 1–24 characters"}, state}

      true ->
        players = put_in(state.players, [player_id, :name], name)
        {:reply, :ok, broadcast(%{state | players: players})}
    end
  end

  def handle_call({:create_lobby, player_id, game_code, region, opts}, _from, state) do
    game_code = normalize_code(game_code)
    description = opts |> Keyword.get(:description) |> normalize_description()

    cond do
      player_name(state, player_id) == nil ->
        {:reply, {:error, "pick a name first"}, state}

      game_code == :invalid ->
        {:reply, {:error, "game code must be 4–12 letters or digits"}, state}

      region not in @regions ->
        {:reply, {:error, "region must be NA or EU"}, state}

      hosted_lobby(state, player_id) != nil ->
        {:reply, {:error, "you already host a lobby"}, state}

      seated_lobby(state, player_id) != nil ->
        {:reply, {:error, "leave your current lobby before hosting one"}, state}

      description == :too_long ->
        {:reply, {:error, "description must be at most 120 characters"}, state}

      true ->
        lobby = %{
          id: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false),
          code: generate_code(state),
          game_code: game_code,
          region: region,
          creator_id: player_id,
          members: [],
          open?: Keyword.get(opts, :open?, false) == true,
          status: :gathering,
          auto_ready?: Keyword.get(opts, :auto_ready?, false) == true,
          ready_check: nil,
          description: description,
          votes: %{},
          messages: [],
          created_at: System.system_time(:millisecond)
        }

        state = put_in(state.lobbies[lobby.id], lobby)
        {:reply, {:ok, lobby.id}, broadcast(state)}
    end
  end

  def handle_call({:close_lobby, player_id}, _from, state) do
    case hosted_lobby(state, player_id) do
      nil ->
        {:reply, :ok, state}

      lobby ->
        notify_lobby_closed(state, lobby, "the host closed the lobby")
        {:reply, :ok, state |> remove_lobby(lobby.id) |> broadcast()}
    end
  end

  def handle_call({:set_open, player_id, open?}, _from, state) do
    case hosted_lobby(state, player_id) do
      nil ->
        {:reply, {:error, "you don't host a lobby"}, state}

      lobby ->
        state = put_in(state.lobbies[lobby.id], %{lobby | open?: open? == true})
        {:reply, :ok, broadcast(state)}
    end
  end

  def handle_call({:set_status, player_id, status}, _from, state) do
    lobby = hosted_lobby(state, player_id)

    cond do
      lobby == nil ->
        {:reply, {:error, "you don't host a lobby"}, state}

      status not in @statuses ->
        {:reply, {:error, "unknown lobby status"}, state}

      true ->
        state = put_in(state.lobbies[lobby.id], %{lobby | status: status})
        {:reply, :ok, broadcast(state)}
    end
  end

  def handle_call({:set_auto_ready, player_id, auto?}, _from, state) do
    case hosted_lobby(state, player_id) do
      nil ->
        {:reply, {:error, "you don't host a lobby"}, state}

      lobby ->
        state = put_in(state.lobbies[lobby.id], %{lobby | auto_ready?: auto? == true})
        {:reply, :ok, broadcast(state)}
    end
  end

  def handle_call({:start_ready_check, player_id}, _from, state) do
    lobby = hosted_lobby(state, player_id)

    cond do
      lobby == nil ->
        {:reply, {:error, "you don't host a lobby"}, state}

      match?(%{status: :running}, lobby.ready_check) ->
        {:reply, {:error, "a ready check is already running"}, state}

      true ->
        {:reply, :ok, state |> begin_ready_check(lobby.id) |> broadcast()}
    end
  end

  def handle_call({:ready_up, player_id}, _from, state) do
    lobby = Enum.find(Map.values(state.lobbies), &seated?(&1, player_id))

    cond do
      lobby == nil ->
        {:reply, {:error, "you're not in a lobby"}, state}

      not match?(%{status: :running}, lobby.ready_check) ->
        {:reply, {:error, "no ready check is running"}, state}

      true ->
        check = lobby.ready_check
        check = %{check | responses: Map.put(check.responses, player_id, true)}
        state = put_in(state.lobbies[lobby.id], %{lobby | ready_check: check})
        {:reply, :ok, state |> maybe_pass_ready_check(lobby.id) |> broadcast()}
    end
  end

  def handle_call({:set_description, player_id, description}, _from, state) do
    lobby = hosted_lobby(state, player_id)

    cond do
      lobby == nil ->
        {:reply, {:error, "you don't host a lobby"}, state}

      normalize_description(description) == :too_long ->
        {:reply, {:error, "description must be at most 120 characters"}, state}

      true ->
        state =
          put_in(state.lobbies[lobby.id], %{
            lobby
            | description: normalize_description(description)
          })

        {:reply, :ok, broadcast(state)}
    end
  end

  def handle_call({:set_game_code, player_id, game_code}, _from, state) do
    lobby = hosted_lobby(state, player_id)
    game_code = normalize_code(game_code)

    cond do
      lobby == nil ->
        {:reply, {:error, "you don't host a lobby"}, state}

      game_code == :invalid ->
        {:reply, {:error, "game code must be 4–12 letters or digits"}, state}

      game_code == lobby.game_code ->
        {:reply, :ok, state}

      true ->
        state = put_in(state.lobbies[lobby.id], %{lobby | game_code: game_code})
        {:reply, :ok, broadcast(state)}
    end
  end

  def handle_call({:join_lobby, player_id, code}, _from, state) do
    case find_by_code(state, normalize_code(code)) do
      nil -> {:reply, {:error, "no lobby with that code"}, state}
      lobby -> take_seat(state, player_id, lobby)
    end
  end

  def handle_call({:join_open_lobby, player_id, lobby_id}, _from, state) do
    lobby = state.lobbies[lobby_id]

    cond do
      lobby == nil ->
        {:reply, {:error, "that lobby is gone"}, state}

      not lobby.open? ->
        {:reply, {:error, "this lobby needs its code to join"}, state}

      true ->
        take_seat(state, player_id, lobby)
    end
  end

  def handle_call({:leave_lobby, player_id}, _from, state) do
    {:reply, :ok, state |> remove_seat(player_id) |> broadcast()}
  end

  def handle_call({:kick_player, player_id, member_id}, _from, state) do
    lobby = hosted_lobby(state, player_id)

    cond do
      lobby == nil ->
        {:reply, {:error, "you don't host a lobby"}, state}

      member_id not in lobby.members ->
        {:reply, {:error, "that player isn't seated in your lobby"}, state}

      true ->
        notify_player(state, member_id, "the host removed you from the lobby")
        {:reply, :ok, state |> remove_seat(member_id) |> broadcast()}
    end
  end

  def handle_call({:send_chat, player_id, lobby_id, body}, _from, state) do
    body = body |> to_string() |> String.trim()
    lobby = state.lobbies[lobby_id]
    name = player_name(state, player_id)

    cond do
      name == nil ->
        {:reply, {:error, "not connected"}, state}

      body == "" or String.length(body) > 240 ->
        {:reply, {:error, "message must be 1–240 characters"}, state}

      lobby == nil ->
        {:reply, {:error, "that lobby is gone"}, state}

      not seated?(lobby, player_id) ->
        {:reply, {:error, "only players seated in this lobby can use its chat"}, state}

      true ->
        message = %{
          player_id: player_id,
          name: name,
          body: body,
          at: System.system_time(:second)
        }

        messages = Enum.take([message | lobby.messages], @chat_history)
        state = put_in(state.lobbies[lobby_id], %{lobby | messages: messages})
        {:reply, :ok, broadcast(state)}
    end
  end

  def handle_call({:vote_map, player_id, lobby_id, map}, _from, state) do
    lobby = state.lobbies[lobby_id]

    cond do
      lobby == nil ->
        {:reply, {:error, "that lobby is gone"}, state}

      map not in @maps ->
        {:reply, {:error, "unknown map"}, state}

      not seated?(lobby, player_id) ->
        {:reply, {:error, "only seated players can vote on the map"}, state}

      true ->
        votes =
          if lobby.votes[player_id] == map do
            Map.delete(lobby.votes, player_id)
          else
            Map.put(lobby.votes, player_id, map)
          end

        state = put_in(state.lobbies[lobby_id], %{lobby | votes: votes})
        {:reply, :ok, broadcast(state)}
    end
  end

  def handle_call({:snapshot, player_id}, _from, state) do
    {:reply, build_snapshot(state, player_id), state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    case Enum.find(state.players, fn {_id, p} -> Map.has_key?(p.pids, pid) end) do
      nil ->
        {:noreply, state}

      {player_id, player} ->
        pids = Map.delete(player.pids, pid)
        players = Map.put(state.players, player_id, %{player | pids: pids})
        state = %{state | players: players}

        if map_size(pids) == 0 do
          # last tab gone — start the grace countdown; seat chips show them red
          timer = Process.send_after(self(), {:drop_player, player_id}, @disconnect_grace_ms)

          {:noreply,
           broadcast(%{state | disconnected: Map.put(state.disconnected, player_id, timer)})}
        else
          # another tab is still connected; nothing changes for anyone
          {:noreply, state}
        end
    end
  end

  def handle_info({:ready_check_timeout, lobby_id}, state) do
    case state.lobbies[lobby_id] do
      %{ready_check: %{status: :running} = check} = lobby ->
        Process.send_after(self(), {:clear_ready_check, lobby_id}, @ready_result_ttl_ms)
        check = %{check | status: :failed, timer_ref: nil}
        state = put_in(state.lobbies[lobby_id], %{lobby | ready_check: check})
        {:noreply, broadcast(state)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:clear_ready_check, lobby_id}, state) do
    case state.lobbies[lobby_id] do
      # never clear a running check — a newer one may have started meanwhile
      %{ready_check: %{status: status}} = lobby when status != :running ->
        state = put_in(state.lobbies[lobby_id], %{lobby | ready_check: nil})
        {:noreply, broadcast(state)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:drop_player, player_id}, state) do
    if Map.has_key?(state.disconnected, player_id) do
      # the entry goes too — the browser's localStorage restores the callsign
      # on return, so state stays bounded by concurrent players, not lifetime
      state = %{
        state
        | disconnected: Map.delete(state.disconnected, player_id),
          players: Map.delete(state.players, player_id)
      }

      state =
        case hosted_lobby(state, player_id) do
          nil ->
            remove_seat(state, player_id)

          lobby ->
            notify_lobby_closed(state, lobby, "the host disconnected — lobby closed")
            remove_lobby(state, lobby.id)
        end

      {:noreply, broadcast(state)}
    else
      {:noreply, state}
    end
  end

  ## Seats

  defp take_seat(state, player_id, lobby) do
    cond do
      player_name(state, player_id) == nil ->
        {:reply, {:error, "not connected"}, state}

      lobby.creator_id == player_id ->
        {:reply, {:error, "you host this lobby"}, state}

      player_id in lobby.members ->
        {:reply, {:error, "you already have a seat in this lobby"}, state}

      seated_lobby(state, player_id) != nil ->
        {:reply, {:error, "leave your current lobby first"}, state}

      hosted_lobby(state, player_id) != nil ->
        {:reply, {:error, "close your own lobby before joining another"}, state}

      seats_taken(lobby) >= @lobby_size ->
        {:reply, {:error, "lobby is full"}, state}

      true ->
        state =
          put_in(state.lobbies[lobby.id], %{lobby | members: lobby.members ++ [player_id]})

        lobby = state.lobbies[lobby.id]

        state =
          if seats_taken(lobby) >= @lobby_size and lobby.auto_ready? and
               not match?(%{status: :running}, lobby.ready_check) do
            begin_ready_check(state, lobby.id)
          else
            state
          end

        {:reply, :ok, broadcast(state)}
    end
  end

  defp remove_seat(state, player_id) do
    case seated_lobby(state, player_id) do
      nil ->
        state

      lobby ->
        check =
          case lobby.ready_check do
            %{responses: responses} = check ->
              %{check | responses: Map.delete(responses, player_id)}

            nil ->
              nil
          end

        state =
          put_in(state.lobbies[lobby.id], %{
            lobby
            | members: List.delete(lobby.members, player_id),
              votes: Map.delete(lobby.votes, player_id),
              ready_check: check
          })

        # a leaver may have been the last player everyone was waiting on
        maybe_pass_ready_check(state, lobby.id)
    end
  end

  defp begin_ready_check(state, lobby_id) do
    lobby = state.lobbies[lobby_id]

    if lobby.ready_check && lobby.ready_check.timer_ref do
      Process.cancel_timer(lobby.ready_check.timer_ref)
    end

    timer = Process.send_after(self(), {:ready_check_timeout, lobby_id}, @ready_check_timeout_ms)

    check = %{
      status: :running,
      responses: %{},
      deadline: System.system_time(:millisecond) + @ready_check_timeout_ms,
      timer_ref: timer
    }

    state = put_in(state.lobbies[lobby_id], %{lobby | ready_check: check})
    maybe_pass_ready_check(state, lobby_id)
  end

  defp maybe_pass_ready_check(state, lobby_id) do
    case state.lobbies[lobby_id] do
      %{ready_check: %{status: :running} = check} = lobby ->
        seated_ids = [lobby.creator_id | lobby.members]

        if Enum.all?(seated_ids, &Map.get(check.responses, &1)) do
          if check.timer_ref, do: Process.cancel_timer(check.timer_ref)
          Process.send_after(self(), {:clear_ready_check, lobby_id}, @ready_result_ttl_ms)
          check = %{check | status: :passed, timer_ref: nil}
          # everyone confirmed — the game is on
          put_in(state.lobbies[lobby_id], %{lobby | ready_check: check, status: :in_game})
        else
          state
        end

      _ ->
        state
    end
  end

  defp remove_lobby(state, lobby_id) do
    %{state | lobbies: Map.delete(state.lobbies, lobby_id)}
  end

  # tell every connected member why their lobby just vanished
  defp notify_lobby_closed(state, lobby, reason) do
    Enum.each(lobby.members, &notify_player(state, &1, reason))
  end

  defp notify_player(state, player_id, message) do
    for pid <- Map.keys(get_in(state.players, [player_id, :pids]) || %{}) do
      send(pid, {:lobby_notice, message})
    end

    :ok
  end

  ## Helpers

  defp hosted_lobby(state, player_id) do
    Enum.find(Map.values(state.lobbies), &(&1.creator_id == player_id))
  end

  defp seated_lobby(state, player_id) do
    Enum.find(Map.values(state.lobbies), &(player_id in &1.members))
  end

  # blank join input normalizes to nil and must never match a lobby
  defp find_by_code(_state, nil), do: nil

  defp find_by_code(state, code) do
    Enum.find(Map.values(state.lobbies), &(&1.code == code))
  end

  # unambiguous alphabet: no I/L/O/0/1
  @code_alphabet ~c"ABCDEFGHJKMNPQRSTUVWXYZ23456789"

  defp generate_code(state) do
    Stream.repeatedly(fn ->
      for _ <- 1..6, into: "", do: <<Enum.random(@code_alphabet)>>
    end)
    |> Enum.find(&(find_by_code(state, &1) == nil))
  end

  defp seats_taken(lobby), do: 1 + length(lobby.members)

  defp seated?(lobby, player_id) do
    lobby.creator_id == player_id or player_id in lobby.members
  end

  defp player_name(state, player_id), do: get_in(state.players, [player_id, :name])

  # nil when the host hasn't got a code yet, :invalid when they typed junk
  defp normalize_code(code) do
    case code |> to_string() |> String.trim() |> String.upcase() do
      "" -> nil
      code -> if Regex.match?(@code_format, code), do: code, else: :invalid
    end
  end

  defp normalize_description(nil), do: nil

  defp normalize_description(text) do
    case text |> to_string() |> String.trim() do
      "" -> nil
      trimmed -> if String.length(trimmed) > 120, do: :too_long, else: trimmed
    end
  end

  defp random_name(state) do
    taken = state.players |> Map.values() |> Enum.map(& &1.name) |> MapSet.new()

    Stream.repeatedly(fn ->
      "#{Enum.random(@name_adjectives)}#{Enum.random(@name_nouns)}#{Enum.random(10..99)}"
    end)
    |> Enum.find(&(&1 not in taken))
  end

  defp broadcast(state) do
    Phoenix.PubSub.broadcast(Tyrmm.PubSub, @topic, :lobbies_updated)
    state
  end

  ## Snapshot

  defp build_snapshot(state, player_id) do
    lobbies = state.lobbies |> Map.values() |> Enum.sort_by(& &1.created_at)

    %{
      name: player_name(state, player_id),
      lobby: lobbies |> Enum.find(&seated?(&1, player_id)) |> lobby_view(state, player_id),
      lobbies: Enum.map(lobbies, &lobby_view(&1, state, player_id)),
      counts: %{
        lobbies: length(lobbies),
        seated: lobbies |> Enum.map(&seats_taken/1) |> Enum.sum()
      }
    }
  end

  defp lobby_view(nil, _state, _player_id), do: nil

  defp lobby_view(lobby, state, player_id) do
    seated? = seated?(lobby, player_id)

    %{
      id: lobby.id,
      region: lobby.region,
      host: player_name(state, lobby.creator_id) || "host",
      mine: lobby.creator_id == player_id,
      member: player_id in lobby.members,
      # only seated players get to see the codes and read the chat
      code: if(seated?, do: lobby.code),
      game_code: if(seated?, do: lobby.game_code),
      open: lobby.open?,
      status: lobby.status,
      auto_ready: lobby.auto_ready?,
      ready_check: ready_check_view(lobby, state, player_id),
      description: lobby.description,
      players:
        Enum.map([lobby.creator_id | lobby.members], fn id ->
          %{
            # ids are safe to show seated players: server events only ever act
            # on the session's own player_id, never a client-supplied identity
            id: id,
            host: id == lobby.creator_id,
            name: player_name(state, id) || "player",
            you: id == player_id,
            # seated players are either live or inside the disconnect grace window
            connected: not Map.has_key?(state.disconnected, id),
            ready:
              case lobby.ready_check do
                %{status: :running, responses: responses} -> Map.get(responses, id, false)
                _ -> nil
              end
          }
        end),
      seats: seats_taken(lobby),
      size: @lobby_size,
      full: seats_taken(lobby) >= @lobby_size,
      messages: if(seated?, do: lobby.messages, else: []),
      vote: vote_view(lobby, player_id)
    }
  end

  defp ready_check_view(%{ready_check: nil}, _state, _player_id), do: nil

  defp ready_check_view(lobby, state, player_id) do
    check = lobby.ready_check
    seated_ids = [lobby.creator_id | lobby.members]

    players =
      Enum.map(seated_ids, fn id ->
        %{name: player_name(state, id) || "player", ready: Map.get(check.responses, id, false)}
      end)

    %{
      status: check.status,
      deadline: check.deadline,
      players: players,
      ready_count: Enum.count(players, & &1.ready),
      total: length(players),
      me_ready: Map.get(check.responses, player_id, false)
    }
  end

  defp vote_view(lobby, player_id) do
    tally = lobby.votes |> Map.values() |> Enum.frequencies()

    top =
      case Enum.max_by(tally, fn {_map, count} -> count end, fn -> nil end) do
        nil -> nil
        {map, _count} -> map
      end

    %{tally: tally, my_vote: lobby.votes[player_id], top_map: top}
  end
end
