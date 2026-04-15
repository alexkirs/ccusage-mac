local state = require("claude_usage.state")
local data = require("claude_usage.data")
local updater = require("claude_usage.updater")
local log = state.logger("menubar")
local get, set = state.get, state.set

local M = {}
M.VERSION = "0.2.0"
M.bar = nil
M.fetchTimer = nil
M.titleTimer = nil

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

-- Time formatters. All three take an epoch (seconds since 1970); resets
-- come from the API as ISO-8601, converted to epoch in data.lua/makeWindow.
-- The older string-parsing path (parseDuration / parseWeekdayClock /
-- resetsHuman) was removed — the API has always returned ISO.
local function fmtAbs(epoch)
  -- "Wed Apr 15, 15:59" — weekday + date + 24h clock.
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

-- Compact "H:MM" countdown (for the 5h window, which is always under 5 hours).
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

-- Labeled styled title: "5h62·1w41" — labels neutral gray, numbers
-- colored per bucket. No leading glyph: the colored bar is already
-- rendered as the menu bar icon.
local function labeledStyled(fh, w)
  return run("5h", NEUTRAL_COLOR)
      .. run(tostring(fh), colorForUsed(fh))
      .. run("·", NEUTRAL_COLOR)
      .. run("1w", NEUTRAL_COLOR)
      .. run(tostring(w), colorForUsed(w))
end

local function formatTitle()
  local s = state.data
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

-- 2px-wide vertical bar that fills bottom-up by percent, drawn via hs.canvas.
-- Cached by (worstPct, hex) so we don't redraw an identical icon every tick.
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
  _iconCacheSize = _iconCacheSize + 1
  -- Possible keys: (fillH 0..16) × 4 bucket colors = 68. Wipe well above that
  -- to catch any color drift, but still bounded.
  if _iconCacheSize > 64 then
    _iconCache = {}; _iconCacheSize = 0
  end
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
  if not win or not win.resetsAt then return "—" end
  return fmtRel(win.resetsAt) .. " (" .. fmtAbs(win.resetsAt) .. ")"
end

-- Every field that data.fetch can populate. Wiped at refresh start so an
-- earlier tick's value (e.g. a stale errorMsg) never bleeds into a later
-- successful tick's state.
local FETCH_KEYS = {
  "fiveHour", "weekly", "weeklySonnet", "weeklyOpus", "weeklyHaiku",
  "spend", "account", "extraUsage", "warnings", "errorMsg",
}

local function refresh()
  log.d("refresh")
  data.fetch(function(parsed)
    for _, k in ipairs(FETCH_KEYS) do state.data[k] = nil end
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

local USAGE_URL = "https://claude.ai/settings/usage"

local function fmtMoney(amount, currency)
  if not amount then return "—" end
  if currency == "USD" or not currency then return string.format("$%.2f", amount) end
  return string.format("%.2f %s", amount, currency)
end

-- Flip Extra usage via direct PUT /api/organizations/<uuid>/overage_spend_limit.
-- The DOM switch can't be driven programmatically (React's isTrusted filter),
-- so we hit the same endpoint the SPA's mutation uses. orgUuid comes from
-- the last successful fetch (state.data.account.orgUuid).
local TOGGLE_EXTRA_JS_TEMPLATE = [[
(function(){
  var TOKEN = "%s";
  var ORG = "%s";
  var desired = %s;
  window.__cu_toggle = {stage:"starting", token: TOKEN};
  fetch("/api/organizations/" + ORG + "/overage_spend_limit", {
    method: "PUT",
    headers: {"content-type": "application/json"},
    credentials: "include",
    body: JSON.stringify({is_enabled: desired}),
  }).then(function(r){
    return r.text().then(function(body){
      var parsed = null; try { parsed = JSON.parse(body); } catch (e) {}
      var ok = r.status === 200 && parsed && parsed.is_enabled === desired;
      window.__cu_toggle = {
        stage:"done", token: TOKEN,
        ok: ok, status: r.status, desired: desired,
        actual: parsed && parsed.is_enabled,
        bodySnippet: body.slice(0, 200),
      };
    });
  }).catch(function(e){
    window.__cu_toggle = {stage:"done", token: TOKEN, err: "fetch_err: " + String(e)};
  });
})()
]]
local TOGGLE_READ_JS = "JSON.stringify(window.__cu_toggle || {stage:'none'})"

local function toggleExtraUsage()
  local acct = state.data.account
  local orgUuid = acct and acct.orgUuid
  if not orgUuid then
    hs.alert.show("Toggle blocked: no orgUuid yet — refresh first")
    return
  end
  local before = state.data.extraUsage and state.data.extraUsage.isEnabled
  local desired = not before
  log.i("toggle extra usage: " .. tostring(before) .. " → " .. tostring(desired))
  -- Instant feedback — PUT takes 2–5s, alert covers the gap.
  hs.alert.show("Extra usage: updating to " .. (desired and "on" or "off") .. "…", 2)
  local token = string.format("%d_%d", os.time(), math.random(1000000))
  local js = string.format(TOGGLE_EXTRA_JS_TEMPLATE, token, orgUuid, tostring(desired))
  data.runJS(js, function() end)

  -- PUT /overage_spend_limit has measured round-trips of 2–5s. Cap the
  -- poll generously; on timeout, trigger a refresh rather than marking it
  -- failed — the mutation often landed server-side, next fetch confirms.
  local tries = 0
  local poll
  poll = hs.timer.doEvery(0.2, function()
    tries = tries + 1
    if tries > 75 then  -- 15s cap
      poll:stop()
      log.w("toggle poll timed out; refreshing to confirm actual state")
      refresh()
      return
    end
    data.runJS(TOGGLE_READ_JS, function(resultStr)
      if not resultStr then return end
      local ok, info = pcall(hs.json.decode, resultStr)
      if not ok or type(info) ~= "table" then return end
      if info.stage ~= "done" or info.token ~= token then return end
      poll:stop()
      log.i("toggle result: " .. hs.inspect(info))
      state.log("i", "extra_usage PUT → " .. hs.json.encode(info))
      if not info.ok then
        hs.alert.show("Extra usage toggle failed (HTTP " .. tostring(info.status or "?") .. ")")
        state.data.warnings = state.data.warnings or {}
        table.insert(state.data.warnings,
          "Extra usage PUT failed: " .. (info.err or ("status=" .. tostring(info.status)))
          .. " · desired=" .. tostring(desired) .. " · actual=" .. tostring(info.actual))
        applyTitle()
        return
      end
      if state.data.extraUsage then state.data.extraUsage.isEnabled = desired end
      applyTitle()
      hs.alert.show("Extra usage " .. (desired and "on" or "off"))
      refresh()
    end)
  end)
