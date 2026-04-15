local state = require("claude_usage.state")
local scraper = require("claude_usage.scraper")
local fetcher = require("claude_usage.fetcher")
local log = hs.logger.new("cu.menubar", hs.settings.get("claude_usage.log_level") or "info")

local M = {}
M.VERSION = "0.1.0"
M.bar = nil
M.fetchTimer = nil
M.titleTimer = nil

local FORMATS = { "compact_reset", "compact", "labeled", "verbose" }
local FORMAT_LABELS = {
  compact_reset = "Compact + 5h reset",
  compact = "Compact",
  labeled = "Labeled",
  verbose = "Verbose",
}
local DEFAULT_FORMAT = "compact_reset"
local NS = "claude_usage."

local function get(k, default)
  local v = hs.settings.get(NS .. k)
  if v == nil then return default end
  return v
end

local function set(k, v)
  hs.settings.set(NS .. k, v)
end

-- Numbers are "% used" — higher = worse.
-- Thresholds drive the color bucket (4 levels). Bar glyphs use a finer 8-level
-- scale for a smoother visual fill.
local THRESHOLDS = { watch = 50, careful = 70, danger = 85 }

-- Block-meter family U+2581..U+2587. All seven sit on the baseline and rise
-- upward to a consistent height, so the menu bar line-box renders them with
-- matching ascender. The full block U+2588 is deliberately dropped — it spans
-- the entire cell (ascender→descender) and gets visually clipped in the
-- narrow menu bar band, looking inconsistent next to ▇.
local BARS = { "▁", "▂", "▃", "▄", "▅", "▆", "▇" }

-- Tailwind -500 family: readable on both light and dark menu bar backgrounds.
local BUCKET_COLOR = {
  safe    = "#10B981",   -- emerald-500
  watch   = "#F59E0B",   -- amber-500
  careful = "#F97316",   -- orange-500
  danger  = "#EF4444",   -- red-500
}
local NEUTRAL_COLOR = "#9CA3AF"  -- gray-400, for separators like "/" and reset text

local function bucketFor(pctUsed)
  if type(pctUsed) ~= "number" then return nil end
  if pctUsed >= THRESHOLDS.danger then return "danger"
  elseif pctUsed >= THRESHOLDS.careful then return "careful"
  elseif pctUsed >= THRESHOLDS.watch then return "watch"
  else return "safe" end
end

local function colorForUsed(pctUsed)
  local b = bucketFor(pctUsed)
  return b and BUCKET_COLOR[b] or NEUTRAL_COLOR
end

local function barFor(pctUsed)
  if type(pctUsed) ~= "number" then return "·" end
  -- 0 → ▁, 100 → ▇, linear across 7 bins.
  local level = math.floor(pctUsed * 7 / 100) + 1
  if level < 1 then level = 1 elseif level > 7 then level = 7 end
  return BARS[level]
end

local function glyph()
  local s = state.data
  if s.status == "needs_login" then return "⚠" end
  if (s.status == "error") and not s.fiveHour then return "⚠" end
  if s.status == "init" then return "…" end
  if s.warnings and #s.warnings > 0 then return "⚠" end
  local fh = s.fiveHour and s.fiveHour.percentUsed or 0
  local w = s.weekly and s.weekly.percentUsed or 0
  return barFor(math.max(fh, w))
end

local function glyphColor()
  local s = state.data
  if s.status == "needs_login" then return BUCKET_COLOR.danger end
  if (s.status == "error") and not s.fiveHour then return BUCKET_COLOR.danger end
  if s.warnings and #s.warnings > 0 then return BUCKET_COLOR.danger end
  local fh = s.fiveHour and s.fiveHour.percentUsed or 0
  local w = s.weekly and s.weekly.percentUsed or 0
  return colorForUsed(math.max(fh, w))
end

local function humanAgo(epoch)
  if not epoch then return "never" end
  local d = os.time() - epoch
  if d < 0 then return "now" end
  if d < 60 then return d .. "s ago" end
  local m = math.floor(d / 60)
  if m < 60 then return m .. "m ago" end
  local h = math.floor(m / 60)
  return h .. "h ago"
end

