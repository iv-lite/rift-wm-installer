-- lib/displays.lua — display navigation: focus/move to the previous/next
-- display, including empty displays and 3+ display setups.
--
-- Cmd+Ctrl+←/→ shift focus to another display without moving the window.
-- Cmd+Ctrl+Shift+←/→ moves the focused window to the previous/next display
-- and follows it.
--
-- Focus is delegated entirely to the compiled
-- ~/.config/mac-scrolling-wm/helpers/focus-display helper (see that file):
-- it enumerates displays and the mouse's current one via CoreGraphics, asks
-- the running paneru daemon over IPC (`paneru query on-screen`) which
-- window (if any) belongs to the target display, and warps the pointer
-- there. Being compiled rather than run as an ephemeral `swift -e` script
-- (like move/geometry/mouse helpers below still are) matters here
-- specifically: focus is the far more frequently pressed of the two
-- shortcuts, and the JIT-compile tax of an ephemeral script (commonly
-- 150-400ms) was the dominant cost of every keypress. focus_display below
-- is therefore just a thin dispatch into that helper, guarded by MOVE_BUSY.
--
-- Move is also fully delegated to compiled helpers — both the 2-display
-- path (paneru's own `window nextdisplay` via CLI) and the 3+ display
-- path (move-display, which handles the full float→teleport→re-tile
-- sequence via CLI round-trips). This is because paneru batches all
-- `paneru.run`/`ws:focus` commands in a Lua-side outbox that is only
-- flushed to the ECS *after the keybind dispatch returns* (worker.rs
-- Task::finish), so any in-dispatch poll of `paneru.query_json("state")`
-- can never observe the effect of a `paneru.run` within the same
-- dispatch — the poll always reads pre-command state and times out. CLI
-- commands, by contrast, are separate Mach port messages that the daemon
-- processes independently; by the time the next CLI invocation (query)
-- arrives, the previous command has been applied. A short poll with
-- retries covers the edge case where the daemon's frame hasn't run yet.
--
-- The move never resizes or maximizes the window — it keeps whatever size
-- it had before, on either display — and never changes its tiled/floating
-- disposition either: a window that was tiled comes back tiled; a window
-- the user had deliberately left floating (a scratchpad, a picture-in-
-- picture-style utility window) comes back floating.
--
-- While a move is mid-flight (3+ displays only — the 2-display path never
-- floats) the focused window is *floating*. MOVE_BUSY blocks a second
-- dispatch from starting while one is already in flight, so rapid re-presses
-- can't race each other or compute targets off a stale "current" display.

local log = require("lib.log").log
local query = require("lib.query")
local query_active_safe = query.active
local query_state_safe = query.state
local find_window = query.find_window

-- Helpers (see helpers/):
--   focus-display   — compiled: focus a display via CG + paneru IPC (query on-screen)
--   move-display    — compiled: full move sequence (float, teleport, re-tile) via CLI
--   display-geometry — real CG frames of every online display, empties included
--   mouse-display   — which display id currently has the pointer
local HELPERS_DIR = os.getenv("HOME") .. "/.config/mac-scrolling-wm/helpers/"
local FOCUS_HELPER = HELPERS_DIR .. "focus-display"
local MOVE_HELPER = HELPERS_DIR .. "move-display"
local GEOM_HELPER = HELPERS_DIR .. "display-geometry"
local MOUSE_HELPER = HELPERS_DIR .. "mouse-display"

-- Which display id currently has the mouse pointer, or nil if the helper
-- failed. A plain synchronous `paneru.exec` call — no in-process query API.
local function current_display_id()
  local ok, res = pcall(paneru.exec, MOUSE_HELPER, {})
  if not ok or not res or res.code ~= 0 then return nil end
  return tonumber((res.stdout or ""):match("%d+"))
end

-- ─── Display geometry cache ───────────────────────────────────────────────
-- Paneru's Lua `display_of` resolves a display by *membership*, so a monitor
-- with no windows is invisible to it and navigation cannot reach it. The real
-- display list (all online displays, cached here and refreshed on display
-- events / on a detected geometry mismatch) is what ordering and targeting use.
local DISPLAYS = {}      -- display_id -> { id, x, y, width, height }
local ORDERED_IDS = {}   -- display ids in geometric order (y, then x, ascending)
local GEOM_STALE = true

local function sort_ordered_ids()
  table.sort(ORDERED_IDS, function(a, b)
    if DISPLAYS[a].y ~= DISPLAYS[b].y then return DISPLAYS[a].y < DISPLAYS[b].y end
    return DISPLAYS[a].x < DISPLAYS[b].x
  end)
end

local function refresh_geometry()
  local ok, res = pcall(paneru.exec, GEOM_HELPER, {})
  if not ok or not res or res.code ~= 0 then return false end
  local t, ids = {}, {}
  for line in (res.stdout or ""):gmatch("[^\r\n]+") do
    local id, x, y, w, h = line:match("(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)")
    if id then
      id, x, y, w, h = tonumber(id), tonumber(x), tonumber(y), tonumber(w), tonumber(h)
      t[id] = { id = id, x = x, y = y, width = w, height = h }
      ids[#ids + 1] = id
    end
  end
  if #ids == 0 then return false end
  DISPLAYS, ORDERED_IDS, GEOM_STALE = t, ids, false
  sort_ordered_ids()
  return true
end

-- Re-read geometry when the cached set went stale, or when any window sits on
-- a display we know nothing about (a display appeared outside an event).
local function ensure_geometry(ws)
  if GEOM_STALE then
    if refresh_geometry() then return end
  else
    for _, w in ipairs(ws:windows()) do
      local d = ws:display_of(w.id)
      if d and not DISPLAYS[d.id] then
        GEOM_STALE = true
        refresh_geometry()
        return
      end
    end
  end
end

-- Geometric display ordering (all physical displays, empty ones included).
local function ordered_displays(ws)
  ensure_geometry(ws)
  if #ORDERED_IDS >= 2 then return ORDERED_IDS end
  -- geometry helper unavailable: fall back to window-derived ordering
  local displays = {}
  for _, w in ipairs(ws:windows()) do
    local d = ws:display_of(w.id)
    if d and not displays[d.id] then
      displays[d.id] = { id = d.id, x = d.x, y = d.y }
    end
  end
  local ids = {}
  for id in pairs(displays) do ids[#ids + 1] = id end
  table.sort(ids, function(a, b)
    if displays[a].y ~= displays[b].y then return displays[a].y < displays[b].y end
    return displays[a].x < displays[b].x
  end)
  return ids
end

-- ─── Move busy-guard ───────────────────────────────────────────────────────
-- `ws:window(id).floating` is a snapshot taken once at the start of *this*
-- dispatch — it never reflects a `window manage` toggle a still-in-flight
-- move is in the middle of applying, only what was true before that move's
-- own first await. Two rapid Cmd+Ctrl+Shift+arrow presses could each pass
-- that stale check, both start floating/teleporting the same window to
-- different displays (a visible jiggle: one teleport lands, then the other
-- immediately overwrites it), and their two uncoordinated `window manage`
-- calls (`window manage` toggles tiled/floating, not idempotent) could
-- leave the window stuck floating forever, which then made every later
-- focus/move look "broken" since the stale-floating check never clears on
-- its own. MOVE_BUSY is a plain Lua variable instead: set as the very first
-- statement, before any `paneru.exec`/`query_*` await, so a second dispatch
-- that starts while the first is still in flight sees it immediately — no
-- yield happens between the check and the set.
local MOVE_BUSY = false

-- Focus is a thin dispatch into the compiled focus-display helper (see that
-- file for the full logic: CG display enumeration, mouse-based "current
-- display", the paneru IPC lookup of a window on the target display, and
-- the warp/synthetic-move that makes focus_follows_mouse pick it up). The
-- only thing worth doing in-process is the MOVE_BUSY check — no reason to
-- pay a subprocess launch just to find out a move is in flight.
local function focus_display(ws, target)
  if MOVE_BUSY then
    log("focus " .. target .. ": busy (a move is in flight)")
    return
  end
  local ok, res = pcall(paneru.exec, FOCUS_HELPER, { target })
  if not ok or not res or res.code ~= 0 then
    log("focus " .. target .. ": focus-display helper failed" ..
      ((res and res.stderr and res.stderr ~= "") and (": " .. res.stderr) or ""))
  end
end

local function display_frame(ws, display_id)
  ensure_geometry(ws)
  local t = DISPLAYS[display_id]
  if t then return t end
  for _, w in ipairs(ws:windows()) do
    local d = ws:display_of(w.id)
    if d and d.id == display_id then return d end
  end
end

-- Poll `find_window(query_state_safe(), wid)` until `predicate(w)` holds
-- or the budget runs out. Returns true if the predicate was satisfied.
-- Used only by the 2-display settle path (the 3+ path is fully handled
-- by the move-display helper, which does its own CLI-based polling).
local function poll_window(wid, ticks, predicate)
  for _ = 1, ticks do
    local w = find_window(query_state_safe(), wid)
    if w and predicate(w) then return true end
  end
  return false
end

local function move_to_display(ws, target)
  if MOVE_BUSY then
    log("move " .. target .. ": busy (another move already in flight)")
    return
  end
  MOVE_BUSY = true
  local ok, err = pcall(function()
    local focused = ws:focused()
    if not focused then
      log("move " .. target .. ": no focused window")
      return
    end
    -- The window's disposition right now, before anything below touches
    -- it — this move must restore exactly this afterward, never force it
    -- tiled just because it changed displays.
    local w0 = find_window(query_state_safe(), focused)
    local was_floating = w0 ~= nil and w0.floating
    local ids = ordered_displays(ws)
    if #ids < 2 then
      log("move " .. target .. ": fewer than 2 displays (" .. #ids .. ")")
      return
    end
    local cur_id = current_display_id()
    if not cur_id then
      log("move " .. target .. ": mouse-display helper failed")
      return
    end
    if not DISPLAYS[cur_id] then
      log("move " .. target .. ": cur_id " .. cur_id .. " not in geometry cache, refreshing")
      GEOM_STALE = true
      if refresh_geometry() then ids = ORDERED_IDS end
    end
    local idx
    for i, id in ipairs(ids) do if id == cur_id then idx = i break end end
    if not idx then
      log("move " .. target .. ": cur_id " .. cur_id .. " not in ids [" .. table.concat(ids, ",") .. "] even after refresh")
      return
    end
    local n = #ids
    local step = (target == "previous") and (n - 1) or 1
    local target_id = ids[((idx - 1 + step) % n) + 1]
    log(string.format("move %s: cur=%d idx=%d/%d ids=[%s] -> target=%d",
      target, cur_id, idx, n, table.concat(ids, ","), target_id))
    if target_id == cur_id then
      log("move " .. target .. ": target == current, nothing to do")
      return
    end
    if n == 2 then
      -- 2-display path: `paneru window nextdisplay` via CLI (not
      -- paneru.run, which would batch until dispatch-end and make
      -- the poll below see stale state). Poll for display_id to
      -- confirm the window arrived on the target.
      local exec_ok, res = pcall(paneru.exec, "paneru", { "send-cmd", "window", "nextdisplay" })
      if not exec_ok or not res or res.code ~= 0 then
        log("move " .. target .. ": nextdisplay CLI failed")
        paneru.flash("move display: nextdisplay failed", 3.0)
        return
      end
      local settled = poll_window(focused, 200,
        function(w) return w.display_id == target_id end)
      if not settled then
        log("move " .. target .. ": window " .. focused .. " never reported display " .. target_id)
        paneru.flash("move display: failed to settle on target display", 3.0)
      end
      return
    end
    -- 3+ display path: the move-display helper owns the full sequence
    -- (float, AX teleport, click, re-tile) via CLI round-trips, each
    -- processed independently by the daemon. Lua just checks the exit code.
    local t = display_frame(ws, target_id)
    if not t then
      log("move " .. target .. ": no geometry for target display " .. target_id)
      paneru.flash("move display: no geometry for target display", 3.0)
      return
    end
    local exec_ok, res = pcall(paneru.exec, MOVE_HELPER, {
      tostring(focused), tostring(math.floor(t.x)), tostring(math.floor(t.y)),
      tostring(math.floor(t.width)), tostring(math.floor(t.height)),
      was_floating and "1" or "0",
    })
    if not exec_ok or not res or res.code ~= 0 then
      log("move " .. target .. ": move-display failed for window " .. focused ..
        " to display " .. target_id ..
        ((res and res.stderr and res.stderr ~= "") and (": " .. res.stderr) or ""))
      paneru.flash("move display: move failed", 3.0)
      return
    end
    log("move " .. target .. ": window " .. focused .. " moved to display " .. target_id)
  end)
  MOVE_BUSY = false
  if not ok then
    log("move " .. target .. ": internal error: " .. tostring(err))
  end
end

-- Any display event invalidates the geometry cache (re-read on next use).
for _, evt in ipairs({ "display_added", "display_removed", "display_moved",
                        "display_resized", "display_configured", "display_changed" }) do
  paneru.on(evt, function() GEOM_STALE = true end)
end

return {
  focus = focus_display,
  move = move_to_display,
}
