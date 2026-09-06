local PREFIX = ((...) or "claude_usage"):gsub("%.[^.]+$", "")
local state = require(PREFIX .. ".state")
local updater = require(PREFIX .. ".updater")
local login = require(PREFIX .. ".login")
local log = state.logger("menubar")
local get, set = state.get, state.set

local M = {}
M.VERSION = "0.4.0"
M.PREFIX = PREFIX
M.PROVIDERS = {
  claude = require(PREFIX .. ".claude"),
  codex  = require(PREFIX .. ".codex"),
  grok   = require(PREFIX .. ".grok"),
  grokbot = require(PREFIX .. ".grokbot"),
}
M.PROVIDER_ORDER = { "claude", "codex", "grok", "grokbot" }
M.instances = {}            -- keyed by account id
M.accounts = {}             -- registry (list), persisted via state.saveAccounts
M._updaterStarted = false

local DEBUG_DIR = os.getenv("HOME") .. "/.hammerspoon/claude_usage/debug"

local FORMATS = { "compact_reset", "compact", "labeled" }
local FORMAT_LABELS = {
  compact_reset = "Compact + 5h reset",
  compact = "Compact",
  labeled = "Labeled",
}
local DEFAULT_FORMAT = "compact_reset"

-- Numbers are "% used" — higher = worse. Thresholds drive the color bucket.
local THRESHOLDS = { watch = 50, careful = 70, danger = 85 }

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
  if h >= 24 then return string.format("%dd", math.floor(h / 24 + 0.5)) end
  return string.format("%d:%02d", h, m)
end

-- Menubar block image: brand glyph (left) + 3px usage bar + two stacked text
-- rows (5h·1w percents on top, reset clock below). The whole block is drawn as
-- one canvas image and set as the item's icon (title left empty) so the data
-- stacks vertically and the block stays ~2x narrower than a single-line title.
-- The brand half adapts to light/dark theme; bars/numbers keep their bucket
-- color since the color carries information.
local ICON_H = 30   -- tall enough for two ~12px text rows (menu bar ~33px)
local BRAND_W = 8   -- left column holding the vertical provider label
local GAP_W   = 0
local BAR_W   = 5

-- Returns true on dark mode. Re-checked on every render so theme toggles
-- show within one titleTimer tick (60s) without explicit appearance hooks.
local function isDarkMode()
  return hs.host.interfaceStyle and hs.host.interfaceStyle() == "Dark"
end

-- Provider brand drawn as a vertical (90°-rotated) lowercase label in the left
-- column instead of a glyph. Light-gray, theme-adaptive so it reads on both
-- light and dark menu bar backgrounds. Reads bottom-to-top.
local LABEL_SIZE = 7

local function drawVerticalLabel(canvas, label)
  local text = (label or "?"):sub(1, 7)  -- ~7 glyphs fit the 30px column
  local color = isDarkMode() and "#D1D5DB" or "#6B7280"  -- gray-300 / gray-500
  local cw = LABEL_SIZE * 0.602  -- Menlo monospace advance
  local wordW = math.ceil(utf8.len(text) * cw) + 2
  local lineH = LABEL_SIZE + 3
  local cx, cy = BRAND_W / 2, ICON_H / 2
  canvas:appendElements({
    type = "text",
    text = text,
    frame = { x = cx - wordW / 2, y = cy - lineH / 2, w = wordW, h = lineH },
    textColor = { hex = color, alpha = 1 },
    textSize = LABEL_SIZE,
    textFont = "Menlo-Bold",
    textAlignment = "center",
    transformation = hs.canvas.matrix.translate(cx, cy):rotate(-90):translate(-cx, -cy),
  })
end

-- Draws a 3px usage bar (faint track + bottom-anchored fill) inside a
-- BAR_W-wide slot whose left edge is slotX.
local function drawBar(canvas, slotX, fillH, hex)
  canvas:appendElements({
    type = "rectangle",
    frame = { x = slotX + 1, y = 0, w = 3, h = ICON_H },
    fillColor = { white = 0.5, alpha = 0.18 },
    strokeWidth = 0,
  })
  if fillH > 0 then
    canvas:appendElements({
      type = "rectangle",
      frame = { x = slotX + 1, y = ICON_H - fillH, w = 3, h = fillH },
      fillColor = { hex = hex, alpha = 1 },
      strokeWidth = 0,
    })
  end
