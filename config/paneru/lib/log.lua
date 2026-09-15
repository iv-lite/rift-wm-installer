-- lib/log.lua — a plain file-backed logger for the display-navigation module.
--
-- Every decision point in lib/displays.lua logs here — it used to be
-- completely silent, which made "nothing happens" reports undebuggable.
-- Plain io.open/write: Paneru's Lua runtime enables the full standard
-- library (StdLib::ALL), no subprocess needed.

local NAV_LOG = os.getenv("HOME") .. "/.config/mac-scrolling-wm/helpers/display-nav.log"

local function log(msg)
  local ok, f = pcall(io.open, NAV_LOG, "a")
  if not ok or not f then return end
  f:write(os.date("[%Y-%m-%d %H:%M:%S] "), msg, "\n")
  f:close()
end

return { log = log }
