-- Optional CPU load sparkline + die temperature in the strip. Both are off by
-- default; the 5 s tick and the temperature helper run only while enabled.
-- Load comes from hs.host.cpuUsage() (no subprocess); temperature from the
-- `sensors` helper (sensors.c) kept alive as one hs.task, one line per 5 s.
local PREFIX = ((...) or "claude_usage"):gsub("%.[^.]+$", "")
local state = require(PREFIX .. ".state")
local log = state.logger("sensors")
local get, set = state.get, state.set

local M = {}
local DIR = os.getenv("HOME") .. "/.hammerspoon/claude_usage"
local BIN, SRC = DIR .. "/sensors", DIR .. "/sensors.c"
local TICK = 2
local BARS = 20            -- 1 px per sample → 40 s of history
local hist, temp = {}, nil
M.onTick = function() end  -- menubar sets this to its redraw

function M.graphOn() return get("cpu_graph", false) end
function M.tempOn() return get("cpu_temp", false) end

local function ensureHelper()
  local b, s = hs.fs.attributes(BIN), hs.fs.attributes(SRC)
  if b and s and b.modification >= s.modification then return true end
  log.i("building sensors helper")
  local ok = os.execute(string.format(
    "clang -O2 -framework CoreFoundation -framework IOKit -o '%s' '%s' 2>/dev/null", BIN, SRC))
  if not ok then log.e("clang failed; is Xcode CLT installed? (xcode-select --install)") end
  return ok
end

local function startTemp()
  if M.task or not ensureHelper() then return end
  M.task = hs.task.new(BIN, function() M.task = nil end, function(_, out)
    local n = tonumber(out:match("%d+"))
    temp = n and n > 0 and n or nil
    M.onTick()
    return true
  end, { tostring(TICK) })
  M.task:start()
end

local function stopTemp()
  if M.task then M.task:terminate(); M.task = nil end
  temp = nil
end

local function tick()
  local u = hs.host.cpuUsage()          -- since previous call, i.e. last TICK s
  table.insert(hist, u.overall.active / 100)
  if #hist > BARS then table.remove(hist, 1) end
  M.onTick()
end

-- Brings timers/helper in line with the settings. Call after any toggle.
function M.sync()
  if M.graphOn() and not M.timer then
    hs.host.cpuUsage()                  -- prime the delta
    M.timer = hs.timer.doEvery(TICK, tick)
  elseif not M.graphOn() and M.timer then
    M.timer:stop(); M.timer = nil; hist = {}
  end
  if M.tempOn() then startTemp() else stopTemp() end
end

function M.toggleGraph() set("cpu_graph", not M.graphOn()); M.sync() end
function M.toggleTemp() set("cpu_temp", not M.tempOn()); M.sync() end
function M.stop() if M.timer then M.timer:stop(); M.timer = nil end; stopTemp() end

-- Same rule as Hot.app: color follows the system thermal pressure, not the
-- degrees. nominal → theme gray, fair → orange, serious/critical → red.
local function tempColor(dark)
  local st = hs.host.thermalState()
  if st == "fair" then return "#F97316" end
  if st == "serious" or st == "critical" then return "#EF4444" end
  return dark and "#D1D5DB" or "#6B7280"
end

local function loadColor(v)
  return v >= 0.85 and "#EF4444" or v >= 0.7 and "#F97316" or v >= 0.5 and "#F59E0B" or "#10B981"
end

local COL_W = BARS        -- one column: temperature on top, graph below
local FONT = { name = "Menlo", size = 11 }

-- Draws the sensor column into `canvas` at x, ICON_H tall. Returns width used
-- (0 when both are off). Temp alone: centered; graph alone: full height;
-- both: "78°" in the top row, graph in the bottom row, like the account blocks.
-- Graph: 1px bars, each colored by its own load (history stays readable).
function M.draw(canvas, x, h, dark)
  local g, t = M.graphOn(), M.tempOn()
  if not (g or t) then return 0 end
  local gy, gh = 0, h                        -- graph frame
  if t then
    local ty = g and 0 or (h - 14) / 2
    local txt = hs.styledtext.new(temp and (temp .. "°") or "–", {
      font = FONT, color = { hex = temp and tempColor(dark) or "#9CA3AF" },
      paragraphStyle = { alignment = "center" },
    })
    canvas:appendElements({ type = "text", text = txt, frame = { x = x - 4, y = ty, w = COL_W + 8, h = 15 } })
    gy, gh = 15, h - 16
  end
  if g then
    for i, v in ipairs(hist) do
      local bh = math.max(1, math.floor(v * gh + 0.5))
      canvas:appendElements({ type = "rectangle", action = "fill", fillColor = { hex = loadColor(v) },
        frame = { x = x + BARS - #hist + i - 1, y = gy + gh - bh, w = 1, h = bh } })
    end
  end
  return COL_W
end

return M
