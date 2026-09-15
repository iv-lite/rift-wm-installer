-- lib/query.lua — in-process state queries, shared by lib/displays.lua.
--
-- `paneru.query_active`/`query_json` reach into the live world for as long
-- as this dispatch is on the stack (no subprocess, unlike `paneru query
-- state`) — bind handlers run via mlua's `call_async`, which supports nested
-- async Lua calls, the same mechanism that makes `paneru.exec`/`run` work.
-- Every failure is logged with its actual error text so a problem here is
-- never silent.

local log = require("lib.log").log

local function query_active_safe()
  local ok, result = pcall(paneru.query_active)
  if not ok then
    log("query_active error: " .. tostring(result))
    return nil
  end
  return result
end

local function query_state_safe()
  local ok, result = pcall(paneru.query_json, "state")
  if not ok then
    log("query_json(state) error: " .. tostring(result))
    return nil
  end
  return result
end

-- The moved window's own record ({window_id, floating, display_id, frame,
-- ...}) from a fresh state snapshot, or nil if it can't be found.
local function find_window(state, window_id)
  if not state then return nil end
  for _, row in ipairs(state.virtual_workspaces or {}) do
    for _, w in ipairs(row.windows or {}) do
      if w.window_id == window_id then return w end
    end
  end
end

return {
  active = query_active_safe,
  state = query_state_safe,
  find_window = find_window,
}