local WEEKDAYS = { sun=0, mon=1, tue=2, wed=3, thu=4, fri=5, sat=6 }

-- Parse strings like "1 hr 22 min", "45 min", "2 days 3 hr" into seconds.
local function parseDuration(s)
  if not s then return nil end
  local secs, matched = 0, false
  for n, unit in s:gmatch("(%d+)%s*(%a+)") do
    local num, u = tonumber(n), unit:lower()
    if num then
      if u:match("^d") then secs = secs + num * 86400; matched = true
      elseif u:match("^h") then secs = secs + num * 3600; matched = true
      elseif u:match("^s") then secs = secs + num; matched = true
      elseif u:match("^m") and not u:match("^mo") then secs = secs + num * 60; matched = true
      end
    end
  end
  return matched and secs or nil
end

-- Parse strings like "Sat 6:00 PM", "Mon 9:00 AM" into the next matching epoch.
local function parseWeekdayClock(s)
  if not s then return nil end
  local wd, h, m, ampm = s:match("^(%a+)%s+(%d+):(%d+)%s*(%a*)")
  if not wd then return nil end
  local target = WEEKDAYS[wd:sub(1, 3):lower()]
  if not target then return nil end
  h = tonumber(h); m = tonumber(m)
  if not h or not m then return nil end
  if ampm:upper() == "PM" and h < 12 then h = h + 12
  elseif ampm:upper() == "AM" and h == 12 then h = 0 end
  local now = os.time()
  local nowT = os.date("*t", now)
  local curWd = nowT.wday - 1  -- os.date: Sun=1..Sat=7 → 0..6
  local daysDelta = (target - curWd) % 7
  local cand = os.time({
    year = nowT.year, month = nowT.month, day = nowT.day + daysDelta,
    hour = h, min = m, sec = 0,
  })
  if cand <= now then cand = cand + 7 * 86400 end
  return cand
end

local function toEpoch(human)
  if not human or human == "" then return nil end
  local d = parseDuration(human)
  if d then return os.time() + d end
  return parseWeekdayClock(human)
end

local function fmtAbs(epoch)
  -- "Wed Apr 15, 15:59" — weekday + date + 24h clock. Consistent across both windows.
  return os.date("%a %b %d, %H:%M", epoch)
end

local function fmtRel(epoch)
  local d = epoch - os.time()
  if d <= 0 then return "now" end
  if d < 60 then return d .. "s" end
  local m = math.floor(d / 60)
  if m < 60 then return m .. "min" end
  local h = math.floor(m / 60); m = m % 60
  if h < 24 then
    if m == 0 then return h .. "h" end
    return h .. "h " .. m .. "min"
  end
  local days = math.floor(h / 24); h = h % 24
  if h == 0 then return days .. "d" end
  return days .. "d " .. h .. "h"
end

local function fiveHourResetRel(s)
  local w = s.fiveHour
  if not w then return nil end
  local epoch = w.resetsAt or toEpoch(w.resetsHuman)
  if not epoch then return nil end
  return fmtRel(epoch)
end

-- Compact "H:MM" countdown for the 5h reset (always under 5 hours).
local function fmtClock(epoch)
  if not epoch then return nil end
  local d = epoch - os.time()
  if d <= 0 then return "0:00" end
  local h = math.floor(d / 3600)
  local m = math.floor((d % 3600) / 60)
  if h >= 24 then
    local days = math.floor(h / 24); h = h % 24
    return string.format("%dd%dh", days, h)
  end
  return string.format("%d:%02d", h, m)
end

local function fiveHourResetClock(s)
  local w = s.fiveHour
  if not w then return nil end
  local epoch = w.resetsAt or toEpoch(w.resetsHuman)
  if not epoch then return nil end
  return fmtClock(epoch)
end

local function run(text, hex)
  return hs.styledtext.new(text, { color = { hex = hex, alpha = 1 } })
end

-- Tight compact title: "<5h>·<1w>" with optional " H:MM" tail. No leading
-- glyph in text — the bar is rendered as the menu bar item's icon instead.
local function compactStyled(fh, w, tail)
  local st = run(tostring(fh), colorForUsed(fh))
           .. run("·", NEUTRAL_COLOR)
           .. run(tostring(w), colorForUsed(w))
  if tail and tail ~= "" then
    st = st .. run(" " .. tail, NEUTRAL_COLOR)
  end
  return st
