defmodule TyrmmWeb.LobbyLive do
  use TyrmmWeb, :live_view

  alias Tyrmm.Lobbies
  alias TyrmmWeb.Presence

  @impl true
  def mount(_params, session, socket) do
    player_id = session["player_id"] || anonymous_id()

    if connected?(socket) do
      :ok = Phoenix.PubSub.subscribe(Tyrmm.PubSub, Lobbies.topic())
      :ok = Phoenix.PubSub.subscribe(Tyrmm.PubSub, Presence.topic())
      {:ok, _} = Presence.track_player(self(), player_id)
      :ok = Lobbies.register(player_id)
    end

    socket =
      socket
      |> assign(:page_title, "Lobbies")
      |> assign(:player_id, player_id)
      |> assign(:online, Presence.online_count())
      |> assign(:now, System.system_time(:millisecond))
      |> assign(:ticking, false)
      |> refresh()

    {:ok, socket}
  end

  # /join/:code — an invite link; take the seat and clean the URL
  @impl true
  def handle_params(%{"code" => code}, _uri, socket) do
    if connected?(socket) do
      {:noreply, socket |> join_by_link(code) |> push_patch(to: ~p"/")}
    else
      {:noreply, socket}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  defp join_by_link(socket, code) do
    case Lobbies.join_lobby(socket.assigns.player_id, code) do
      :ok ->
        socket |> put_flash(:info, "you took a seat") |> refresh()

      # clicking your own invite link shouldn't scold you
      {:error, msg} when msg in ["you host this lobby", "you already have a seat in this lobby"] ->
        socket

      {:error, msg} ->
        put_flash(socket, :error, msg)
    end
  end

  ## Events

  @impl true
  def handle_event("set_name", %{"name" => name}, socket) do
    case Lobbies.set_name(socket.assigns.player_id, name) do
      :ok -> {:noreply, refresh(socket)}
      {:error, msg} -> {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("create_lobby", %{"code" => code, "region" => region} = params, socket) do
    opts = [
      open?: params["open"] == "true",
      auto_ready?: params["auto_ready"] == "true",
      description: params["description"]
    ]

    case Lobbies.create_lobby(socket.assigns.player_id, code, parse_region(region), opts) do
      {:ok, _lobby_id} -> {:noreply, refresh(socket)}
      {:error, msg} -> {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("close_lobby", _params, socket) do
    :ok = Lobbies.close_lobby(socket.assigns.player_id)
    {:noreply, refresh(socket)}
  end

  def handle_event("set_status", %{"status" => status}, socket) do
    case Lobbies.set_status(socket.assigns.player_id, parse_status(status)) do
      :ok -> {:noreply, refresh(socket)}
      {:error, msg} -> {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("toggle_auto_ready", params, socket) do
    case Lobbies.set_auto_ready(socket.assigns.player_id, params["value"] == "on") do
      :ok -> {:noreply, refresh(socket)}
      {:error, msg} -> {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("start_ready_check", _params, socket) do
    case Lobbies.start_ready_check(socket.assigns.player_id) do
      :ok -> {:noreply, refresh(socket)}
      {:error, msg} -> {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("ready_up", _params, socket) do
    case Lobbies.ready_up(socket.assigns.player_id) do
      :ok -> {:noreply, refresh(socket)}
      {:error, msg} -> {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("toggle_open", params, socket) do
    case Lobbies.set_open(socket.assigns.player_id, params["value"] == "on") do
      :ok -> {:noreply, refresh(socket)}
      {:error, msg} -> {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("set_description", %{"description" => description}, socket) do
    case Lobbies.set_description(socket.assigns.player_id, description) do
      :ok -> {:noreply, refresh(socket)}
      {:error, msg} -> {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("join_lobby", %{"code" => code}, socket) do
    case Lobbies.join_lobby(socket.assigns.player_id, code) do
      :ok -> {:noreply, refresh(socket)}
      {:error, msg} -> {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("join_open", %{"lobby-id" => lobby_id}, socket) do
    case Lobbies.join_open_lobby(socket.assigns.player_id, lobby_id) do
      :ok -> {:noreply, refresh(socket)}
      {:error, msg} -> {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("leave_lobby", _params, socket) do
    :ok = Lobbies.leave_lobby(socket.assigns.player_id)
    {:noreply, refresh(socket)}
  end

  def handle_event("send_chat", %{"lobby_id" => lobby_id, "body" => body}, socket) do
    case Lobbies.send_chat(socket.assigns.player_id, lobby_id, body) do
      :ok -> {:noreply, socket |> push_event("chat_sent", %{}) |> refresh()}
      {:error, msg} -> {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("vote_map", %{"map" => map, "lobby-id" => lobby_id}, socket) do
    case Lobbies.vote_map(socket.assigns.player_id, lobby_id, map) do
      :ok -> {:noreply, refresh(socket)}
      {:error, msg} -> {:noreply, put_flash(socket, :error, msg)}
    end
  end

  ## Messages

  @impl true
  def handle_info(:lobbies_updated, socket) do
    {:noreply, refresh(socket)}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    {:noreply, assign(socket, :online, Presence.online_count())}
  end

  def handle_info({:lobby_closed, reason}, socket) do
    {:noreply, socket |> put_flash(:error, reason) |> refresh()}
  end

  def handle_info(:tick, socket) do
    socket = assign(socket, :now, System.system_time(:millisecond))

    if ready_check_running?(socket.assigns.snap) do
      Process.send_after(self(), :tick, 1_000)
      {:noreply, socket}
    else
      {:noreply, assign(socket, :ticking, false)}
    end
  end

  ## Helpers

  defp refresh(socket) do
    snap = Lobbies.snapshot(socket.assigns.player_id)
    socket = assign(socket, snap: snap, now: System.system_time(:millisecond))

    if ready_check_running?(snap) && connected?(socket) && !socket.assigns.ticking do
      Process.send_after(self(), :tick, 1_000)
      assign(socket, :ticking, true)
    else
      socket
    end
  end

  defp ready_check_running?(snap) do
    match?(%{lobby: %{ready_check: %{status: :running}}}, snap)
  end

  defp seconds_left(deadline, now), do: max(div(deadline - now, 1000), 0)

  defp anonymous_id, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

  defp parse_region("na"), do: :na
  defp parse_region("eu"), do: :eu
  defp parse_region(_), do: nil

  defp parse_status("gathering"), do: :gathering
  defp parse_status("in_game"), do: :in_game
  defp parse_status(_), do: nil

  # dropped beats ready-check state beats the "you" highlight
  defp seat_chip_class(player) do
    cond do
      not player.connected -> "border-[#f0554d]/50 text-[#f0554d]"
      player.ready == true -> "border-[#c8f542]/50 text-[#c8f542]"
      player.ready == false -> "border-[#f0a63a]/50 text-[#f0a63a]"
      player.you -> "border-[#99f7ff]/40 text-[#99f7ff]"
      true -> "border-[#2a3140] text-[#aab4c4]"
    end
  end

  defp format_time(unix_seconds) do
    unix_seconds |> DateTime.from_unix!() |> Calendar.strftime("%H:%M")
  end

  attr :region, :atom, required: true

  defp region_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 border px-2 py-0.5 font-code text-[13px] font-semibold uppercase tracking-[0.2em]",
      @region == :na && "border-[#f0a63a]/40 bg-[#f0a63a]/10 text-[#f0a63a]",
      @region == :eu && "border-[#4ac6f5]/40 bg-[#4ac6f5]/10 text-[#4ac6f5]"
    ]}>
      {@region}
    </span>
    """
  end

  attr :label, :string, required: true
  attr :class, :string, default: nil
  slot :inner_block, required: true
  slot :corner

  defp panel(assigns) do
    ~H"""
    <section class={["relative border border-[#1c212b] bg-[#10141b]", @class]}>
      <div class="flex items-center justify-between border-b border-[#1c212b] px-4 py-2">
        <h2 class="font-display text-[13px] font-semibold uppercase tracking-[0.3em] text-[#aab4c4]">
          {@label}
        </h2>
        {render_slot(@corner)}
      </div>
      <div class="p-4">
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :accent, :boolean, default: false

  defp stat(assigns) do
    ~H"""
    <span class="flex items-baseline gap-1.5 font-code text-[13px] uppercase tracking-[0.2em] text-[#7f8a9c]">
      {@label}
      <span class={[
        "font-display text-base font-bold tabular-nums",
        (@accent && "text-[#99f7ff]") || "text-[#d7dde6]"
      ]}>
        {@value}
      </span>
    </span>
    """
  end

  attr :lobby_id, :string, required: true
  attr :vote, :map, required: true

  defp map_vote(assigns) do
    ~H"""
    <div>
      <div class="grid grid-cols-2 gap-2 sm:grid-cols-5">
        <button
          :for={map <- Lobbies.maps()}
          phx-click="vote_map"
          phx-value-map={map}
          phx-value-lobby-id={@lobby_id}
          class={[
            "flex items-center justify-between gap-2 border px-2 py-1 text-left font-code text-[13px] transition",
            (@vote.my_vote == map &&
               "border-[#99f7ff] bg-[#99f7ff]/10 text-[#99f7ff]") ||
              "border-[#2a3140] text-[#aab4c4] hover:border-[#99f7ff]/60 hover:text-[#99f7ff]"
          ]}
        >
          <span class="truncate">{map}</span>
          <span class={[
            "tabular-nums",
            (@vote.top_map == map && Map.get(@vote.tally, map, 0) > 0 && "text-[#f0a63a]") ||
              "text-[#566175]"
          ]}>
            {Map.get(@vote.tally, map, 0)}
          </span>
        </button>
      </div>
    </div>
    """
  end

  attr :lobby_id, :string, required: true
  attr :messages, :list, required: true
  attr :me, :string, required: true

  defp chat_box(assigns) do
    ~H"""
    <div class="border border-[#1c212b] bg-[#0a0c10]">
      <%!-- newest-first + col-reverse keeps the view pinned to the latest message --%>
      <div class="flex h-40 flex-col-reverse gap-1.5 overflow-y-auto px-3 py-2">
        <div :if={@messages == []} class="font-code text-[13px] text-[#566175]">
          No messages yet. Say hi.
        </div>
        <div :for={message <- @messages} class="font-code text-[14px] leading-snug">
          <span class={[
            "font-semibold",
            (message.player_id == @me && "text-[#99f7ff]") || "text-[#aab4c4]"
          ]}>
            {message.name}
          </span>
          <span class="text-[#566175]">{format_time(message.at)}</span>
          <span class="text-[#d7dde6]">{message.body}</span>
        </div>
      </div>
      <%!-- the ChatForm hook clears + refocuses the input on the chat_sent event --%>
      <form
        id={"chat-form-#{@lobby_id}"}
        phx-hook="ChatForm"
        phx-submit="send_chat"
        class="flex border-t border-[#1c212b]"
      >
        <input type="hidden" name="lobby_id" value={@lobby_id} />
        <input
          type="text"
          name="body"
          maxlength="240"
          required
          autocomplete="off"
          placeholder="say something…"
          class="flex-1 bg-transparent px-3 py-2 font-code text-[14px] text-[#d7dde6] placeholder-[#566175] outline-none"
        />
        <button
          type="submit"
          class="px-4 font-code text-[13px] uppercase tracking-[0.2em] text-[#99f7ff] transition hover:bg-[#99f7ff]/10"
        >
          Send
        </button>
      </form>
    </div>
    """
  end

  ## Render

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <:header>
        <.stat label="On site" value={to_string(@online)} accent />
      </:header>
      <div class="space-y-4">
        <%!-- callsign + alarm sound, one always-on strip --%>
        <div class="flex flex-wrap items-center gap-x-6 gap-y-2 border border-[#1c212b] bg-[#10141b] px-4 py-2">
          <form
            :if={@snap.name}
            phx-submit="set_name"
            class="flex items-center gap-2"
            title="callsign assigned at random — change it if you like"
          >
            <span class="font-code text-[13px] uppercase tracking-[0.2em] text-[#7f8a9c]">
              Callsign
            </span>
            <input
              id="callsign-input"
              type="text"
              name="name"
              value={@snap.name}
              maxlength="24"
              required
              autocomplete="off"
              class="w-36 border border-[#2a3140] bg-[#0a0c10] px-2 py-0.5 font-display text-sm font-bold text-[#99f7ff] outline-none transition-colors focus:border-[#99f7ff]"
            />
            <button
              type="submit"
              class="border border-[#2a3140] px-2.5 py-0.5 font-code text-[12px] uppercase tracking-[0.2em] text-[#aab4c4] transition hover:border-[#99f7ff] hover:text-[#99f7ff]"
            >
              Rename
            </button>
          </form>
          <div class="ml-auto flex items-center gap-3">
            <button
              phx-click={JS.dispatch("tyrmm:sound-check")}
              title="play the ready check alarm — also unlocks audio for this tab"
              class="flex cursor-pointer items-center gap-1.5 border border-[#2a3140] px-3 py-1 font-code text-[12px] uppercase tracking-[0.2em] text-[#aab4c4] transition hover:border-[#99f7ff] hover:text-[#99f7ff]"
            >
              <.icon name="hero-speaker-wave-micro" class="size-3.5" /> Try ready check sound
            </button>
            <input
              id="alarm-volume"
              phx-hook="AlarmVolume"
              phx-update="ignore"
              type="range"
              min="0"
              max="1"
              step="0.05"
              title="ready check alarm volume"
              class="w-24 cursor-pointer accent-[#99f7ff]"
            />
          </div>
          <div class="flex basis-full flex-wrap items-center gap-x-3 gap-y-1">
            <button
              id="keep-awake-toggle"
              phx-hook="KeepAwakeToggle"
              phx-update="ignore"
              type="button"
              class="flex cursor-pointer items-center gap-1.5 border border-[#2a3140] px-3 py-1 font-code text-[12px] uppercase tracking-[0.2em] text-[#aab4c4] transition hover:border-[#99f7ff] hover:text-[#99f7ff]"
            >
              <.icon name="hero-bolt-micro" class="size-3.5" /> Keep tab awake:
              <span data-state>off</span>
            </button>
            <span class="font-code text-[12px] text-[#7f8a9c]">
              plays silent audio so the browser doesn't put this tab to sleep —
              ready check alarms stay on time while you're in another window.
              <span class="text-[#f0a63a]">PC only</span>
              — mobile browsers suspend
              background tabs regardless
            </span>
          </div>
        </div>

        <%!-- lobby view: you're seated, this is your whole world now --%>
        <.panel
          :if={@snap.lobby}
          label={
            (@snap.lobby.mine && "Your lobby") || "#{@snap.lobby.host}'s lobby — you have a seat"
          }
        >
          <:corner><.region_badge region={@snap.lobby.region} /></:corner>

          <%!-- keeps the screen awake while you hold a seat --%>
          <div id="lobby-wake-lock" phx-hook="KeepAwake" class="hidden"></div>

          <%!-- ready check banner --%>
          <div
            :if={@snap.lobby.ready_check}
            class={[
              "mb-4 border p-3",
              @snap.lobby.ready_check.status == :running && "border-[#f0a63a]/60 bg-[#f0a63a]/5",
              @snap.lobby.ready_check.status == :passed && "border-[#99f7ff]/60 bg-[#99f7ff]/5",
              @snap.lobby.ready_check.status == :failed && "border-[#f0554d]/60 bg-[#f0554d]/5"
            ]}
          >
            <%!-- mounted only while you still owe a ready; the hook repeats the
                 alarm until this unmounts (you readied or the check ended) --%>
            <span
              :if={@snap.lobby.ready_check.status == :running && !@snap.lobby.ready_check.me_ready}
              id="ready-alarm"
              phx-hook="ReadyAlarm"
              class="hidden"
            ></span>
            <div class="flex flex-wrap items-center gap-x-4 gap-y-2">
              <span
                :if={@snap.lobby.ready_check.status == :running}
                class="font-display text-sm font-bold uppercase tracking-[0.25em] text-[#f0a63a]"
              >
                Ready check
                <span class={[
                  "ml-2 tabular-nums",
                  seconds_left(@snap.lobby.ready_check.deadline, @now) <= 10 && "text-[#f0554d]"
                ]}>
                  {seconds_left(@snap.lobby.ready_check.deadline, @now)}s
                </span>
              </span>
              <span
                :if={@snap.lobby.ready_check.status == :passed}
                class="font-display text-sm font-bold uppercase tracking-[0.25em] text-[#99f7ff]"
              >
                All ready — see you in game
              </span>
              <span
                :if={@snap.lobby.ready_check.status == :failed}
                class="font-display text-sm font-bold uppercase tracking-[0.25em] text-[#f0554d]"
              >
                Ready check failed
              </span>
              <span class="font-code text-[14px] tabular-nums text-[#aab4c4]">
                {@snap.lobby.ready_check.ready_count}/{@snap.lobby.ready_check.total} ready
              </span>
              <button
                :if={@snap.lobby.ready_check.status == :running && !@snap.lobby.ready_check.me_ready}
                phx-click="ready_up"
                class="ml-auto border border-[#99f7ff] bg-[#99f7ff] px-5 py-1.5 font-display text-sm font-bold uppercase tracking-[0.25em] text-[#0a0c10] transition hover:bg-transparent hover:text-[#99f7ff]"
              >
                I'm ready
              </button>
              <span
                :if={@snap.lobby.ready_check.status == :running && @snap.lobby.ready_check.me_ready}
                class="ml-auto font-code text-[13px] uppercase tracking-[0.2em] text-[#99f7ff]"
              >
                ready<span class="animate-blink">_</span>
              </span>
            </div>
            <div class="mt-2 flex flex-wrap gap-1.5">
              <span
                :for={player <- @snap.lobby.ready_check.players}
                class={[
                  "border px-2 py-0.5 font-code text-[13px]",
                  (player.ready && "border-[#99f7ff]/50 text-[#99f7ff]") ||
                    "border-[#2a3140] text-[#7f8a9c]"
                ]}
              >
                {(player.ready && "✓ ") || ""}{player.name}
              </span>
            </div>
          </div>

          <div class="space-y-4">
            <div class="space-y-3">
              <div class="flex items-baseline justify-between">
                <div>
                  <div class="font-code text-[12px] uppercase tracking-[0.25em] text-[#7f8a9c]">
                    In-game code
                  </div>
                  <div class="select-all font-display text-xl font-bold tracking-[0.3em] text-[#99f7ff]">
                    {@snap.lobby.code}
                  </div>
                  <button
                    phx-click={JS.dispatch("tyrmm:copy")}
                    data-copy={url(~p"/join/#{@snap.lobby.code}")}
                    title="opening this link takes a seat in your lobby"
                    class="mt-1 flex cursor-pointer items-center gap-1.5 border border-[#2a3140] px-2 py-0.5 font-code text-[12px] uppercase tracking-[0.2em] text-[#aab4c4] transition hover:border-[#99f7ff] hover:text-[#99f7ff]"
                  >
                    <.icon name="hero-link-micro" class="size-3.5" /> Copy join link
                  </button>
                </div>
                <div class="text-right">
                  <div class="font-code text-[12px] uppercase tracking-[0.25em] text-[#7f8a9c]">
                    Seats
                  </div>
                  <div class="font-display text-xl font-bold tabular-nums">
                    {@snap.lobby.seats}<span class="text-[#7f8a9c]">/16</span>
                  </div>
                </div>
              </div>
              <div class="h-1.5 w-full bg-[#1c212b]">
                <div
                  class="h-full bg-[#99f7ff] transition-all duration-500"
                  style={"width: #{round(@snap.lobby.seats / 16 * 100)}%"}
                >
                </div>
              </div>
              <div class="flex flex-wrap gap-1.5">
                <span
                  :for={player <- @snap.lobby.players}
                  class={["border px-2 py-0.5 font-code text-[13px]", seat_chip_class(player)]}
                >
                  {player.name}
                </span>
              </div>
              <div class="flex items-center justify-between">
                <span class="font-code text-[13px] uppercase tracking-[0.2em] text-[#aab4c4]">
                  <span :if={@snap.lobby.status == :in_game} class="text-[#f0a63a]">
                    in game<span class="animate-blink">_</span>
                  </span>
                  <span :if={@snap.lobby.status == :gathering && !@snap.lobby.full}>
                    gathering<span class="animate-blink">_</span>
                  </span>
                  <span
                    :if={@snap.lobby.status == :gathering && @snap.lobby.full}
                    class="text-[#99f7ff]"
                  >
                    full — see you in game
                  </span>
                </span>
                <span :if={@snap.lobby.mine} class="flex items-center gap-2">
                  <button
                    :if={@snap.lobby.status == :gathering}
                    phx-click="set_status"
                    phx-value-status="in_game"
                    class="border border-[#c8f542]/60 px-4 py-1.5 font-code text-[13px] uppercase tracking-[0.2em] text-[#c8f542] transition hover:bg-[#c8f542] hover:text-[#0a0c10]"
                  >
                    Start game
                  </button>
                  <button
                    :if={@snap.lobby.status == :in_game}
                    phx-click="set_status"
                    phx-value-status="gathering"
                    class="border border-[#2a3140] px-4 py-1.5 font-code text-[13px] uppercase tracking-[0.2em] text-[#aab4c4] transition hover:border-[#99f7ff] hover:text-[#99f7ff]"
                  >
                    Back to gathering
                  </button>
                  <button
                    :if={!match?(%{status: :running}, @snap.lobby.ready_check)}
                    phx-click="start_ready_check"
                    class="border border-[#f0a63a]/60 px-4 py-1.5 font-code text-[13px] uppercase tracking-[0.2em] text-[#f0a63a] transition hover:bg-[#f0a63a] hover:text-[#0a0c10]"
                  >
                    Ready check
                  </button>
                  <button
                    phx-click="close_lobby"
                    class="border border-[#f0554d]/50 px-4 py-1.5 font-code text-[13px] uppercase tracking-[0.2em] text-[#f0554d] transition hover:bg-[#f0554d] hover:text-[#0a0c10]"
                  >
                    Close lobby
                  </button>
                </span>
                <button
                  :if={!@snap.lobby.mine}
                  phx-click="leave_lobby"
                  class="border border-[#f0554d]/50 px-4 py-1.5 font-code text-[13px] uppercase tracking-[0.2em] text-[#f0554d] transition hover:bg-[#f0554d] hover:text-[#0a0c10]"
                >
                  Give up seat
                </button>
              </div>
            </div>
            <div>
              <div class="mb-2 font-code text-[12px] uppercase tracking-[0.25em] text-[#7f8a9c]">
                Lobby chat — seated players only
              </div>
              <.chat_box lobby_id={@snap.lobby.id} messages={@snap.lobby.messages} me={@player_id} />
            </div>
          </div>
          <div :if={@snap.lobby.mine} class="mt-3 flex flex-wrap gap-x-6 gap-y-2">
            <label class="flex cursor-pointer items-center gap-2.5">
              <input
                type="checkbox"
                checked={@snap.lobby.open}
                phx-click="toggle_open"
                class="size-4 cursor-pointer accent-[#99f7ff]"
              />
              <span class="font-code text-[13px] text-[#aab4c4]">
                <span class="font-semibold text-[#d7dde6]">Free to join</span>
                — joinable from the list, no code needed
              </span>
            </label>
            <label class="flex cursor-pointer items-center gap-2.5">
              <input
                type="checkbox"
                checked={@snap.lobby.auto_ready}
                phx-click="toggle_auto_ready"
                class="size-4 cursor-pointer accent-[#99f7ff]"
              />
              <span class="font-code text-[13px] text-[#aab4c4]">
                <span class="font-semibold text-[#d7dde6]">Auto ready check</span>
                — starts when the lobby fills to 16
              </span>
            </label>
          </div>
          <form :if={@snap.lobby.mine} phx-submit="set_description" class="mt-3 flex gap-2">
            <input
              id="lobby-description-input"
              type="text"
              name="description"
              value={@snap.lobby.description}
              maxlength="120"
              autocomplete="off"
              placeholder="lobby description — shown in the lobby list (leave empty to clear)"
              class="min-w-0 flex-1 border border-[#2a3140] bg-[#0a0c10] px-3 py-1.5 font-code text-[14px] text-[#d7dde6] placeholder-[#566175] outline-none transition-colors focus:border-[#99f7ff]"
            />
            <button
              type="submit"
              class="border border-[#2a3140] px-4 py-1.5 font-code text-[12px] uppercase tracking-[0.2em] text-[#aab4c4] transition hover:border-[#99f7ff] hover:text-[#99f7ff]"
            >
              Update
            </button>
          </form>
          <p
            :if={!@snap.lobby.mine && @snap.lobby.description}
            class="mt-4 font-code text-[14px] italic text-[#aab4c4]"
          >
            “{@snap.lobby.description}”
          </p>
          <div class="mt-3 border-t border-[#1c212b] pt-3">
            <div class="mb-2 flex items-baseline gap-10 font-code text-[12px] uppercase tracking-[0.25em] text-[#7f8a9c]">
              Map vote
              <span :if={@snap.lobby.vote.top_map}>
                leading: <span class="text-[#f0a63a]">{@snap.lobby.vote.top_map}</span>
              </span>
            </div>
            <.map_vote lobby_id={@snap.lobby.id} vote={@snap.lobby.vote} />
          </div>
        </.panel>

        <%!-- lobby actions: only when not seated anywhere --%>
        <div :if={@snap.name && is_nil(@snap.lobby)} class="space-y-4">
          <%!-- host a lobby: collapsible --%>
          <section class="border border-[#1c212b] bg-[#10141b]">
            <button
              type="button"
              phx-click={
                JS.toggle_class("grid-rows-[1fr] visible", to: "#host-lobby-body")
                |> JS.toggle_class("rotate-90", to: "#host-lobby-chevron")
              }
              class="group flex w-full cursor-pointer items-center justify-between px-4 py-2 transition hover:bg-[#99f7ff]/10"
            >
              <h2 class="font-display text-[13px] font-semibold uppercase tracking-[0.3em] text-[#aab4c4] transition-colors group-hover:text-[#99f7ff]">
                Host a lobby
              </h2>
              <span id="host-lobby-chevron" class="flex transition-transform">
                <.icon
                  name="hero-chevron-right-micro"
                  class="size-4 text-[#7f8a9c] transition-colors group-hover:text-[#99f7ff]"
                />
              </span>
            </button>
            <%!-- rows 0fr↔1fr animates height; invisible keeps collapsed fields unfocusable --%>
            <div
              id="host-lobby-body"
              class="invisible grid grid-rows-[0fr] transition-[grid-template-rows,visibility] duration-200 ease-out"
            >
              <div class="overflow-hidden">
                <div class="border-t border-[#1c212b] p-4">
                  <form phx-submit="create_lobby" class="space-y-3">
                    <label class="block">
                      <span class="mb-1 block font-code text-[13px] uppercase tracking-[0.25em] text-[#7f8a9c]">
                        In-game room code
                      </span>
                      <input
                        type="text"
                        name="code"
                        required
                        autocomplete="off"
                        pattern="[a-zA-Z0-9]{4,12}"
                        title="4–12 letters or digits"
                        placeholder="PASTE CODE"
                        class="w-full border border-[#2a3140] bg-[#0a0c10] px-3 py-1.5 font-code text-sm uppercase tracking-[0.3em] text-[#99f7ff] placeholder-[#566175] outline-none transition-colors focus:border-[#99f7ff]"
                      />
                    </label>
                    <div>
                      <span class="mb-1 block font-code text-[13px] uppercase tracking-[0.25em] text-[#7f8a9c]">
                        Region
                      </span>
                      <div class="flex gap-2">
                        <label class="flex-1 cursor-pointer">
                          <input type="radio" name="region" value="na" required class="peer sr-only" />
                          <span class="block border border-[#2a3140] px-3 py-1.5 text-center font-display text-sm font-semibold uppercase tracking-[0.2em] text-[#aab4c4] transition peer-checked:border-[#f0a63a] peer-checked:bg-[#f0a63a]/10 peer-checked:text-[#f0a63a]">
                            NA
                          </span>
                        </label>
                        <label class="flex-1 cursor-pointer">
                          <input type="radio" name="region" value="eu" class="peer sr-only" />
                          <span class="block border border-[#2a3140] px-3 py-1.5 text-center font-display text-sm font-semibold uppercase tracking-[0.2em] text-[#aab4c4] transition peer-checked:border-[#4ac6f5] peer-checked:bg-[#4ac6f5]/10 peer-checked:text-[#4ac6f5]">
                            EU
                          </span>
                        </label>
                      </div>
                    </div>
                    <label class="block">
                      <span class="mb-1 block font-code text-[13px] uppercase tracking-[0.25em] text-[#7f8a9c]">
                        Description <span class="text-[#566175]">(optional)</span>
                      </span>
                      <input
                        type="text"
                        name="description"
                        maxlength="120"
                        autocomplete="off"
                        placeholder="e.g. chill scrims, mics required"
                        class="w-full border border-[#2a3140] bg-[#0a0c10] px-3 py-1.5 font-code text-[14px] text-[#d7dde6] placeholder-[#566175] outline-none transition-colors focus:border-[#99f7ff]"
                      />
                    </label>
                    <label class="flex cursor-pointer items-start gap-2.5">
                      <input
                        type="checkbox"
                        name="open"
                        value="true"
                        checked
                        class="mt-0.5 size-4 cursor-pointer accent-[#99f7ff]"
                      />
                      <span class="font-code text-[13px] leading-relaxed text-[#aab4c4]">
                        <span class="font-semibold text-[#d7dde6]">Free to join</span>
                        — anyone can take a seat straight from the lobby list, no code needed
                      </span>
                    </label>
                    <label class="flex cursor-pointer items-start gap-2.5">
                      <input
                        type="checkbox"
                        name="auto_ready"
                        value="true"
                        checked
                        class="mt-0.5 size-4 cursor-pointer accent-[#99f7ff]"
                      />
                      <span class="font-code text-[13px] leading-relaxed text-[#aab4c4]">
                        <span class="font-semibold text-[#d7dde6]">Auto ready check</span>
                        — starts when the lobby fills to 16
                      </span>
                    </label>
                    <button
                      type="submit"
                      class="w-full border border-[#99f7ff] px-6 py-2 font-display text-sm font-bold uppercase tracking-[0.2em] text-[#99f7ff] transition hover:bg-[#99f7ff] hover:text-[#0a0c10]"
                    >
                      Open lobby
                    </button>
                  </form>
                </div>
              </div>
            </div>
          </section>
        </div>

        <%!-- lobby board --%>
        <.panel label="Lobbies">
          <:corner>
            <div class="flex flex-wrap items-center gap-x-5 gap-y-1">
              <.stat label="Lobbies" value={to_string(@snap.counts.lobbies)} />
              <.stat label="Seated" value={to_string(@snap.counts.seated)} />
              <form
                :if={@snap.name && is_nil(@snap.lobby)}
                phx-submit="join_lobby"
                class="flex items-center gap-2"
                title="take a seat with an in-game lobby code"
              >
                <input
                  type="text"
                  name="code"
                  required
                  autocomplete="off"
                  pattern="[a-zA-Z0-9]{4,12}"
                  title="4–12 letters or digits"
                  placeholder="LOBBY CODE"
                  class="w-40 border border-[#2a3140] bg-[#0a0c10] px-3 py-1 font-code text-sm uppercase tracking-[0.3em] text-[#99f7ff] placeholder-[#566175] outline-none transition-colors focus:border-[#99f7ff]"
                />
                <button
                  type="submit"
                  class="border border-[#2a3140] px-4 py-1 font-display text-sm font-bold uppercase tracking-[0.2em] text-[#aab4c4] transition hover:border-[#99f7ff] hover:text-[#99f7ff]"
                >
                  Take a seat
                </button>
              </form>
            </div>
          </:corner>
          <div :if={@snap.lobbies == []} class="py-4 text-center font-code text-[14px] text-[#566175]">
            No open lobbies. Host one above.
          </div>
          <table :if={@snap.lobbies != []} class="w-full text-left">
            <thead>
              <tr class="border-b border-[#1c212b] font-code text-[12px] uppercase tracking-[0.25em] text-[#7f8a9c]">
                <th class="pb-2 pr-4 font-normal">Host</th>
                <th class="pb-2 pr-4 font-normal">Region</th>
                <th class="pb-2 pr-4 text-right font-normal">Seats</th>
                <th class="pb-2 text-right font-normal"></th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={lobby <- @snap.lobbies}
                class="border-b border-[#1c212b]/60 font-code text-sm last:border-0"
              >
                <td class="py-2 pr-4">
                  <div>
                    {lobby.host}
                    <span :if={lobby.mine} class="ml-2 text-[12px] uppercase text-[#99f7ff]">
                      you
                    </span>
                    <span :if={lobby.member} class="ml-2 text-[12px] uppercase text-[#99f7ff]">
                      seated
                    </span>
                    <span
                      :if={lobby.status == :in_game}
                      class="ml-2 border border-[#f0a63a]/40 px-1.5 text-[12px] uppercase tracking-[0.15em] text-[#f0a63a]"
                    >
                      in game
                    </span>
                    <span
                      :if={lobby.full}
                      class="ml-2 border border-[#f0554d]/40 px-1.5 text-[12px] uppercase tracking-[0.15em] text-[#f0554d]"
                    >
                      full
                    </span>
                  </div>
                  <div :if={lobby.description} class="mt-0.5 text-[13px] italic text-[#7f8a9c]">
                    {lobby.description}
                  </div>
                </td>
                <td class="py-2 pr-4"><.region_badge region={lobby.region} /></td>
                <td class="py-3 pr-4 text-right tabular-nums">
                  {lobby.seats}<span class="text-[#7f8a9c]">/16</span>
                </td>
                <td class="py-2 text-right">
                  <button
                    :if={
                      lobby.open and not lobby.full and not lobby.mine and not lobby.member and
                        is_nil(@snap.lobby)
                    }
                    phx-click="join_open"
                    phx-value-lobby-id={lobby.id}
                    class="border border-[#99f7ff]/50 px-3 py-1 text-[13px] uppercase tracking-[0.15em] text-[#99f7ff] transition hover:bg-[#99f7ff] hover:text-[#0a0c10]"
                  >
                    Join
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </.panel>
      </div>
    </Layouts.app>
    """
  end
end