end

-- One menu builder, two modes. `compact` is the Ctrl/Alt-click variant:
-- a two-line usage summary + Refresh. Anything else falls through to the
-- full menu with windows, extras, health, account actions, and submenus.
local function buildMenu(compact)
  local s = state.data

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

  -- Usage + extras only render when logged in. Stale data is misleading.
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

    -- Extra usage (overage) block.
    -- When enabled: render with system labelColor + green "on" so it reads as active.
    -- When disabled: pass plain strings so NSMenu applies its own dimmed/disabled
    -- styling, matching the other window rows (explicit gray hex draws solid and
    -- looks active by comparison).
    if s.extraUsage then
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
    table.insert(items, { title = "Open claude.ai/settings/usage", fn = function() openUrl(USAGE_URL) end })
    local logoutLabel = "Log out (" .. s.account.email
                     .. (s.account.orgName and (" · " .. s.account.orgName) or "") .. ")"
    table.insert(items, { title = logoutLabel, fn = function() data.logoutSoft(refresh) end })
  else
    table.insert(items, {
      title = s.status == "needs_login" and "⚠  Log in to claude.ai…" or "Log in to claude.ai…",
      fn = function() data.interactiveLogin(function() refresh() end) end,
    })
  end

  -- Display format submenu.
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

  -- Updater section.
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

  -- Debug submenu — slim now that the innerText path is gone.
  local debugItems = {
    { title = "Open Hammerspoon console", fn = function() hs.openConsole() end },
    { title = "Dump fetcher response to debug/last-fetcher.json",
      checked = get("dump_fetcher", false) == true,
      fn = function() set("dump_fetcher", not (get("dump_fetcher", false) == true)) end },
    { title = "-" },
    { title = "Force re-fetch now", fn = refresh },
    { title = "Reload page now (hard)", fn = function()
        data.reload(function(_, _) refresh() end)
      end },
    { title = "Destroy persistent webview", fn = function()
        data.destroyPersistent()
        hs.alert.show("persistent webview destroyed")
      end },
    { title = "-" },
    { title = "Copy state JSON", fn = function()
        hs.pasteboard.setContents(hs.json.encode(state.data, true))
        hs.alert.show("state JSON copied")
      end },
    { title = "Copy webview debug state", fn = function()
        hs.pasteboard.setContents(hs.json.encode(data.debugState(), true))
        hs.alert.show("webview debug state copied")
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
        data.logoutHard()
      end },
    { title = "Clear cookies (relaunch Hammerspoon after)", fn = function()
        data.clearCookies()
        hs.alert.show("cookies wiped · relaunch Hammerspoon")
      end },
    { title = "Reload module (hot)", fn = function()
        M.stop()
        for _, mod in ipairs({ "claude_usage", "claude_usage.menubar",
                               "claude_usage.data", "claude_usage.state",
                               "claude_usage.updater" }) do
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
  local verLine = "About claude-usage v" .. M.VERSION
  if aboutUs.sha then verLine = verLine .. " · " .. aboutUs.sha end
  table.insert(items, { title = verLine, disabled = true })
  table.insert(items, { title = "    " .. os.getenv("HOME") .. "/.hammerspoon/claude_usage", disabled = true })
  table.insert(items, { title = "Quit", fn = function() M.stop() end })

  return items
end

M._debug = {
  resetStr    = function(win) return resetStr(win) end,
  formatTitle = function() return formatTitle() end,
}

function M.start()
  M.bar = hs.menubar.new()
  if not M.bar then
    log.e("hs.menubar.new returned nil"); return
  end
  M.bar:setTitle("… loading")

  -- hs.menubar: if setMenu is a function, it's called each click with keyboard mods.
  M.bar:setMenu(function(mods)
    return buildMenu(mods and (mods.ctrl or mods.alt))
  end)

  updater.start()
  refresh()
  M.fetchTimer = hs.timer.doEvery(60, function() refresh() end)
  -- Cheap tick so "last fetch Xs ago" and glyph stay current without a fetch.
  -- Countdown only updates minute-by-minute, so 60 s is enough to keep it
  -- alive between fetches (fetchTimer fires every 60 s anyway).
  M.titleTimer = hs.timer.doEvery(60, function()
    applyTitle()
  end)
  log.i("started v" .. M.VERSION)
  state.log("i", "started v" .. M.VERSION)
end

function M.stop()
  if M.fetchTimer then M.fetchTimer:stop(); M.fetchTimer = nil end
  if M.titleTimer then M.titleTimer:stop(); M.titleTimer = nil end
  if M.bar then M.bar:delete(); M.bar = nil end
  updater.stop()
  -- Drop the long-lived webview too, so a module reload starts cold.
  data.destroyPersistent()
end

return M