end

local function formatTitle()
  local s = state.data
  if s.status == "needs_login" then return "⚠ login" end
  if s.status == "init" then return "… loading" end
  if s.status == "error" and not s.fiveHour then return "⚠ err" end
  local fh = s.fiveHour and s.fiveHour.percentUsed or "?"
  local w = s.weekly and s.weekly.percentUsed or "?"
  local fmt = get("format", DEFAULT_FORMAT)
  -- Labeled / verbose retain the in-text glyph for now (the icon shows alongside).
  local g = glyph()
  if fmt == "labeled" then return string.format("%s 5h·%s 1w·%s", g, fh, w) end
  if fmt == "verbose" then return string.format("%s 5h %s%% · 1w %s%% used", g, fh, w) end
  if fmt == "compact_reset" then
    return compactStyled(fh, w, fiveHourResetClock(s) or "—")
  end
  return compactStyled(fh, w, nil)
end

-- 2px-wide vertical bar that fills bottom-up by percent, drawn via hs.canvas.
-- Cached by (worstPct, hex) so we don't redraw an identical icon every tick.
local ICON_W, ICON_H = 5, 16
local _iconCache = {}
local function progressBarIcon(pctUsed, hex)
  if type(pctUsed) ~= "number" then return nil end
  local pct = math.max(0, math.min(100, pctUsed))
  local fillH = math.floor(pct * ICON_H / 100 + 0.5)
  local cacheKey = fillH .. ":" .. hex
  if _iconCache[cacheKey] then return _iconCache[cacheKey] end
  local canvas = hs.canvas.new({ x = 0, y = 0, w = ICON_W, h = ICON_H })
  -- Faint background so the bar's outline is visible at 0% too.
  canvas:appendElements({
    type = "rectangle",
    frame = { x = 1, y = 0, w = 2, h = ICON_H },
    fillColor = { white = 0.5, alpha = 0.18 },
    strokeWidth = 0,
  })
  if fillH > 0 then
    canvas:appendElements({
      type = "rectangle",
      frame = { x = 1, y = ICON_H - fillH, w = 2, h = fillH },
      fillColor = { hex = hex, alpha = 1 },
      strokeWidth = 0,
    })
  end
  local img = canvas:imageFromCanvas()
  canvas:delete()
  _iconCache[cacheKey] = img
  -- Bound the cache; one entry per (fillH × bucket) is at most ~64.
  if next(_iconCache) and #_iconCache > 256 then _iconCache = {} end
  return img
end

local function currentBarIcon()
  local s = state.data
  if s.status ~= "ok" or not s.fiveHour or not s.weekly then return nil end
  local worst = math.max(s.fiveHour.percentUsed or 0, s.weekly.percentUsed or 0)
  return progressBarIcon(worst, colorForUsed(worst))
end

local function applyTitle()
  if not M.bar then return end
  M.bar:setIcon(currentBarIcon(), false)
  M.bar:setTitle(formatTitle())
end

local function resetStr(win)
  if not win then return "—" end
  local human = win.resetsHuman
  local epoch = win.resetsAt or toEpoch(human)
  if not epoch then
    if human and human ~= "" then return human end
    return "—"
  end
  -- Always compute both sides ourselves for consistent formatting across both windows.
  return fmtRel(epoch) .. " (" .. fmtAbs(epoch) .. ")"
end

local function refresh()
  log.d("refresh (fetcher path)")
  fetcher.fetch(function(parsed)
    -- Clear per-fetch fields so stale values don't leak across refreshes.
    state.data.warnings = nil
    state.data.weeklySonnet = nil
    state.data.weeklyOpus = nil
    state.data.weeklyHaiku = nil
    state.data.spend = nil
    for k, v in pairs(parsed) do state.data[k] = v end
    applyTitle()
  end)
end

local function openUrl(url)
  hs.urlevent.openURL(url)
end

local function tupleOrDash(win)
  if not win then return "—" end
  return (win.percentUsed or "?") .. "% used · resets " .. resetStr(win)
end

