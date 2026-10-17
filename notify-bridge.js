// notify-bridge.js  -  OpenCode plugin (runs inside OpenCode).
//
// It only WATCHES OpenCode's official plugin events and CLASSIFIES them:
//   done   = a task finished and OpenCode is idle, waiting for your next prompt
//   error  = the session reported an error (API/auth/etc.)
//   input  = OpenCode is waiting for you (permission request or a question)
// It then starts alert.ps1 (sound + Telegram). It also writes a small "state" file that
// watchdog.ps1 uses to detect crashes and stalls, which a plugin cannot detect by itself
// (a crashed OpenCode cannot report its own crash).
//
// It never reads or writes your project files. Everything lives in %USERPROFILE%\opencode-notify.

import fs from "node:fs"
import os from "node:os"
import path from "node:path"
import { spawn } from "node:child_process"

const BASE = process.env.OPENCODE_NOTIFY_HOME || path.join(os.homedir(), "opencode-notify")
const STATE_DIR = path.join(BASE, "state")
const LOG_DIR = path.join(BASE, "logs")
const LOG_FILE = path.join(LOG_DIR, "events.log")
const CONFIG_FILE = path.join(BASE, "config.json")
const ALERT_PS1 = path.join(BASE, "alert.ps1")
const WATCHDOG_PS1 = path.join(BASE, "watchdog.ps1")
const STOP_FLAG = path.join(STATE_DIR, "stop-alarm.flag")
const PS_EXE = process.env.OPENCODE_NOTIFY_PS || "powershell.exe" // override is only for testing
const PS_ARGS = ["-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File"]

// Events that fire constantly; they count as "activity" but are not written to the log.
const NOISY = new Set([
  "message.part.updated",
  "message.part.delta",
  "message.updated",
  "session.updated",
  "session.diff",
  "file.watcher.updated",
  "lsp.client.diagnostics",
  "lsp.updated",
  "tui.prompt.append",
  "vcs.branch.updated",
  "todo.updated",
])

function log(line) {
  try {
    fs.mkdirSync(LOG_DIR, { recursive: true })
    try {
      if (fs.statSync(LOG_FILE).size > 1_000_000) fs.renameSync(LOG_FILE, LOG_FILE + ".old")
    } catch {}
    fs.appendFileSync(LOG_FILE, `${new Date().toISOString()} ${line}\n`)
  } catch {}
}

let cfgCache = { at: 0, value: {} }
function cfg() {
  const now = Date.now()
  if (now - cfgCache.at > 10_000) {
    try {
      const raw = fs.readFileSync(CONFIG_FILE, "utf8").replace(/^\uFEFF/, "")
      cfgCache = { at: now, value: JSON.parse(raw) }
    } catch {
      cfgCache = { at: now, value: cfgCache.value }
    }
  }
  return cfgCache.value
}

