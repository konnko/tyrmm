---
name: tyrmm-lobbies
description: Use when working on Tyrmm's lobby system (lobbies, seats, chat, map votes, ready checks, the LobbyLive UI, or the Lobbies GenServer). Explains the architecture, hard rules, code patterns, and testing/verification conventions of the current implementation.
---

# Tyrmm lobby system

Tyrmm is a lobby directory for a game's custom-games mode. Hosts paste an in-game
room code, players take seats, coordinate via chat / map votes / ready checks, then
join the custom game in-game with the code. **There is no matchmaking** — a queue +
confirmation system existed and was deliberately scrapped by the user; do not
reintroduce it.

## Hard rules (user-mandated, do not violate)

- **No database at all.** Everything lives in the `Tyrmm.Lobbies` GenServer. The
  user said: "don't use db for anything, just genservers, don't worry about
  memory", and later (2026-08-17) had the entire Ash/Postgres/auth/Oban/
  ErrorTracker skeleton deleted because the deploy target has no Postgres —
  do not add Ecto/repos back. Errors go to server logs only. A shutdown
  backup of lobby state was built and deliberately reverted: restored lobbies
  are pointless because hosts can't reconnect within the disconnect grace.
- **Players are anonymous.** Identity = `player_id` in the session cookie
  (`ensure_player_id` plug in `router.ex`). Names are auto-assigned random
  callsigns (adjective+animal+number), held in the GenServer while the player
  is around (the entry is deleted when the 30s disconnect grace runs out —
  state stays bounded by concurrent players) and mirrored to localStorage
  (`tyrmm:callsign`) by the `CallsignStore` hook, which replays the stored
  name via `restore_name` on connect — so callsigns survive both drops and
  server restarts.
- **Host-only mutations**: description, free-to-join toggle, status
  (gathering/in game), auto-ready toggle, starting ready checks, closing the
  lobby. Always enforce in the server (not just
  the UI) via `hosted_lobby/2`.
- **Seated-only access**: both lobby codes, chat (read AND write — outsider
  snapshots get `messages: []`), and map votes are only for the host + members.
- **One lobby per player in any role** (host or seat), unique site codes among
  open lobbies (guaranteed by generation), 16 seats including the host.
- **Two codes, don't conflate them** (user-mandated): `code` is the generated
  site lobby ID (6 chars, unambiguous alphabet, never user-set) used for
  `join_lobby` and `/join/:code` links; `game_code` is the optional in-game
  room code the host pastes (`set_game_code/2`, clearable, no uniqueness).

## Files

| File | Role |
|---|---|
| `lib/tyrmm/lobbies.ex` | The GenServer: all state, rules, and snapshot building |
| `lib/tyrmm_web/live/lobby_live.ex` | The single LiveView (routes `/` and `/join/:code`) |
| `lib/tyrmm_web/presence.ex` | Phoenix.Presence for the "on site" count |
| `lib/tyrmm_web/components/layouts.ex` | App shell (dark theme baked in, `:header` slot for the top bar) |
| `assets/js/app.js` | All client hooks: alarm audio, wake lock, chat focus, clipboard |
| `assets/css/app.css` | Fonts, `@theme` utilities, grid/scan/blink keyframes |
| `test/tyrmm_web/live/lobby_live_test.exs` | The whole test suite |
| `Dockerfile`, `rel/overlays/bin/server` | Release scaffolding (phx.gen.release --docker) |

Both `TyrmmWeb.Presence` and `Tyrmm.Lobbies` are supervision children in
`application.ex` — changing that file requires an app-server restart
(`restart_app_server` with `supervision_tree_changed`); everything else hot-reloads.
Note: hot-reloading `lobbies.ex` twice can kill the GenServer (old code purge) and
reset dev state — that's normal in dev, not a bug.

## Server architecture (`Tyrmm.Lobbies`)

State:

```elixir
%{
  players: %{player_id => %{name, pids: %{pid => monitor_ref}}},  # one pid per open tab!
  disconnected: %{player_id => grace_timer},     # 30s grace; refresh survives, then cleanup
  lobbies: %{lobby_id => lobby}
}
```

Lobby map: `id` (random url-safe base64), `code` (generated site ID),
`game_code` (nil | uppercased 4–12 alnum), `region` (:na | :eu),
`creator_id`, `members` (list, join order), `open?`, `status` (:gathering |
:in_game, host-only via `set_status/2`, purely informational — joins stay
allowed), `auto_ready?`,
`ready_check` (nil or map below), `description` (nil | ≤120 chars), `votes`
(`%{player_id => map_name}`), `messages` (newest-first, capped 50, ≤240 chars each),
`created_at` (ms).