end

local ROW_FONT = "Menlo"
local ROW_SIZE = 12
local CHAR_W   = ROW_SIZE * 0.602  -- Menlo is monospace; calibrated advance per glyph
local ROW_H    = ROW_SIZE + 2      -- per-row line box (size 12 → ~14px)

-- One colored styledtext run in the block font.
local function seg(text, hex)
  return hs.styledtext.new(text, {
    color = { hex = hex, alpha = 1 },
    font  = { name = ROW_FONT, size = ROW_SIZE },
  })
end

-- "23·7" — 5h·1w percents, each in its bucket color, neutral separator.
local function pctRow(fh, w)
  return seg(tostring(fh), colorForUsed(fh))
      .. seg("·", NEUTRAL_COLOR)
      .. seg(tostring(w), colorForUsed(w))
end

-- Builds one menubar block image from b = { label, w5h, w1w, showReset, text }.
-- b.text (e.g. "⚠", "…") replaces the numbers when the account has no data.
local function buildBlockIcon(b)
  local w5h, w1w = b.w5h, b.w1w
  -- Weekly-only providers (Codex since 2026-07 has no 5h window): render a
  -- single number driven by the weekly window instead of "?·N".
  local single = (not w5h) ~= (not w1w)
  local fh = single and (w5h or w1w).percentUsed or (w5h and w5h.percentUsed or "?")
  local w  = w1w and w1w.percentUsed or "?"
  local row1str = single and tostring(fh) or (tostring(fh) .. "·" .. tostring(w))
  local row1 = single and seg(tostring(fh), colorForUsed(fh)) or pctRow(fh, w)
  if b.text then
    fh, row1str = "?", b.text
    row1 = seg(b.text, b.text == "…" and NEUTRAL_COLOR or BUCKET_COLOR.danger)
  end
  local resetWin = w5h or w1w
  local row2, row2str
  if b.showReset and not b.text then
    row2str = (resetWin and resetWin.resetsAt and fmtClock(resetWin.resetsAt)) or "—"
    row2 = seg(row2str, NEUTRAL_COLOR)
  end

  -- Monospace → width from glyph count (utf8: "·" is multi-byte).
  local chars = utf8.len(row1str)
  if row2str then chars = math.max(chars, utf8.len(row2str)) end
  local textX = BRAND_W + GAP_W + BAR_W + 2
  local textW = math.ceil(chars * CHAR_W) + (b.text and 8 or 2)  -- fallback-font glyphs run wider

  local canvas = hs.canvas.new({ x = 0, y = 0, w = textX + textW, h = ICON_H })

  -- Vertical provider label + bar (bar driven by the 5h percent).
  drawVerticalLabel(canvas, b.label)
  local fillH = (type(fh) == "number")
    and math.floor(math.max(0, math.min(100, fh)) * ICON_H / 100 + 0.5) or 0
  drawBar(canvas, BRAND_W + GAP_W, fillH, colorForUsed(fh))

  -- Text rows: two stacked when reset shown, else one vertically centered.
  if row2 then
    local top = math.floor((ICON_H - ROW_H * 2) / 2)
    canvas:appendElements({ type = "text", text = row1, frame = { x = textX, y = top,         w = textW, h = ROW_H + 2 } })
    canvas:appendElements({ type = "text", text = row2, frame = { x = textX, y = top + ROW_H, w = textW, h = ROW_H + 2 } })
  else
    local top = math.floor((ICON_H - ROW_H) / 2)
    canvas:appendElements({ type = "text", text = row1, frame = { x = textX, y = top, w = textW, h = ROW_H + 2 } })
  end

  local img = canvas:imageFromCanvas()
  canvas:delete()
  return img, textX + textW
end

