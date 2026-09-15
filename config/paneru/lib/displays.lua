-- lib/displays.lua — display navigation: focus/move to the previous/next
-- display, including empty displays and 3+ display setups.
--
-- Cmd+Ctrl+←/→ shift focus to another display without moving the window,
-- using geometric display order (sorted by macOS arrangement position).
-- Cmd+Ctrl+Shift+←/→ moves the focused window to the previous/next display
-- and follows it.
--
-- "Current display" is whichever display the mouse pointer is on right now
-- (helpers/mouse-display), not the focused window's display: a window is
-- only tracked by Paneru's Lua `display_of` via strip membership, which
-- doesn't exist when the display you're on has no windows at all — that used
-- to make focus-switching impossible to trigger *from* an empty display.
-- Mouse position needs no window to exist, so it works the same whether the
-- current or target display is empty. Comparing that against the full
-- geometry-ordered display list (all online displays, empties included) and
-- stepping ±1 gives next/previous.
--
-- Paneru itself can only move a window to a single fixed display
-- (`other().next()` in its ECS), which on 3+ display setups cannot reach
-- every monitor — verified against the real paneru source's complete
-- Command/Operation/MouseMove vocabulary and CLI argv grammar
-- (crates/shared_types/src/commands.rs, crates/shared_types/src/argv.rs):
-- "nextdisplay"/"nextdisplaysend" are the only display-move tokens, both
-- zero-argument, at every layer (Lua, CLI, and the Mach IPC wire format all
-- funnel through the same enums) — there is no indexed/targeted variant to
-- fall back on anywhere. With exactly two displays a single `nextdisplay`
-- hop suffices (previous and next are the same display). With three or more
-- the window is floated, teleported (via the external
-- ~/.config/mac-scrolling-wm/helpers/move-display, a compiled Accessibility
-- helper — see that file) onto the target display's frame, and brought into
-- focus there so Paneru's active-display marker rotates.
--
-- Either way, resizing to full width must wait until the window has actually
-- landed on the destination (Paneru's active-display marker only rotates on
-- a `DisplayChanged` event, which neither `nextdisplay` nor the teleport fire
-- themselves — resizing any earlier can apply against the wrong display, or
-- race Paneru's own internal post-move resize and visibly double up).
-- settle_after_move polls for this in-process via `paneru.query_active`/
-- `query_json` (lib/query.lua) — bind handlers run via mlua's `call_async`,
-- which supports nested async Lua calls, the same mechanism that makes
-- `paneru.exec`/`run` work here; no subprocess spawn per check, unlike
-- shelling out to `paneru query state`. Every failure is logged (lib/log.lua)
-- instead of silently swallowed.
--
-- `window fullwidth` TOGGLES (Paneru's own `full_width_window`: removes the
-- marker and restores the previous width if one is already present) rather
-- than idempotently setting full width. A window that arrives already
-- full-width (the common case, since this shortcut leaves windows
-- full-width) would otherwise get shrunk back down by an unconditional call
-- — ensure_full_width below only calls it when the window isn't already
-- comfortably full width.
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

-- Helpers installed alongside move-display (layout, see helpers/):
--   display-geometry — real CG frames of every online display, empties included
--   warp-pointer    — drop the cursor on an absolute point (focus an empty display)
--   mouse-display   — which display id currently has the pointer
local HELPERS_DIR = os.getenv("HOME") .. "/.config/mac-scrolling-wm/helpers/"
local MOVE_HELPER = HELPERS_DIR .. "move-display"
local GEOM_HELPER = HELPERS_DIR .. "display-geometry"
local WARP_HELPER = HELPERS_DIR .. "warp-pointer"
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

local function focused_on_display(ws, display_id)
  for _, w in ipairs(ws:windows()) do
    local d = ws:display_of(w.id)
    if d and d.id == display_id and w.focused then return w.id end
  end
  for _, w in ipairs(ws:windows()) do
    local d = ws:display_of(w.id)
    if d and d.id == display_id then return w.id end
  end
end

-- ─── Move busy-guard ───────────────────────────────────────────────────────
-- `ws:window(id).floating` is a snapshot taken once at the start of *this*
-- dispatch — it never reflects a `window manage` toggle a still-in-flight
-- move is in the middle of applying, only what was true before that move's
-- own first await. Two rapid Cmd+Ctrl+Shift+arrow presses could each pass
-- that stale check, both start floating/teleporting the same window to
-- different displays (a visible jiggle: one teleport lands, then the other
-- immediately overwrites it), and their two uncoordinated `window manage`
-- calls (a TOGGLE, not idempotent — see ensure_full_width's comment) could
-- leave the window stuck floating forever, which then made every later
-- focus/move look "broken" since the stale-floating check never clears on
-- its own. MOVE_BUSY is a plain Lua variable instead: set as the very first
-- statement, before any `paneru.exec`/`query_*` await, so a second dispatch
-- that starts while the first is still in flight sees it immediately — no
-- yield happens between the check and the set.
local MOVE_BUSY = false

local function focus_display(ws, target)
  if MOVE_BUSY then
    log("focus " .. target .. ": busy (a move is in flight)")
    return
  end
  -- No separate check on the focused window's own floating state: that used
  -- to block ALL focus-switching, forever, whenever any window was left
  -- floating (e.g. by a failed move) — an unrelated window's leftover state
  -- should never be able to jam navigation. MOVE_BUSY above is the only
  -- thing that should block this, and it clears deterministically.
  local ids = ordered_displays(ws)
  if #ids < 2 then
    log("focus " .. target .. ": fewer than 2 displays (" .. #ids .. ")")
    return
  end
  local cur_id = current_display_id()
  if not cur_id then
    log("focus " .. target .. ": mouse-display helper failed")
    return
  end
  if not DISPLAYS[cur_id] then
    log("focus " .. target .. ": cur_id " .. cur_id .. " not in geometry cache, refreshing")
    GEOM_STALE = true
    if refresh_geometry() then ids = ORDERED_IDS end
  end
  local idx
  for i, id in ipairs(ids) do if id == cur_id then idx = i break end end
  if not idx then
    log("focus " .. target .. ": cur_id " .. cur_id .. " not in ids [" .. table.concat(ids, ",") .. "] even after refresh")
    return
  end
  local n = #ids
  local step = (target == "previous") and (n - 1) or 1
  local target_id = ids[((idx - 1 + step) % n) + 1]
  log(string.format("focus %s: cur=%d idx=%d/%d ids=[%s] -> target=%d",
    target, cur_id, idx, n, table.concat(ids, ","), target_id))
  local win = focused_on_display(ws, target_id)
  if win then
    log("focus " .. target .. ": focusing existing window " .. win .. " on display " .. target_id)
    return ws:focus(win)
  end
  -- Target display has no windows: drop the pointer on its center so the OS
  -- treats it as the active display (the same idea as `mouse nextdisplay`).
  local t = DISPLAYS[target_id]
  if t then
    log("focus " .. target .. ": target display " .. target_id .. " has no windows, warping pointer to its center")
    paneru.exec(WARP_HELPER, { string.format("%d %d", math.floor(t.x + t.width / 2), math.floor(t.y + t.height / 2)) })
  else
    log("focus " .. target .. ": no geometry for target display " .. target_id)
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

-- `window fullwidth` toggles (see comment above): only call it when the
-- window isn't already comfortably full width, so arriving already-maximized
-- stays maximized instead of shrinking back to its remembered ratio. 0.85 is
-- safely above the largest non-full preset column width (0.5) and safely
-- below a true full-width frame minus screen/window padding.
local FULLWIDTH_RATIO = 0.85
local function ensure_full_width(target, w)
  if w and w.frame and target and target.width > 0
      and (w.frame.width / target.width) >= FULLWIDTH_RATIO then
    log(string.format("ensure_full_width: window %d already ~full width (%d/%d), skipping",
      w.window_id, w.frame.width, target.width))
    return
  end
  paneru.run("window fullwidth")
end

-- Settle the moved window onto target_id: poll the window's OWN record
-- (query_json("state") -> find_window) for its display_id to become
-- target_id, then re-tile and resize. This does NOT poll
-- paneru.query_active()'s "active display" — per Paneru's own source, that
-- marker only updates on a real display-topology event (added/removed/
-- moved/resized/configured/woken), never on an ordinary focus change or
-- window move, so it would never match here no matter how long anything
-- waited. The window's own display_id, by contrast, reflects where it
-- actually is.
local SETTLE_POLL_TICKS = 200

local function settle_after_move(ws, target_id, moved_window_id)
  local target = DISPLAYS[target_id]
  local landed = false
  for _ = 1, SETTLE_POLL_TICKS do
    local w = find_window(query_state_safe(), moved_window_id)
    if w and w.display_id == target_id then landed = true break end
  end
  if landed then
    -- focus_follows_mouse can steal focus mid-hop; steer it back so the
    -- re-manage below tiles the window that actually moved.
    local active = query_active_safe()
    if active and active.focused_window_id ~= moved_window_id then
      ws:focus(moved_window_id)
    end
    paneru.run("window manage")  -- re-tile onto the destination strip
    local w = find_window(query_state_safe(), moved_window_id)
    if w and w.floating == false then
      ensure_full_width(target, w)
      log(string.format("settle: window %d adopted on display %d", moved_window_id, target_id))
      return true
    end
    log(string.format("settle: window %d reported display %d but did not end up tiled",
      moved_window_id, target_id))
  else
    log("settle: window " .. moved_window_id .. " never reported display " .. target_id)
  end
  paneru.flash("move-display: failed to settle on target display", 3.0)
  -- Always leave it tiled, even on failure, so a stuck float can't jam
  -- every focus/move attempt afterward the way it did before this fix.
  local w = find_window(query_state_safe(), moved_window_id)
  if w and w.floating then paneru.run("window manage") end
  return false
end

local function move_to_display(ws, target)
  if MOVE_BUSY then
    log("move " .. target .. ": busy (another move already in flight)")
    return
  end
  -- Set *before* anything below can yield (current_display_id/paneru.exec
  -- always awaits), so a second dispatch starting while this one is still
  -- in flight sees MOVE_BUSY immediately instead of racing on stale state.
  MOVE_BUSY = true
  local ok, err = pcall(function()
    local focused = ws:focused()
    if not focused then
      log("move " .. target .. ": no focused window")
      return
    end
    -- Clear any leftover floating state up front (self-heal instead of
    -- refusing to move at all) — a window left floating by an earlier
    -- failed move must not be able to permanently jam the next one too.
    local w0 = find_window(query_state_safe(), focused)
    if w0 and w0.floating then
      log("move " .. target .. ": focused window " .. focused .. " was left floating, re-tiling first")
      paneru.run("window manage")
    end
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
      -- nextdisplay already tiles the window onto the destination strip
      -- natively; it never floats, so settle_after_move just waits + resizes.
      paneru.run("window nextdisplay")
      settle_after_move(ws, target_id, focused)
      return
    end
    local t = display_frame(ws, target_id)
    if not t then
      log("move " .. target .. ": no geometry for target display " .. target_id)
      paneru.flash("move-display: no geometry for target display", 3.0)
      return
    end
    local active = query_active_safe()
    local app_name = active and active.focused_app_name or ""
    paneru.run("window manage")  -- float, so it can be teleported off its strip
    local exec_ok, res = pcall(paneru.exec, MOVE_HELPER, { app_name, tostring(math.floor(t.x)), tostring(math.floor(t.y)) })
    if not exec_ok or not res or res.code ~= 0 then
      log("move " .. target .. ": teleport to " .. target_id .. " failed")
      paneru.flash("move-display: teleport failed", 3.0)
      local w = find_window(query_state_safe(), focused)
      if w and w.floating then paneru.run("window manage") end  -- leave it tiled somewhere clean
      return
    end
    settle_after_move(ws, target_id, focused)
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