Ready check: `%{status: :running | :passed | :failed, responses: %{player_id => true},
deadline (ms epoch), timer_ref}`. Nobody is pre-readied — the host must confirm
like everyone else (manual or auto start). Passes when **all currently
seated** are ready (recheck on ready_up AND on seat removal — a leaver can complete
it; a mid-check joiner must also ready). Timeout 30s → :failed. Results display for
15s then `{:clear_ready_check, id}` clears — guarded to never clear a `:running`
check. Nobody is kicked on failure.

Patterns the module relies on:

- Every mutation goes through `handle_call`, returns updated state through
  `broadcast/1` which pushes `:lobbies_updated` on PubSub topic `"lobbies"`.
  LiveViews then re-pull their own personalized snapshot — there is no diffing,
  no per-event payloads. Keep this model; it makes new features one broadcast away.
- `snapshot(player_id)` returns a personalized view: `%{name, lobby (mine, nil if
  none), lobbies (all, each with mine/member flags), counts}`. Per-viewer secrets
  (code, messages) are stripped in `lobby_view/3` — add new secret fields there.
- Liveness: LiveViews call `register(player_id)` on connected mount; the server
  monitors EVERY tab's pid (a player can have several tabs — replacing instead of
  accumulating pids once closed a host's lobby while their other tab watched).
  Grace starts only when the LAST pid dies: DOWN → 30s grace timer →
  `drop_player`: member loses seat (votes + ready responses go too, via
  `remove_seat`), host's lobby closes. DOWN-to-empty and register both
  `broadcast` (seat chips show dropped players red live).
- When a lobby closes (host closed it or dropped), `notify_lobby_closed/3` sends
  `{:lobby_closed, reason}` directly to each connected member's LiveView pid →
  they render it as an error flash. Use this direct-send pattern for any future
  "tell these specific players something" need.
- The `players` list in `lobby_view` is per-player maps `%{name, you, connected,
  ready}` (ready is nil outside a running check) — that drives seat chip colors:
  red = disconnected, amber = owes a ready, lime `#c8f542` = readied, cyan = you.
- Timer messages carry the lobby id and re-check state on arrival (lobby may be
  gone, check may have been replaced) — follow this pattern for any new timer.

## LiveView architecture (`TyrmmWeb.LobbyLive`)

- `refresh/1` re-pulls the snapshot; every event handler ends with it. Server
  errors come back as `{:error, msg}` → `put_flash(:error, msg)`.
- Countdown ticking: `:tick` self-messages every 1s only while a ready check is
  `:running` (`ticking` assign prevents duplicate timers); `seconds_left/2` from a
  ms-epoch `deadline` + `now` assign.
