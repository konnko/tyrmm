// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/tyrmm"
import topbar from "../vendor/topbar"

// three-note chirp for ready checks; browsers keep the AudioContext usable
// once it has been resumed from a user gesture (the sound check button)
let audioCtx
let alarmVolume = parseFloat(localStorage.getItem("tyrmm:alarm-volume") ?? "0.5")
function readyAlarm() {
  if (alarmVolume <= 0) return
  try {
    audioCtx = audioCtx || new (window.AudioContext || window.webkitAudioContext)()
    if (audioCtx.state === "suspended") audioCtx.resume()
    const t0 = audioCtx.currentTime
    const peak = 0.24 * alarmVolume
    ;[[880, 0], [1175, 0.2], [1568, 0.4]].forEach(([freq, at]) => {
      const osc = audioCtx.createOscillator()
      const gain = audioCtx.createGain()
      osc.type = "square"
      osc.frequency.value = freq
      gain.gain.setValueAtTime(0.0001, t0 + at)
      gain.gain.exponentialRampToValueAtTime(peak, t0 + at + 0.02)
      gain.gain.exponentialRampToValueAtTime(0.0001, t0 + at + 0.18)
      osc.connect(gain)
      gain.connect(audioCtx.destination)
      osc.start(t0 + at)
      osc.stop(t0 + at + 0.2)
    })
  } catch (_e) {}
}
// a near-silent 40Hz loop marks the tab as playing audio, which exempts it
// from background timer throttling, freezing, and memory-saver discard —
// otherwise the 4s alarm repeat gets clamped to once a minute in hidden tabs
let silentOsc
function startSilence() {
  try {
    audioCtx = audioCtx || new (window.AudioContext || window.webkitAudioContext)()
    if (audioCtx.state === "suspended") audioCtx.resume()
    if (silentOsc) return
    const osc = audioCtx.createOscillator()
    const gain = audioCtx.createGain()
    osc.type = "sine"
    osc.frequency.value = 40
    gain.gain.value = 0.001
    osc.connect(gain)
    gain.connect(audioCtx.destination)
    osc.start()
    silentOsc = osc
  } catch (_e) {}
}
function stopSilence() {
  if (!silentOsc) return
  try {
    silentOsc.stop()
  } catch (_e) {}
  silentOsc = null
}

window.addEventListener("tyrmm:sound-check", readyAlarm)

// copy-to-clipboard for elements carrying data-copy (e.g. the lobby invite link)
window.addEventListener("tyrmm:copy", e => {
  const el = e.target.closest("[data-copy]")
  if (!el) return
  navigator.clipboard.writeText(el.dataset.copy)
  const label = el.lastChild
  const original = label.textContent
  label.textContent = " Copied!"
  setTimeout(() => (label.textContent = original), 1500)
})

// deliberately NOT persisted: browsers refuse audio until the page gets a
// user gesture, so a remembered "on" would silently do nothing after a fresh
// load — instead the player clicks each visit and the click unlocks audio
let keepAwakeEnabled = false

const hooks = {
  // opt-in toggle for the silent keep-alive loop; the click doubles as the
  // user gesture that unlocks audio for the tab. Pulses amber until enabled.
  KeepAwakeToggle: {
    mounted() {
      this.render = () => {
        for (const cls of ["animate-pulse", "border-[#f0a63a]", "text-[#f0a63a]", "bg-[#f0a63a]/10"])
          this.el.classList.toggle(cls, !keepAwakeEnabled)
        for (const cls of ["border-[#99f7ff]", "text-[#99f7ff]", "bg-[#99f7ff]/10"])
          this.el.classList.toggle(cls, keepAwakeEnabled)
        this.el.querySelector("[data-state]").textContent = keepAwakeEnabled ? "on" : "off"
      }
      this.el.addEventListener("click", () => {
        keepAwakeEnabled = !keepAwakeEnabled
        keepAwakeEnabled ? startSilence() : stopSilence()
        this.render()
      })
      // still on after a LiveView reconnect (same page, gesture already given)
      if (keepAwakeEnabled) startSilence()
      this.render()
    },
  },
  // rendered only while a check is running and this player hasn't readied,
  // so the alarm nags every 4s until the element unmounts
  ReadyAlarm: {
    mounted() {
      readyAlarm()
      this.repeat = setInterval(readyAlarm, 4000)
    },
    destroyed() {
      clearInterval(this.repeat)
    },
  },
  // volume for the alarm, remembered per browser
  AlarmVolume: {
    mounted() {
      this.el.value = alarmVolume
      this.el.addEventListener("input", e => {
        alarmVolume = parseFloat(e.target.value) || 0
        localStorage.setItem("tyrmm:alarm-volume", e.target.value)
      })
    },
  },
  // the callsign lives in the browser: restore it to the server on connect
  // (names die with the in-memory server, localStorage outlives it)
  CallsignStore: {
    mounted() {
      this.handleEvent("store_callsign", ({name}) =>
        localStorage.setItem("tyrmm:callsign", name)
      )
      const current = this.el.querySelector("input[name=name]").value
      const stored = localStorage.getItem("tyrmm:callsign")
      if (stored && stored !== current) {
        this.pushEvent("restore_name", {name: stored})
      } else {
        localStorage.setItem("tyrmm:callsign", current)
      }
    },
  },
  // clears the chat input after a successful send, keeping focus for the next message
  ChatForm: {
    mounted() {
      this.handleEvent("chat_sent", () => {
        const input = this.el.querySelector("input[name=body]")
        input.value = ""
        input.focus()
      })
    },
  },
  // holds a screen wake lock while seated in a lobby (visible tabs only —
  // background-tab liveness is the KeepAwakeToggle's silent loop)
  KeepAwake: {
    mounted() {
      this.acquire = async () => {
        try {
          if ("wakeLock" in navigator && document.visibilityState === "visible") {
            this.lock = await navigator.wakeLock.request("screen")
          }
        } catch (_e) {}
      }
      this.onVisibility = () => this.acquire()
      document.addEventListener("visibilitychange", this.onVisibility)
      this.acquire()
    },
    destroyed() {
      document.removeEventListener("visibilitychange", this.onVisibility)
      if (this.lock) this.lock.release().catch(() => {})
    },
  },
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, ...hooks},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