-- Composites all blocks side-by-side into one image: one menubar item for
-- every account, so macOS pads the whole strip once (~17px) instead of per
-- account. Returns an hs.image.
local BLOCK_GAP = 7
local function buildComboIcon(blocks)
  local imgs, widths, total = {}, {}, 0
  for i, b in ipairs(blocks) do
    local img, wd = buildBlockIcon(b)
    imgs[i], widths[i] = img, wd
    total = total + wd + (i > 1 and BLOCK_GAP or 0)
  end
  local canvas = hs.canvas.new({ x = 0, y = 0, w = total, h = ICON_H })
  local x = 0
  for i, img in ipairs(imgs) do
    if i > 1 then x = x + BLOCK_GAP end
    canvas:appendElements({ type = "image", image = img, frame = { x = x, y = 0, w = widths[i], h = ICON_H } })
    x = x + widths[i]
  end
  local out = canvas:imageFromCanvas()
  canvas:delete()
  return out
end

-- Finds the Codex "Spark" per-model entry in additional[] (label matched
-- case-insensitively). Returns { label, fiveHour, weekly } or nil.
local function sparkEntry(s)
  if not (s and s.additional) then return nil end
  for _, a in ipairs(s.additional) do
    if a.label and a.label:lower():find("spark", 1, true) then
      return a
    end
  end
  return nil
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
-- Account registry
---------------------------------------------------------------------

function M.save() state.saveAccounts(M.accounts) end

local function visibleCount()
  local n = 0
  for _, a in ipairs(M.accounts) do if not a.hidden then n = n + 1 end end
  return n
end

local function fmtDays(epoch)
  if not epoch then return nil end
  local d = math.floor((epoch - os.time()) / 86400)
  if d < 0 then return "expired" end
  if d == 0 then return "today" end
  return d .. "d"
end

-- Opens the login window for `acct`; on success stores the harvested cookie
-- and refreshes. Shared by "Log in…" and "Add … account".
local function loginInto(acct, provider, onDone)
  login.open(provider, function(ck, exp, domainCookies)
    if not ck then
      hs.alert.show("No " .. provider.loginLabel .. " session found")
      return
    end
    acct.cookie, acct.cookieExpires = ck, exp
    if provider.afterLogin then provider.afterLogin(acct, domainCookies) end
    M.save()
    if onDone then onDone() end
  end)
end

local function refreshAcct(acct)
  local inst = M.instances[acct.id]; if inst then inst.refresh() end
end

function M.addAccount(providerId)
  local provider = M.PROVIDERS[providerId]
  local acct = { id = providerId .. "-" .. os.time(), provider = providerId }
  loginInto(acct, provider, function()
    table.insert(M.accounts, acct)
    M.save()
    M.start(acct)
  end)
end

-- Log out = drop the account. The only remaining account can't vanish (the
-- menu must stay reachable), so it just loses its session instead.
function M.logoutAccount(acct)
  local provider = M.PROVIDERS[acct.provider]
  provider.logout(acct, function()
    acct.cookie, acct.cookieExpires = nil, nil
    M.save()
    if #M.accounts > 1 then M.removeAccount(acct.id) else refreshAcct(acct) end
  end)
end

function M.removeAccount(id)
  if #M.accounts <= 1 then hs.alert.show("Can't remove the only account"); return end
  local inst = M.instances[id]
  if inst then inst.stop(); M.instances[id] = nil end
  for i, a in ipairs(M.accounts) do
    if a.id == id then table.remove(M.accounts, i); break end
  end
  -- Never leave the menu bar empty: unhide the first remaining account.
  if visibleCount() == 0 then M.setHidden(M.accounts[1], false) end
  M.save()
  M.applyAllTitles()
end

-- Hidden accounts keep their session but get no block; useful when the menu
-- bar overflows. The last visible block can't be hidden.
function M.setHidden(acct, hidden)
  if hidden and visibleCount() <= 1 then hs.alert.show("Keep at least one block visible"); return end
  acct.hidden = hidden or nil
  M.save()
  local inst = M.instances[acct.id]
  if hidden and inst then inst.stop(); M.instances[acct.id] = nil end
  if not hidden and not inst then M.start(acct) end
  M.applyAllTitles()