- Page layout (top to bottom): site header (wordmark + "On site" via the layout's
  `:header` slot + live dot); always-on strip (callsign form + "Try ready check
  sound" + volume slider + "Keep tab awake" toggle w/ PC-only caption); seated →
  one full lobby panel (ready-check banner, copy-join-link button (the site
  lobby ID is deliberately NEVER displayed — it only rides the invite link,
  showing it looks like an in-game code and misleads) + amber in-game code
  (host edits / members see "Waiting on host"), seats
  bar, stateful player chips, chat below (stacked, never side-by-side), host
  controls, description, map vote w/ "leading:" in its heading); the Lobbies
  panel (its header corner holds the Lobbies/Seated stats + the join-by-code
  form when unseated); unseated also get the collapsible "Host a lobby" section
  (grid-rows 0fr↔1fr height animation via `JS.toggle_class("grid-rows-[1fr]
  visible")` — animates height so content below glides instead of jumping;
  free-to-join + auto-ready checkboxes default CHECKED).
- Invite links: `/join/:code` → `handle_params` joins on connected mount, flashes
  the outcome, `push_patch`es back to `/` (note: a patch during initial mount
  emits no patch event — don't `assert_patch` it in tests). Own-lobby links are
  silently ignored. The copy button uses `data-copy` + a `tyrmm:copy` window
  listener (JS.dispatch), with a "Copied!" label swap.
- JS hooks (all in `app.js`): `ReadyAlarm` (mounts only while a running check has
  `!me_ready`; chirps on mount + every 4s, unmount stops it), `AlarmVolume`
  (range slider, localStorage `tyrmm:alarm-volume`, `phx-update="ignore"`),
  `KeepAwakeToggle` (opt-in silent 40Hz loop, keeps hidden tabs unthrottled —
  desktop only; deliberately NOT persisted — the enabling click is the
  audio-unlock gesture, so it starts off every load and pulses amber until
  clicked), `KeepAwake` (screen wake lock
  while seated, visible tabs only), `ChatForm` (see below), `CallsignStore`
  (localStorage `tyrmm:callsign`, restores the name on connect). Web-audio alarm is
  synthesized (no asset files); the sound-check button doubles as the audio
  unlock gesture.
- Component conventions: private function components `panel` (header + corner
  slot), `stat`, `region_badge`, `chat_box`, `map_vote`. `<.icon>` takes only
  `name`/`class` — wrap in a span if you need an id.
- Chat input: stable form id + `ChatForm` hook — on successful send the server
  pushes a `chat_sent` event and the hook clears + refocuses the input (an id-bump
  trick was tried first; it cleared but dropped focus).
- Chat scroll pinning: messages stored/rendered newest-first inside a
  `flex-col-reverse` scroll container — newest visually at the bottom, no JS.
- Checkbox toggles (`toggle_open`, `toggle_auto_ready`): `phx-click` on the
  checkbox; checked click sends `%{"value" => "on"}`, unchecked sends no value —
  handlers test `params["value"] == "on"`.

## Design language

Dark "operations deck": bg `#0a0c10`, panel `#10141b`, border `#1c212b`, muted
text `#aab4c4`/`#7f8a9c`/`#566175` (brightened 2026-08-17 — user found the old
greys too faint; don't dim them back), accent ice-cyan `#99f7ff` (user swapped it
in for the original lime `#c8f542` on 2026-08-17; lime survives ONLY on the header
"live" pulse dot and the "readied" seat-chip state — the Start game button that
was the other lime exception was later replaced by the status radio toggle),
warning amber `#f0a63a`
(also the NA region color), danger red `#f0554d`, EU cyan `#4ac6f5`. Fonts:
`font-display` (Chakra Petch, uppercase + wide tracking for headings/numbers) and
`font-code` (IBM Plex Mono, labels/data) — defined in `@theme` in app.css. Square
corners everywhere (no rounding), 1px borders, blinking cursor via `.animate-blink`.
Control heights are unified (2026-08-17): `h-8` for every standard input/button
(buttons use `inline-flex items-center`, no vertical padding), `h-10` for the
big CTAs (Keep tab awake, I'm ready, Open lobby); the status toggle keeps its
oversized `py-2.5`. Don't reintroduce ad-hoc `py-*` control heights.
The user has asked for **compact** UI — small paddings (`p-4`, `py-2`); don't add
airy spacing back. But not *tiny*: label type is 12–14px (bumped from 10–12px
2026-08-17 after the user found it too small — don't shrink it again).

## Maps list

10 hardcoded maps in `@maps` (from the user's game screenshot), ordered
regular → prototypes → Sandbox last (user-chosen order): Divide, Fields, Ravine,
Scorch, Wind Valley, Prototype: Dunes, Prototype: Expanse, Prototype: Ikarus Only,
Prototype: Ruins, Sandbox. Vote = toggle (same map unvotes),
one vote per player, tally + `top_map` computed in `vote_view/2`.

## Testing & verification

- Tests: `test/tyrmm_web/live/lobby_live_test.exs`, `async: false` (shared
  GenServer!). Helpers: `sim_player(id, name)` spawns a sleeping pid and registers
  it; `cleanup(ids)` on_exit leaves/closes for every id. **Pitfalls learned the
  hard way**: don't pattern-match `[lobby] = snapshot(...).lobbies` (leftover
  lobbies from other tests — LiveView-hosted lobbies linger 30s after the test's
  LiveView dies); use `Enum.find` by host/id instead. To test timeouts, send the
  timer message directly: `send(Process.whereis(Tyrmm.Lobbies), {:ready_check_timeout, id})`.
- To test "player dropped" paths: kill the sim pid, sync with
  `:sys.get_state(Lobbies)`, then send `{:drop_player, id}` directly (skips the
  30s grace), and sync again before asserting.
- Always finish with `mix precommit` (compile --warnings-as-errors + format + test).
- Live verification: drive the user's browser with `browser_eval` (page text
  renders UPPERCASE via CSS — compare case-insensitively) and simulate other
  players from `project_eval` with spawned sleeping pids, e.g.
  `Lobbies.register("sim", pid); Lobbies.join_lobby("sim", "CODE")`. Clean up sims
  (leave/close) when done. Don't close/modify a lobby the user opened themselves.

## Release

DB-free `mix release`: `MIX_ENV=prod mix assets.deploy && MIX_ENV=prod mix release`,
run `rel`'s `bin/server` (or the generated `Dockerfile`). Required env:
`SECRET_KEY_BASE`, `PHX_HOST`; optional `PORT`. No migrations, no services.
`assets.deploy` must run `compile` first (colocated-hooks CSS is generated at
compile time — already in the alias, don't remove it). `force_ssl` is on in
`prod.exs` (expects a TLS proxy setting x-forwarded-proto). Changing config
files or deps requires a full dev-server restart, not just a code reload.