function sanitize(text) {
  return String(text ?? "")
    .replace(/["\\\r\n\t]/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 300)
}

function fmtDuration(ms) {
  const s = Math.round(ms / 1000)
  const m = Math.floor(s / 60)
  const h = Math.floor(m / 60)
  if (h > 0) return `${h}h ${m % 60}m`
  if (m > 0) return `${m}m ${s % 60}s`
  return `${s}s`
}

function describeError(err) {
  if (!err) return "Unknown error"
  const name = err.name || "Error"
  const msg = err.data?.message || err.message || ""
  return msg ? `${name}: ${msg}` : name
}

function describePermission(p) {
  const what = p.title || p.permission || p.type || "a permission"
  const pat = p.patterns || p.pattern
  const target = Array.isArray(pat) ? pat.join(", ") : pat
  return target ? `${what}: ${target}` : String(what)
}

function brief(p) {
  const keys = ["sessionID", "status", "permission", "type", "title", "pattern", "patterns", "error", "questions"]
  const out = {}
  for (const k of keys) if (p && p[k] !== undefined) out[k] = p[k]
  const s = JSON.stringify(out)
  return s === "{}" ? "" : " " + s.slice(0, 200)
}

export const NotifyBridge = async ({ client, directory }) => {
  const guardKey = "__opencodeNotifyBridge:" + (directory || "")
  if (globalThis[guardKey]) {
    log("plugin already active for this directory; skipping duplicate init")
    return {}
  }
  globalThis[guardKey] = true

  const state = {
    pid: process.pid,
    startedMs: Date.now(),
    project: path.basename(directory || process.cwd()) || "project",
    directory: directory || process.cwd(),
    status: "idle", // idle | busy | waiting | error | exited | crashed
    lastEvent: Date.now(),
    lastEventType: "init",
    activeTool: null,
    waitingSession: null,
    exitCode: null,
  }
  const STATE_FILE = path.join(STATE_DIR, `instance-${process.pid}.json`)

  const childSessions = new Set()
  const mainSessions = new Set()
  let activeTools = 0
  let busySince = 0
  let workSinceIdle = false
  let suppressIdle = null // { why, at }: swallow the single idle event that follows an error / Esc
  let lastAlertKey = ""
  let lastAlertAt = 0
  let flushTimer = null

  // ---------- state file (read by watchdog.ps1) ----------
  function writeState() {
    try {
      fs.mkdirSync(STATE_DIR, { recursive: true })
      fs.writeFileSync(STATE_FILE, JSON.stringify(state))
    } catch {}
  }
  function flush(now = false) {
    if (now) {
      if (flushTimer) clearTimeout(flushTimer)
      flushTimer = null
      writeState()
    } else if (!flushTimer) {
      flushTimer = setTimeout(() => {
        flushTimer = null
        writeState()
      }, 1000)
      flushTimer.unref?.()
    }
  }
  function touch(type) {
    state.lastEvent = Date.now()
    state.lastEventType = type
    flush()
  }
  function setStatus(s) {
    if (state.status !== s) {
      state.status = s
      log(`status -> ${s}`)
    }
  }

  // ---------- actions ----------
  function stopAlarm(why) {
    try {
      fs.mkdirSync(STATE_DIR, { recursive: true })
      fs.writeFileSync(STOP_FLAG, String(Date.now()))
      log(`stop-alarm flag written (${why})`)
    } catch {}
  }

  function alertNow(kind, message) {
    const now = Date.now()
    const key = kind + "|" + message
    if (key === lastAlertKey && now - lastAlertAt < 2000) return
    lastAlertKey = key
    lastAlertAt = now
    const msg = sanitize(`[${state.project}] ${message}`)
    log(`ALERT ${kind}: ${msg}`)
    if (!fs.existsSync(ALERT_PS1)) {
      log(`alert.ps1 not found at ${ALERT_PS1}`)
      return
    }
    try {
      const child = spawn(PS_EXE, [...PS_ARGS, ALERT_PS1, "-Kind", kind, "-SpawnedAt", String(now), "-Message", msg], {
        detached: true,
        stdio: "ignore",
        windowsHide: true,
      })
      child.on("error", (e) => log("could not start alert.ps1: " + e.message))
      child.unref()
    } catch (e) {
      log("could not start alert.ps1: " + (e?.message || e))
    }
  }

  function startWatchdog() {
    if (!fs.existsSync(WATCHDOG_PS1)) {
      log(`watchdog.ps1 not found at ${WATCHDOG_PS1}`)
      return
    }
    try {
      // watchdog.ps1 allows only one copy of itself, so extra launches exit immediately.
      const child = spawn(PS_EXE, [...PS_ARGS, WATCHDOG_PS1], { detached: true, stdio: "ignore", windowsHide: true })
      child.on("error", (e) => log("could not start watchdog.ps1: " + e.message))
      child.unref()
    } catch (e) {
      log("could not start watchdog.ps1: " + (e?.message || e))
    }
  }

  // ---------- helpers ----------
  async function isChild(id) {
    if (!id) return false
    if (childSessions.has(id)) return true
    if (mainSessions.has(id)) return false
    try {
      const r = await client.session.get({ path: { id } })
      const info = r?.data ?? r
      if (info?.parentID) {
        childSessions.add(id)
        return true
      }
      mainSessions.add(id)
    } catch {}
    return false
  }

  function clearWaiting(sessionID, why) {
    if (state.status !== "waiting") return
    if (sessionID && state.waitingSession && sessionID !== state.waitingSession) return
    state.waitingSession = null
    setStatus("busy")
    stopAlarm(why)
    flush(true)
  }

  // ---------- event handlers ----------
  async function onBusy(sessionID, detail) {
    if (await isChild(sessionID)) return
    workSinceIdle = true
    if (state.status === "idle" || state.status === "error") {
      busySince = Date.now()
      suppressIdle = null
      setStatus("busy")
      stopAlarm("new work started")
    }
    if (detail) log(`retrying: ${detail}`)
    flush(true)
  }

  async function onIdle(sessionID) {
    if (await isChild(sessionID)) return
    const hadWork = workSinceIdle
    const took = busySince ? Date.now() - busySince : 0
    workSinceIdle = false
    busySince = 0
    activeTools = 0
    state.activeTool = null
    state.waitingSession = null
    setStatus("idle")
    flush(true)

    const pending = suppressIdle
    suppressIdle = null
    if (pending && Date.now() - pending.at < 15_000) return log(`idle after ${pending.why}: no 'done' alert`)
    if (!hadWork) return
    const minMs = Number(cfg().minTaskSeconds ?? 10) * 1000
    if (took && took < minMs) return log(`task took ${fmtDuration(took)} (< minTaskSeconds): no alert`)
    alertNow(
      "done",
      took
        ? `Task finished after ${fmtDuration(took)}. Waiting for your next prompt.`
        : "Task finished. Waiting for your next prompt.",
    )
  }

  async function onError(p) {
    const err = p.error
    if (err?.name === "MessageAbortedError") {
      suppressIdle = { why: "you pressed Esc", at: Date.now() }
      workSinceIdle = false
      log("session aborted by the user")
      return
    }
    if (p.sessionID && (await isChild(p.sessionID))) return log("error inside a sub-agent session; ignored")
    suppressIdle = { why: "an error", at: Date.now() }
    setStatus("error")
    flush(true)
    alertNow("error", describeError(err))
  }

  function onPermission(p) {
    state.waitingSession = p.sessionID || null
    setStatus("waiting")
    flush(true)
    alertNow("input", `Waiting for your approval: ${describePermission(p)}`)
  }

  function onQuestion(p) {
    state.waitingSession = p.sessionID || null
    setStatus("waiting")
    flush(true)
    const q = p.questions?.[0]?.question || p.question || "OpenCode has a question for you"
    alertNow("input", `Waiting for your answer: ${q}`)
  }

  async function handle(event) {
    const type = event?.type || "unknown"
    const p = event?.properties || {}
    touch(type)
    if (!NOISY.has(type)) log(type + brief(p))

    switch (type) {
      case "session.created":
      case "session.updated": {
        const info = p.info
        if (info?.id) (info.parentID ? childSessions : mainSessions).add(info.id)
        break
      }
      case "session.status": {
        const t = p.status?.type
        if (t === "busy") await onBusy(p.sessionID)
        else if (t === "retry") await onBusy(p.sessionID, p.status?.message)
        else if (t === "idle") await onIdle(p.sessionID)
        break
      }
      case "session.idle":
        await onIdle(p.sessionID)
        break
      case "session.error":
        await onError(p)
        break
      case "permission.asked":
      case "permission.updated": // older OpenCode versions used this name
        onPermission(p)
        break
      case "permission.replied":
        clearWaiting(p.sessionID, "permission answered")
        break
      case "question.asked":
        onQuestion(p)
        break
      case "question.replied":
      case "question.rejected":
        clearWaiting(p.sessionID, "question answered")
        break
    }
  }

  // ---------- exit detection ----------
  // A normal quit runs this handler; a hard crash/kill cannot, which is exactly how
  // watchdog.ps1 tells them apart (process gone + state was busy/waiting = crash).
  process.on("exit", (code) => {
    try {
      const wasWorking = state.status === "busy" || state.status === "waiting"
      const clean = code === 0 || code === 130 || code === 143
      state.exitCode = code
      state.status = wasWorking && !clean ? "crashed" : "exited"
      state.lastEvent = Date.now()
      fs.writeFileSync(STATE_FILE, JSON.stringify(state))
    } catch {}
  })

  writeState()
  startWatchdog()
  log(`plugin loaded: pid=${process.pid} project=${state.project} dir=${state.directory}`)

  return {
    event: async ({ event }) => {
      try {
        await handle(event)
      } catch (e) {
        log("event handler error: " + (e?.message || e))
      }
    },
    "tool.execute.before": async (input) => {
      try {
        activeTools++
        state.activeTool = input?.tool || "tool"
        touch("tool.execute.before")
        if (state.status === "waiting") {
          clearWaiting(input?.sessionID, "agent resumed")
        } else if (state.status !== "busy") {
          busySince = busySince || Date.now()
          workSinceIdle = true
          setStatus("busy")
          stopAlarm("agent resumed")
          flush(true)
        }
      } catch {}
    },
    "tool.execute.after": async () => {
      try {
        activeTools = Math.max(0, activeTools - 1)
        if (activeTools === 0) state.activeTool = null
        touch("tool.execute.after")
      } catch {}
    },
  }
}