end

---------------------------------------------------------------------
-- Menus
---------------------------------------------------------------------

local function windowBlock(items, title, win)
  if win then
    table.insert(items, { title = title, disabled = true })
    table.insert(items, { title = "    " .. win.percentUsed .. "% used", disabled = true })
    table.insert(items, { title = "    resets in " .. resetStr(win), disabled = true })
  else
    table.insert(items, { title = title .. ": —", disabled = true })
  end
end

-- Top-level entry text: "claude  ·  me@x.com" plus a state suffix when not ok.
local function accountTitle(acct)
  local provider = M.PROVIDERS[acct.provider]
  local inst = M.instances[acct.id]
  local s = inst and inst.s or {}
  local who = s.account and s.account.email or provider.loginLabel
  local t = (acct.label or provider.label) .. "  ·  " .. who
  if acct.hidden then t = t .. "  ·  hidden"
  elseif s.status == "needs_login" then t = t .. "  ·  ⚠ login"
  elseif s.status == "error" then t = t .. "  ·  ⚠ error"
  elseif s.status == "init" then t = t .. "  ·  loading…"
  end
  return t
end

-- Submenu for one account: usage detail, session actions, block settings.
local function accountMenu(acct)
  local provider = M.PROVIDERS[acct.provider]
  local inst = M.instances[acct.id]
  local s = inst and inst.s or { status = acct.hidden and "hidden" or "stopped" }
  local items = {}
  local loggedIn = s.status == "ok" and s.account and s.account.email ~= nil
  local function refresh() refreshAcct(acct) end

  if loggedIn then
    windowBlock(items, "5h window", s.fiveHour)
    windowBlock(items, "1w window", s.weekly)
    if s.weeklySonnet then windowBlock(items, "1w · Sonnet only", s.weeklySonnet) end

    local hasAdditional = s.additional and #s.additional > 0
    local showSpark = get("spark_bar", false) == true
    if hasAdditional and showSpark then
      for _, a in ipairs(s.additional) do
        table.insert(items, { title = "-" })
        table.insert(items, { title = a.label or "additional", disabled = true })
        windowBlock(items, "5h window", a.fiveHour)
        windowBlock(items, "1w window", a.weekly)
      end
    end
    if hasAdditional then
      table.insert(items, { title = "-" })
      table.insert(items, {
        title = "Show per-model limits",
        checked = showSpark,
        fn = function() set("spark_bar", not showSpark); M.applyAllTitles() end,
      })
    end

    if provider.hasExtraUsage and s.extraUsage then
      local eu = s.extraUsage
      table.insert(items, { title = "-" })
      table.insert(items, { title = "Extra usage", disabled = true })
      local usageLine = "    " .. fmtMoney(eu.usedCredits, eu.currency)
             .. " / " .. fmtMoney(eu.monthlyLimit, eu.currency)
             .. (eu.utilization and string.format(" (%d%%)", eu.utilization) or "")
      if eu.isEnabled then
        local labelColor = { list = "System", name = "labelColor" }
        table.insert(items, { title = hs.styledtext.new(usageLine, { color = labelColor }), disabled = true })
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
        fn = function()
          hs.alert.show("Extra usage: updating…", 2)
          provider.toggleExtraUsage(acct, s, function(ok, msg) hs.alert.show(msg); refresh() end)
        end,
      })
    end

    if s.warnings and #s.warnings > 0 then
      table.insert(items, { title = "-" })
      table.insert(items, { title = "⚠  Widget needs attention", disabled = true })
      for _, w in ipairs(s.warnings) do
        table.insert(items, { title = "      • " .. tostring(w), disabled = true })
      end
    end
    table.insert(items, { title = "-" })
  end

  local health = string.format("State: %s · %s · avg %dms",
    s.status or "?", humanAgo(s.lastFetch), state.avgFetchMs())
  local exp = fmtDays(acct.cookieExpires)
  if exp then health = health .. " · session " .. exp end
  table.insert(items, { title = health, disabled = true })
  if s.errorMsg then
    table.insert(items, { title = "  " .. tostring(s.errorMsg):sub(1, 120), disabled = true })
  end

  table.insert(items, { title = "-" })
  if loggedIn then
    table.insert(items, { title = "Refresh now", fn = refresh })
    if provider.openSettingsLabel and provider.openSettingsUrl then
      table.insert(items, { title = "Open " .. provider.openSettingsLabel, fn = function() openUrl(provider.openSettingsUrl) end })
    end
    local logoutLabel = (#M.accounts > 1 and "Log out & remove (" or "Log out (") .. s.account.email
                     .. (s.account.orgName and (" · " .. s.account.orgName) or "") .. ")"
    table.insert(items, { title = logoutLabel, fn = function() M.logoutAccount(acct) end })
  elseif acct.cookie and inst then
    table.insert(items, { title = "Refresh now", fn = refresh })
    table.insert(items, { title = #M.accounts > 1 and "Log out & remove" or "Log out", fn = function() M.logoutAccount(acct) end })
  else
    table.insert(items, {
      title = (s.status == "needs_login" and "⚠  " or "") .. "Log in to " .. provider.loginLabel .. "…",
      fn = function() loginInto(acct, provider, refresh) end,
    })
  end

  table.insert(items, { title = "-" })
  table.insert(items, { title = "Rename…", fn = function()
    local btn, text = hs.dialog.textPrompt("Account label", "Short label shown on the block (up to 7 chars):", acct.label or "", "OK", "Cancel")
    if btn == "OK" then
      acct.label = text ~= "" and text or nil
      M.save()
      M.applyAllTitles()
    end
  end })
  table.insert(items, { title = "Show in menu bar", checked = not acct.hidden, fn = function() M.setHidden(acct, not acct.hidden) end })
  if not acct.cookie then
    table.insert(items, { title = "Remove account", disabled = #M.accounts <= 1, fn = function() M.removeAccount(acct.id) end })
  end
  return items
end

local function debugMenu()
  return {
    { title = "Open Hammerspoon console", fn = function() hs.openConsole() end },
    { title = "Dump fetcher response to debug/<account>-last-fetcher.json",
      checked = get("dump_fetcher", false) == true,
      fn = function() set("dump_fetcher", not (get("dump_fetcher", false) == true)) end },
    { title = "-" },
    { title = "Force re-fetch now (all)", fn = M.refreshAll },
    { title = "Copy state JSON (all accounts)", fn = function()
        local all = {}
        for id, inst in pairs(M.instances) do all[id] = inst.s end
        hs.pasteboard.setContents(hs.json.encode(all, true))
        hs.alert.show("state JSON copied")
      end },
    { title = "Copy fetch log (in-memory)", fn = function()
        hs.pasteboard.setContents(table.concat(state.logRing, "\n"))
        hs.alert.show("log copied (" .. #state.logRing .. " lines)")
      end },
    { title = "Open debug dir", fn = function() openUrl("file://" .. DEBUG_DIR) end },
    { title = "-" },
    { title = "Wipe login-window browser data (all sites)", fn = function()
        hs.webview.datastore.default():removeRecordsAfter(0, hs.webview.datastore.websiteDataTypes(), function()
          hs.alert.show("browser data wiped")
        end)
      end },
    { title = "Reload module (hot)", fn = function()
        M.stopAll()
        for _, mod in ipairs({ "", ".menubar", ".session", ".login", ".claude", ".codex", ".grok", ".grokbot", ".state", ".updater" }) do
          package.loaded[PREFIX .. mod] = nil
        end
        require(PREFIX)
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
end

local function updatesMenu(us)
  local upItems = {
    { title = us.checking and "Checking…" or "Check for updates now",
      disabled = us.checking,
      fn = function()
        updater.forceCheck = true
        hs.alert.show("Checking for updates…")
        updater.checkNow(function(st)
          if st.error then hs.alert.show("Check failed: " .. st.error)
          elseif (st.behind or 0) == 0 then hs.alert.show("Up to date")
          else hs.alert.show(string.format("%d update%s available", st.behind, st.behind == 1 and "" or "s")) end
        end)
      end },
  }
  if us.behind and us.behind > 0 then
    table.insert(upItems, { title = "Apply update & reload", disabled = us.updating, fn = function() updater.apply() end })
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
  table.insert(upItems, { title = "Check daily", checked = us.autoCheck, fn = function() updater.setAutoCheck(not us.autoCheck) end })
  table.insert(upItems, { title = "Auto-apply updates", checked = us.autoApply, fn = function() updater.setAutoApply(not us.autoApply) end })
  table.insert(upItems, { title = "Live reload on file save", checked = us.liveReload, fn = function() updater.setLiveReload(not us.liveReload) end })
  table.insert(upItems, { title = "-" })
  table.insert(upItems, { title = "Last check: " .. (us.lastCheck and humanAgo(us.lastCheck) or "never"), disabled = true })
  if us.dirty then table.insert(upItems, { title = "⚠ Working tree dirty — apply blocked", disabled = true }) end
  if us.error then table.insert(upItems, { title = "⚠ " .. us.error:sub(1, 100), disabled = true }) end
  return upItems
end

-- Main menu: one submenu per account, then the global sections.
-- compact (ctrl/alt-click): flat usage lines for every account.
function M.buildMenu(compact)
  local items = {}
  if compact then
    for _, a in ipairs(M.accounts) do
      local inst = M.instances[a.id]
      local s = inst and inst.s or {}
      if #items > 0 then table.insert(items, { title = "-" }) end
      table.insert(items, { title = accountTitle(a), disabled = true })
      table.insert(items, { title = "    5h: " .. tupleOrDash(s.fiveHour), disabled = true })
      table.insert(items, { title = "    1w: " .. tupleOrDash(s.weekly),   disabled = true })
      if get("spark_bar", false) and s.additional then
        for _, x in ipairs(s.additional) do
          table.insert(items, { title = "    " .. (x.label or "additional"), disabled = true })
          table.insert(items, { title = "        5h: " .. tupleOrDash(x.fiveHour), disabled = true })
          table.insert(items, { title = "        1w: " .. tupleOrDash(x.weekly),   disabled = true })
        end
      end
    end
    table.insert(items, { title = "-" })
    table.insert(items, { title = "Refresh all", fn = M.refreshAll })
    return items
  end

  for _, a in ipairs(M.accounts) do
    table.insert(items, { title = accountTitle(a), menu = accountMenu(a) })
  end
  table.insert(items, { title = "-" })

  local addItems = {}
  for _, p in ipairs(M.PROVIDER_ORDER) do
    table.insert(addItems, { title = M.PROVIDERS[p].loginLabel .. "…", fn = function() M.addAccount(p) end })
  end
  table.insert(items, { title = "Add account", menu = addItems })

  local fmtItems = {}
  for _, f in ipairs(FORMATS) do
    table.insert(fmtItems, {
      title = FORMAT_LABELS[f] or f,
      checked = get("format", DEFAULT_FORMAT) == f,
      fn = function() set("format", f); M.applyAllTitles() end,
    })
  end
  table.insert(items, { title = "Display format", menu = fmtItems })

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
  table.insert(items, { title = "Updates", menu = updatesMenu(us) })
  table.insert(items, { title = "Debug", menu = debugMenu() })

  table.insert(items, { title = "-" })
  local verLine = "About claude-usage v" .. M.VERSION
  if us.sha then verLine = verLine .. " · " .. us.sha end
  table.insert(items, { title = verLine, disabled = true })
  table.insert(items, { title = "    " .. os.getenv("HOME") .. "/.hammerspoon/claude_usage", disabled = true })
  table.insert(items, { title = "Quit", fn = function() M.stopAll() end })
  return items
end

---------------------------------------------------------------------
-- The single menubar item + per-account fetch loops
---------------------------------------------------------------------

local function ensureBar()
  if M.bar then return end
  M.bar = hs.menubar.new()
  if not M.bar then log.e("hs.menubar.new returned nil"); return end
  M.bar:setTitle("… loading")
  M.bar:setMenu(function(mods) return M.buildMenu(mods and (mods.ctrl or mods.alt)) end)
  M.titleTimer = hs.timer.doEvery(60, M.applyAllTitles)  -- reset clocks tick
  if not M._updaterStarted then
    updater.start()
    M._updaterStarted = true
  end
end

-- Redraws the strip: every visible account's blocks, in registry order.
function M.applyAllTitles()
  if not M.bar then return end
  local blocks = {}
  for _, a in ipairs(M.accounts) do
    local inst = M.instances[a.id]
    if inst then for _, b in ipairs(inst.blocks()) do blocks[#blocks + 1] = b end end
  end
  if #blocks == 0 then
    M.bar:setIcon(nil, false); M.bar:setTitle("⚠ login")
    return
  end
  M.bar:setIcon(buildComboIcon(blocks), false)
  M.bar:setTitle("")
end

function M.refreshAll()
  for _, inst in pairs(M.instances) do inst.refresh() end
end

-- acct is a live entry of M.accounts (mutated in place, then M.save()).
function M.start(acct)
  if acct.hidden then return nil end
  local provider = assert(M.PROVIDERS[acct.provider], "unknown provider " .. tostring(acct.provider))
  local instance = { acct = acct, provider = provider, s = { status = "init" } }

  -- Blocks this account contributes to the strip. Codex with Spark enabled
  -- adds a second block for the per-model limit.
  function instance.blocks()
    local s = instance.s
    local label = acct.label or provider.label
    if s.status ~= "ok" or not (s.fiveHour or s.weekly) then
      return { { label = label, text = s.status == "init" and "…" or "⚠" } }
    end
    local showReset = get("format", DEFAULT_FORMAT) == "compact_reset"
    local blocks = { { label = label, w5h = s.fiveHour, w1w = s.weekly, showReset = showReset } }
    if provider.id == "codex" and get("spark_bar", false) then
      local a = sparkEntry(s)
      if a and (a.fiveHour or a.weekly) then
        blocks[#blocks + 1] = { label = "spark", w5h = a.fiveHour, w1w = a.weekly, showReset = showReset }
      end
    end
    return blocks
  end

  function instance.refresh()
    log.d(acct.id .. " refresh")
    local t0 = hs.timer.secondsSinceEpoch()
    provider.fetch(acct, function(parsed)
      local dt = math.floor((hs.timer.secondsSinceEpoch() - t0) * 1000)
      state.recordTiming(dt)
      parsed.lastFetch = os.time()
      parsed.fetchTiming = { totalMs = dt }
      if parsed.newCookie then
        acct.cookie = parsed.newCookie; parsed.newCookie = nil; M.save()
      end
      if parsed.raw and get("dump_fetcher", false) then
        hs.fs.mkdir(DEBUG_DIR)
        local f = io.open(DEBUG_DIR .. "/" .. acct.id .. "-last-fetcher.json", "w")
        if f then f:write(hs.json.encode(parsed.raw, true)); f:close() end
      end
      instance.s = parsed
      log.i(string.format("%s fetch dt=%dms status=%s", acct.id, dt, parsed.status or "?"))
      M.applyAllTitles()
    end)
  end

  function instance.stop()
    if instance.fetchTimer then instance.fetchTimer:stop() end
  end

  M.instances[acct.id] = instance
  ensureBar()
  instance.refresh()
  instance.fetchTimer = hs.timer.doEvery(60, instance.refresh)
  log.i("started v" .. M.VERSION .. " account=" .. acct.id)
  state.log("i", "started v" .. M.VERSION .. " (" .. acct.id .. ")")
  return instance
end

function M.stopAll()
  for _, inst in pairs(M.instances) do inst.stop() end
  M.instances = {}
  if M.titleTimer then M.titleTimer:stop(); M.titleTimer = nil end
  if M.bar then M.bar:delete(); M.bar = nil end
  if M._updaterStarted then
    updater.stop()
    M._updaterStarted = false
  end
end

return M
