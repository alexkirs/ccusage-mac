local state = require("claude_usage.state")
local updater = require("claude_usage.updater")
local log = state.logger("menubar")
local get, set = state.get, state.set

local M = {}
M.VERSION = "0.2.0"
M.instances = {}            -- keyed by provider.id
M._updaterStarted = false

local FORMATS = { "compact_reset", "compact", "labeled" }
local FORMAT_LABELS = {
  compact_reset = "Compact + 5h reset",
  compact = "Compact",
  labeled = "Labeled",
}
local DEFAULT_FORMAT = "compact_reset"

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
  local level = math.floor(pctUsed * 7 / 100) + 1
  if level < 1 then level = 1 elseif level > 7 then level = 7 end
  return BARS[level]
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

local function fmtAbs(epoch)
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
  local epoch = w.resetsAt
  if not epoch then return nil end
  return fmtClock(epoch)
end

local function run(text, hex)
  return hs.styledtext.new(text, { color = { hex = hex, alpha = 1 } })
end

local function compactStyled(fh, w, tail)
  local st = run(tostring(fh), colorForUsed(fh))
           .. run("·", NEUTRAL_COLOR)
           .. run(tostring(w), colorForUsed(w))
  if tail and tail ~= "" then
    st = st .. run(" " .. tail, NEUTRAL_COLOR)
  end
  return st
end

local function labeledStyled(fh, w)
  return run("5h", NEUTRAL_COLOR)
      .. run(tostring(fh), colorForUsed(fh))
      .. run("·", NEUTRAL_COLOR)
      .. run("1w", NEUTRAL_COLOR)
      .. run(tostring(w), colorForUsed(w))
end

-- 3px-wide vertical bar that fills bottom-up by percent, drawn via hs.canvas.
-- Cached by (worstPct, hex) so we don't redraw an identical icon every tick.
-- Cache is shared across all provider instances: same bucket colors.
local ICON_W, ICON_H = 5, 16
local _iconCache = {}
local _iconCacheSize = 0
local function progressBarIcon(pctUsed, hex)
  if type(pctUsed) ~= "number" then return nil end
  local pct = math.max(0, math.min(100, pctUsed))
  local fillH = math.floor(pct * ICON_H / 100 + 0.5)
  local cacheKey = fillH .. ":" .. hex
  if _iconCache[cacheKey] then return _iconCache[cacheKey] end
  local canvas = hs.canvas.new({ x = 0, y = 0, w = ICON_W, h = ICON_H })
  canvas:appendElements({
    type = "rectangle",
    frame = { x = 1, y = 0, w = 3, h = ICON_H },
    fillColor = { white = 0.5, alpha = 0.18 },
    strokeWidth = 0,
  })
  if fillH > 0 then
    canvas:appendElements({
      type = "rectangle",
      frame = { x = 1, y = ICON_H - fillH, w = 3, h = fillH },
      fillColor = { hex = hex, alpha = 1 },
      strokeWidth = 0,
    })
  end
  local img = canvas:imageFromCanvas()
  canvas:delete()
  _iconCache[cacheKey] = img
  _iconCacheSize = _iconCacheSize + 1
  if _iconCacheSize > 64 then
    _iconCache = {}; _iconCacheSize = 0
  end
  return img
end

local function resetStr(win)
  if not win or not win.resetsAt then return "—" end
  return fmtRel(win.resetsAt) .. " (" .. fmtAbs(win.resetsAt) .. ")"
end

local function tupleOrDash(win)
  if not win then return "—" end
  return (win.percentUsed or "?") .. "% used · resets " .. resetStr(win)
end

local function fmtMoney(amount, currency)
  if not amount then return "—" end
  if currency == "USD" or not currency then return string.format("$%.2f", amount) end
  return string.format("%.2f %s", amount, currency)
end

local function openUrl(url)
  hs.urlevent.openURL(url)
end

---------------------------------------------------------------------
-- Per-instance machinery
---------------------------------------------------------------------