local function buildMinimalMenu()
  local s = state.data
  return {
    { title = "5h: " .. tupleOrDash(s.fiveHour), disabled = true },
    { title = "1w: " .. tupleOrDash(s.weekly),   disabled = true },
    { title = "-" },
    { title = "Refresh now", fn = refresh },
  }
end

local function buildFullMenu()
  local items = {}
  local s = state.data

  if s.fiveHour then
    table.insert(items, { title = "5h window", disabled = true })
    table.insert(items, { title = "    " .. s.fiveHour.percentUsed .. "% used", disabled = true })
    table.insert(items, { title = "    resets in " .. resetStr(s.fiveHour), disabled = true })
  else
    table.insert(items, { title = "5h window: —", disabled = true })
  end
  if s.weekly then
    table.insert(items, { title = "1w window", disabled = true })
    table.insert(items, { title = "    " .. s.weekly.percentUsed .. "% used", disabled = true })
    table.insert(items, { title = "    resets in " .. resetStr(s.weekly), disabled = true })
  else
    table.insert(items, { title = "1w window: —", disabled = true })
  end
  if s.weeklySonnet then
    table.insert(items, { title = "1w · Sonnet only", disabled = true })
    table.insert(items, { title = "    " .. s.weeklySonnet.percentUsed .. "% used", disabled = true })
    table.insert(items, { title = "    resets in " .. resetStr(s.weeklySonnet), disabled = true })
  end

  if s.warnings and #s.warnings > 0 then
    table.insert(items, { title = "-" })
    table.insert(items, { title = "⚠  Parser drift detected — widget may need code update", disabled = true })
    for _, w in ipairs(s.warnings) do
      table.insert(items, { title = "      • " .. tostring(w), disabled = true })
    end
  end

  table.insert(items, { title = "-" })
  local health = string.format("State: %s · %s · avg %dms",
    s.status or "?", humanAgo(s.lastFetch), state.avgFetchMs())
  table.insert(items, { title = health, disabled = true })
  if s.errorMsg then
    table.insert(items, { title = "  " .. tostring(s.errorMsg):sub(1, 120), disabled = true })
  end

  if s.status == "needs_login" then
    table.insert(items, { title = "-" })
    table.insert(items, { title = "⚠  Log in to claude.ai", fn = function()
      scraper.interactiveLogin(function() refresh() end)
    end })
  end

  table.insert(items, { title = "-" })
  table.insert(items, { title = "Refresh now", fn = refresh })
  table.insert(items, { title = "Open claude.ai/settings/usage", fn = function()
    openUrl("https://claude.ai/settings/usage")
  end })
  table.insert(items, { title = "Log in…", fn = function()
    scraper.interactiveLogin(function() refresh() end)
  end })

  local fmtItems = {}
  for _, f in ipairs(FORMATS) do
    table.insert(fmtItems, {
      title = FORMAT_LABELS[f] or f,
      checked = get("format", DEFAULT_FORMAT) == f,
      fn = function()
        set("format", f)
        applyTitle()
      end,
    })
  end
  table.insert(items, { title = "Display format", menu = fmtItems })

  local replayPath = get("replay_path")
  local debugItems = {
    { title = "Open Hammerspoon console", fn = function() hs.openConsole() end },
    { title = "Save artifacts (html/txt/json)",
      checked = get("save_artifacts", false) == true,
      fn = function() set("save_artifacts", not (get("save_artifacts", false) == true)) end },
    { title = "Show fetch webview",
      checked = get("debug_visible", false) == true,
      fn = function() set("debug_visible", not (get("debug_visible", false) == true)) end },
    { title = "Keep fetch webview open after extract",
      checked = get("keep_webview", false) == true,
      fn = function() set("keep_webview", not (get("keep_webview", false) == true)) end },
    { title = "-" },
    { title = "Force re-fetch now (warm)", fn = refresh },
    { title = "Reload page now (hard)", fn = function() scraper.forceReload(function(p)
        for k, v in pairs(p) do state.data[k] = v end
        applyTitle()
      end) end },
    { title = "Destroy persistent webview", fn = function()
        scraper.destroyPersistent()
        hs.alert.show("persistent webview destroyed")
      end },
    { title = "Copy fetch debug state", fn = function()
        hs.pasteboard.setContents(hs.json.encode(scraper.debugState(), true))
        hs.alert.show("fetch debug state copied")
      end },
    { title = "Copy state JSON", fn = function()
        hs.pasteboard.setContents(hs.json.encode(state.data, true))
        hs.alert.show("state JSON copied")
      end },
    { title = "Copy fetch log (in-memory)", fn = function()
        hs.pasteboard.setContents(table.concat(state.logRing, "\n"))
        hs.alert.show("log copied (" .. #state.logRing .. " lines)")
      end },
    { title = "Open debug dir", fn = function()
        openUrl("file://" .. os.getenv("HOME") .. "/.hammerspoon/claude_usage/debug")
      end },
    { title = "-" },
    { title = replayPath and ("Replay: " .. replayPath:match("([^/]+)$")) or "Set replay HTML…",
      fn = function()
        local pick = hs.dialog.chooseFileOrFolder(
          "Pick a saved HTML snapshot",
          os.getenv("HOME") .. "/.hammerspoon/claude_usage/debug",
          true, false, false, { "html", "htm", "txt", "json" })
        if pick and pick["1"] then
          set("replay_path", pick["1"])
          refresh()
        end
      end },
    { title = "Clear replay mode",
      disabled = not replayPath,
      fn = function() set("replay_path", nil); refresh() end },
    { title = "-" },
    { title = "Clear cookies (relaunch Hammerspoon after)", fn = function()
        scraper.clearCookies()
        hs.alert.show("cookies wiped · relaunch Hammerspoon")
      end },
    { title = "Reload module (hot)", fn = function()
        M.stop()
        for _, mod in ipairs({ "claude_usage", "claude_usage.menubar",
                               "claude_usage.fetcher", "claude_usage.scraper",
                               "claude_usage.parser", "claude_usage.state" }) do
          package.loaded[mod] = nil
        end
        require("claude_usage")
      end },
    { title = "-" },
    { title = "Log level: " .. (get("log_level", "info")),
      fn = function()
        local cur = get("log_level", "info")
        local nxt = ({ info = "debug", debug = "verbose", verbose = "warning", warning = "error", error = "info" })[cur] or "info"
        set("log_level", nxt)
        hs.alert.show("log level → " .. nxt .. " (reload module to apply)")
      end },
  }
  table.insert(items, { title = "Debug", menu = debugItems })

  table.insert(items, { title = "-" })
  table.insert(items, { title = "About claude-usage v" .. M.VERSION, disabled = true })
  table.insert(items, { title = "    " .. os.getenv("HOME") .. "/.hammerspoon/claude_usage", disabled = true })
  table.insert(items, { title = "Quit", fn = function() M.stop() end })

  return items
end

M._debug = { resetStr = function(win) return resetStr(win) end, toEpoch = toEpoch,
             parseDuration = parseDuration, parseWeekdayClock = parseWeekdayClock,
             formatTitle = function() return formatTitle() end }

function M.start()
  M.bar = hs.menubar.new()
  if not M.bar then
    log.e("hs.menubar.new returned nil"); return
  end
  M.bar:setTitle("… loading")

  -- hs.menubar: if setMenu is a function, it's called each click with keyboard mods.
  M.bar:setMenu(function(mods)
    if mods and (mods.ctrl or mods.alt) then
      return buildMinimalMenu()
    end
    return buildFullMenu()
  end)

  refresh()
  M.fetchTimer = hs.timer.doEvery(60, function() refresh() end)
  -- Cheap tick so "last fetch Xs ago" and glyph stay current without a fetch.
  M.titleTimer = hs.timer.doEvery(15, function()
    applyTitle()
  end)
  log.i("started v" .. M.VERSION)
  state.log("i", "started v" .. M.VERSION)
end

function M.stop()
  if M.fetchTimer then M.fetchTimer:stop(); M.fetchTimer = nil end
  if M.titleTimer then M.titleTimer:stop(); M.titleTimer = nil end
  if M.bar then M.bar:delete(); M.bar = nil end
  -- Drop the long-lived webview too, so a module reload starts cold.
  scraper.destroyPersistent()
end

return M