function M.start(opts)
  opts = opts or {}
  local provider = assert(opts.provider, "menubar.start: opts.provider required")
  local pid = provider.id

  local instance = { provider = provider }

  local function getState()
    return provider.getState() or {}
  end

  local function glyph()
    local s = getState()
    if s.status == "needs_login" then return "⚠" end
    if (s.status == "error") and not s.fiveHour then return "⚠" end
    if s.status == "init" then return "…" end
    if s.warnings and #s.warnings > 0 then return "⚠" end
    local fh = s.fiveHour and s.fiveHour.percentUsed or 0
    local w = s.weekly and s.weekly.percentUsed or 0
    return barFor(math.max(fh, w))
  end

  local function glyphColor()
    local s = getState()
    if s.status == "needs_login" then return BUCKET_COLOR.danger end
    if (s.status == "error") and not s.fiveHour then return BUCKET_COLOR.danger end
    if s.warnings and #s.warnings > 0 then return BUCKET_COLOR.danger end
    local fh = s.fiveHour and s.fiveHour.percentUsed or 0
    local w = s.weekly and s.weekly.percentUsed or 0
    return colorForUsed(math.max(fh, w))
  end

  local function formatTitle()
    local s = getState()
    if s.status == "needs_login" then return "⚠ login" end
    if s.status == "init" then return "… loading" end
    if s.status == "error" and not s.fiveHour then return "⚠ err" end
    local fh = s.fiveHour and s.fiveHour.percentUsed or "?"
    local w = s.weekly and s.weekly.percentUsed or "?"
    local fmt = get("format", DEFAULT_FORMAT)
    if fmt == "labeled" then return labeledStyled(fh, w) end
    if fmt == "compact_reset" then
      return compactStyled(fh, w, fiveHourResetClock(s) or "—")
    end
    return compactStyled(fh, w, nil)
  end

  local function currentBarIcon()
    local s = getState()
    if s.status ~= "ok" or not s.fiveHour then return nil end
    local pct = s.fiveHour.percentUsed or 0
    return progressBarIcon(pct, colorForUsed(pct))
  end

  local function applyTitle()
    if not instance.bar then return end
    -- silence: glyph()/glyphColor() values not currently rendered as text icon;
    -- the colored bar canvas via setIcon is the visible glyph. Keep helpers in
    -- case future modes need them.
    local _, _ = glyph(), glyphColor()
    instance.bar:setIcon(currentBarIcon(), false)
    instance.bar:setTitle(formatTitle())
  end

  local function refresh()
    log.d(pid .. " refresh")
    provider.fetch(function()
      applyTitle()
    end)
  end

  local function toggleExtraUsage()
    if not provider.toggleExtraUsage then return end
    provider.toggleExtraUsage(function()
      applyTitle()
      refresh()
    end)
  end

  local function buildMenu(compact)
    local s = getState()

    if compact then
      return {
        { title = "5h: " .. tupleOrDash(s.fiveHour), disabled = true },
        { title = "1w: " .. tupleOrDash(s.weekly),   disabled = true },
        { title = "-" },
        { title = "Refresh now", fn = refresh },
      }
    end

    local items = {}
    local loggedIn = s.status == "ok" and s.account and s.account.email ~= nil

    if loggedIn then
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
      -- Codex provider populates additional[] with per-model rate limits.
      if s.additional and #s.additional > 0 then
        for _, a in ipairs(s.additional) do
          if a.weekly then
            table.insert(items, { title = "1w · " .. (a.label or "additional"), disabled = true })
            table.insert(items, { title = "    " .. a.weekly.percentUsed .. "% used", disabled = true })
            table.insert(items, { title = "    resets in " .. resetStr(a.weekly), disabled = true })
          end
        end
      end

      -- Extra usage block (Claude only).
      if provider.hasExtraUsage and s.extraUsage then
        local eu = s.extraUsage
        table.insert(items, { title = "-" })
        table.insert(items, { title = "Extra usage", disabled = true })
        local usageLine = "    " .. fmtMoney(eu.usedCredits, eu.currency)
               .. " / " .. fmtMoney(eu.monthlyLimit, eu.currency)
               .. (eu.utilization and string.format(" (%d%%)", eu.utilization) or "")
        if eu.isEnabled then
          local labelColor = { list = "System", name = "labelColor" }
          table.insert(items, {
            title = hs.styledtext.new(usageLine, { color = labelColor }),
            disabled = true,
          })
          table.insert(items, {
            title = hs.styledtext.new("    status: ", { color = labelColor })
                 .. hs.styledtext.new("on", { color = { hex = BUCKET_COLOR.safe, alpha = 1 } }),
            disabled = true,
          })
        else
          table.insert(items, { title = usageLine, disabled = true })
          table.insert(items, { title = "    status: off", disabled = true })
        end
        table.insert(items, {
          title = eu.isEnabled and "Disable extra usage" or "Enable extra usage",
          fn = toggleExtraUsage,
        })
      end

      if s.warnings and #s.warnings > 0 then
        table.insert(items, { title = "-" })
        table.insert(items, { title = "⚠  Widget needs attention", disabled = true })
        for _, w in ipairs(s.warnings) do
          table.insert(items, { title = "      • " .. tostring(w), disabled = true })
        end
      end
    end

    table.insert(items, { title = "-" })
    local health = string.format("State: %s · %s · avg %dms",
      s.status or "?", humanAgo(s.lastFetch), state.avgFetchMs())
    table.insert(items, { title = health, disabled = true })
    if s.errorMsg then
      table.insert(items, { title = "  " .. tostring(s.errorMsg):sub(1, 120), disabled = true })
    end

    table.insert(items, { title = "-" })
    if loggedIn then
      table.insert(items, { title = "Refresh now", fn = refresh })
      if provider.openSettingsLabel and provider.openSettingsUrl then
        table.insert(items, {
          title = "Open " .. provider.openSettingsLabel,
          fn = function() openUrl(provider.openSettingsUrl) end,
        })
      end
      local logoutLabel = "Log out (" .. s.account.email
                       .. (s.account.orgName and (" · " .. s.account.orgName) or "") .. ")"
      table.insert(items, { title = logoutLabel, fn = function() provider.logout(refresh) end })
    else
      local loginLabel = provider.loginLabel or "service"
      table.insert(items, {
        title = s.status == "needs_login"
                  and ("⚠  Log in to " .. loginLabel .. "…")
                  or  ("Log in to " .. loginLabel .. "…"),
        fn = function() provider.login(function() refresh() end) end,
      })
    end

    -- Display format submenu (shared setting, both icons honor it).
    local fmtItems = {}
    for _, f in ipairs(FORMATS) do
      table.insert(fmtItems, {
        title = FORMAT_LABELS[f] or f,
        checked = get("format", DEFAULT_FORMAT) == f,
        fn = function()
          set("format", f)
          M.applyAllTitles()
        end,
      })
    end
    table.insert(items, { title = "Display format", menu = fmtItems })

    -- Updater section (global, but render in each menu).
    local us = updater.status()
    if us.behind and us.behind > 0 then
      table.insert(items, {
        title = hs.styledtext.new(
          string.format("⬆ Update available (%d commit%s) · Apply & reload",
            us.behind, us.behind == 1 and "" or "s"),
          { color = { hex = BUCKET_COLOR.safe, alpha = 1 } }),
        fn = function() updater.apply() end,
      })
    end
    local upItems = {
      { title = us.checking and "Checking…" or "Check for updates now",
        disabled = us.checking,
        fn = function()
          updater.forceCheck = true
          hs.alert.show("Checking for updates…")
          updater.checkNow(function(st)
            if st.error then
              hs.alert.show("Check failed: " .. st.error)
            elseif (st.behind or 0) == 0 then
              hs.alert.show("Up to date")
            else
              hs.alert.show(string.format("%d update%s available",
                st.behind, st.behind == 1 and "" or "s"))
            end
          end)
        end },
    }
    if us.behind and us.behind > 0 then
      table.insert(upItems, { title = "Apply update & reload",
        disabled = us.updating,
        fn = function() updater.apply() end })
      if us.subjects and #us.subjects > 0 then
        table.insert(upItems, { title = "-" })
        table.insert(upItems, { title = "New commits:", disabled = true })
        for i, subj in ipairs(us.subjects) do
          if i > 10 then break end
          table.insert(upItems, { title = "    • " .. subj:sub(1, 80), disabled = true })
        end
      end
    end
    table.insert(upItems, { title = "-" })
    table.insert(upItems, {
      title = "Check daily",
      checked = us.autoCheck,
      fn = function() updater.setAutoCheck(not us.autoCheck) end,
    })
    table.insert(upItems, {
      title = "Auto-apply updates",
      checked = us.autoApply,
      fn = function() updater.setAutoApply(not us.autoApply) end,
    })
    table.insert(upItems, {
      title = "Live reload on file save",
      checked = us.liveReload,
      fn = function() updater.setLiveReload(not us.liveReload) end,
    })
    table.insert(upItems, { title = "-" })
    local last = us.lastCheck and humanAgo(us.lastCheck) or "never"
    table.insert(upItems, { title = "Last check: " .. last, disabled = true })
    if us.dirty then
      table.insert(upItems, { title = "⚠ Working tree dirty — apply blocked", disabled = true })
    end
    if us.error then
      table.insert(upItems, { title = "⚠ " .. us.error:sub(1, 100), disabled = true })
    end
    table.insert(items, { title = "Updates", menu = upItems })

    -- Debug submenu — provider-aware.
    local debugItems = {
      { title = "Open Hammerspoon console", fn = function() hs.openConsole() end },
      { title = "Dump fetcher response to debug/last-fetcher.json",
        checked = get("dump_fetcher", false) == true,
        fn = function() set("dump_fetcher", not (get("dump_fetcher", false) == true)) end },
      { title = "-" },
      { title = "Force re-fetch now", fn = refresh },
      { title = "Reload page now (hard)", fn = function()
          if provider.reload then provider.reload(function(_, _) refresh() end) end
        end },
      { title = "Destroy persistent webview", fn = function()
          if provider.destroyPersistent then provider.destroyPersistent() end
          hs.alert.show("persistent webview destroyed (" .. pid .. ")")
        end },
      { title = "-" },
      { title = "Copy state JSON", fn = function()
          hs.pasteboard.setContents(hs.json.encode(getState(), true))
          hs.alert.show("state JSON copied (" .. pid .. ")")
        end },
      { title = "Copy webview debug state", fn = function()
          if provider.debugState then
            hs.pasteboard.setContents(hs.json.encode(provider.debugState(), true))
            hs.alert.show("webview debug state copied (" .. pid .. ")")
          end
        end },
      { title = "Copy fetch log (in-memory)", fn = function()
          hs.pasteboard.setContents(table.concat(state.logRing, "\n"))
          hs.alert.show("log copied (" .. #state.logRing .. " lines)")
        end },
      { title = "Open debug dir", fn = function()
          openUrl("file://" .. os.getenv("HOME") .. "/.hammerspoon/claude_usage/debug")
        end },
      { title = "-" },
      { title = "Hard logout (clear ALL sessions + relaunch)", fn = function()
          if provider.logoutHard then provider.logoutHard() end
        end },
      { title = "Clear cookies (relaunch Hammerspoon after)", fn = function()
          if provider.clearCookies then provider.clearCookies() end
          hs.alert.show("cookies wiped · relaunch Hammerspoon")
        end },
      { title = "Reload module (hot)", fn = function()
          M.stopAll()
          for _, mod in ipairs({ "claude_usage", "claude_usage.menubar",
                                 "claude_usage.data", "claude_usage.codex_data",
                                 "claude_usage.state", "claude_usage.updater" }) do
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
    local aboutUs = updater.status()
    local verLine = "About claude-usage v" .. M.VERSION .. " · " .. pid
    if aboutUs.sha then verLine = verLine .. " · " .. aboutUs.sha end
    table.insert(items, { title = verLine, disabled = true })
    table.insert(items, { title = "    " .. os.getenv("HOME") .. "/.hammerspoon/claude_usage", disabled = true })
    table.insert(items, { title = "Quit", fn = function() M.stopAll() end })

    return items
  end

  -- Wire up the menubar item.
  instance.bar = hs.menubar.new()
  if not instance.bar then
    log.e("hs.menubar.new returned nil for " .. pid)
    return nil
  end
  instance.bar:setTitle("… loading")
  instance.bar:setMenu(function(mods)
    return buildMenu(mods and (mods.ctrl or mods.alt))
  end)

  if not M._updaterStarted then
    updater.start()
    M._updaterStarted = true
  end

  instance.refresh = refresh
  instance.applyTitle = applyTitle
  instance.buildMenu = buildMenu

  refresh()
  instance.fetchTimer = hs.timer.doEvery(60, refresh)
  instance.titleTimer = hs.timer.doEvery(60, applyTitle)

  M.instances[pid] = instance
  log.i("started v" .. M.VERSION .. " provider=" .. pid)
  state.log("i", "started v" .. M.VERSION .. " (" .. pid .. ")")
  return instance
end

function M.applyAllTitles()
  for _, inst in pairs(M.instances) do
    if inst.applyTitle then inst.applyTitle() end
  end
end

function M.stopAll()
  for _, inst in pairs(M.instances) do
    if inst.fetchTimer then inst.fetchTimer:stop() end
    if inst.titleTimer then inst.titleTimer:stop() end
    if inst.bar then inst.bar:delete() end
    if inst.provider and inst.provider.destroyPersistent then
      inst.provider.destroyPersistent()
    end
  end
  M.instances = {}
  if M._updaterStarted then
    updater.stop()
    M._updaterStarted = false
  end
end

-- Backward-compat alias.
function M.stop() M.stopAll() end

M._debug = {
  resetStr    = function(win) return resetStr(win) end,
}

return M
