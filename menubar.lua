local PREFIX = ((...) or "claude_usage"):gsub("%.[^.]+$", "")
local state = require(PREFIX .. ".state")
local updater = require(PREFIX .. ".updater")
local session = require(PREFIX .. ".session")
local login = require(PREFIX .. ".login")
local log = state.logger("menubar")
local get, set = state.get, state.set

local M = {}
M.VERSION = "0.3.3"
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
  if h >= 24 then
    local days = math.floor(h / 24); h = h % 24
    return string.format("%dd%dh", days, h)
  end
  return string.format("%d:%02d", h, m)
end

local function fiveHourResetClock(s)
  local w = s.fiveHour or s.weekly
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

-- Builds a full menubar block image: brand glyph + bar + stacked text rows.
-- showReset toggles the second (reset clock) row. Returns an hs.image.
local function buildBlockIcon(label, w5h, w1w, showReset)
  -- Weekly-only providers (Codex since 2026-07 has no 5h window): render a
  -- single number driven by the weekly window instead of "?·N".
  local single = (not w5h) ~= (not w1w)
  local fh = single and (w5h or w1w).percentUsed or (w5h and w5h.percentUsed or "?")
  local w  = w1w and w1w.percentUsed or "?"
  local row1str = single and tostring(fh) or (tostring(fh) .. "·" .. tostring(w))
  local row1 = single and seg(tostring(fh), colorForUsed(fh)) or pctRow(fh, w)
  local resetWin = w5h or w1w
  local row2, row2str
  if showReset then
    row2str = (resetWin and resetWin.resetsAt and fmtClock(resetWin.resetsAt)) or "—"
    row2 = seg(row2str, NEUTRAL_COLOR)
  end

  -- Monospace → width from glyph count (utf8: "·" is multi-byte).
  local chars = utf8.len(row1str)
  if row2str then chars = math.max(chars, utf8.len(row2str)) end
  local textX = BRAND_W + GAP_W + BAR_W + 2
  local textW = math.ceil(chars * CHAR_W) + 2

  local canvas = hs.canvas.new({ x = 0, y = 0, w = textX + textW, h = ICON_H })

  -- Vertical provider label + bar (bar driven by the 5h percent).
  drawVerticalLabel(canvas, label)
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

-- Composites several blocks side-by-side into one image, so multiple usage
-- blocks can live in a single menubar item (no system gap between them).
-- blocks = list of { label, w5h, w1w, showReset }. Returns an hs.image.
local BLOCK_GAP = 7
local function buildComboIcon(blocks)
  local imgs, widths, total = {}, {}, 0
  for i, b in ipairs(blocks) do
    local img, wd = buildBlockIcon(b.label, b.w5h, b.w1w, b.showReset)
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

local visibleCount  -- defined below (forward declaration for removeAccount)

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
    if #M.accounts > 1 then
      M.removeAccount(acct.id)
    else
      local inst = M.instances[acct.id]; if inst then inst.refresh() end
    end
  end)
end

function M.removeAccount(id)
  if #M.accounts <= 1 then hs.alert.show("Can't remove the only account"); return end
  local target
  for _, a in ipairs(M.accounts) do if a.id == id then target = a end end
  local inst = M.instances[id]
  if inst then inst.stop(); M.instances[id] = nil end
  for i, a in ipairs(M.accounts) do
    if a.id == id then table.remove(M.accounts, i); break end
  end
  -- Never leave the menu bar empty: unhide the first remaining account.
  if visibleCount() == 0 then M.setHidden(M.accounts[1], false) end
  M.save()
end

function visibleCount()
  local n = 0
  for _, a in ipairs(M.accounts) do if not a.hidden then n = n + 1 end end
  return n
end

-- Hidden accounts keep their session but get no menubar item; useful when
-- the menu bar overflows. The last visible item can't be hidden.
function M.setHidden(acct, hidden)
  if hidden and visibleCount() <= 1 then hs.alert.show("Keep at least one item visible"); return end
  acct.hidden = hidden or nil
  M.save()
  local inst = M.instances[acct.id]
  if hidden and inst then inst.stop(); M.instances[acct.id] = nil end
  if not hidden and not inst then M.start(acct) end
end

local function statusLine(acct)
  local inst = M.instances[acct.id]
  local s = inst and inst.s or {}
  local parts = { acct.hidden and "hidden" or (s.status or "—") }
  if s.status == "ok" then
    parts[#parts + 1] = (s.fiveHour and (s.fiveHour.percentUsed .. "% 5h") or nil)
    parts[#parts + 1] = (s.weekly and (s.weekly.percentUsed .. "% 1w") or nil)
  elseif not acct.cookie then
    parts[#parts + 1] = "no session"
  end
  if acct.cookieExpires then parts[#parts + 1] = "session " .. fmtDays(acct.cookieExpires) end
  return table.concat(parts, " · ")
end

-- One submenu per account, reachable from every item, so accounts whose
-- icon is hidden or pushed off the menu bar can still be managed.
function M.accountsMenu()
  local items = {}
  for _, p in ipairs(M.PROVIDER_ORDER) do
    table.insert(items, { title = "Add " .. M.PROVIDERS[p].loginLabel .. " account…", fn = function() M.addAccount(p) end })
  end
  table.insert(items, { title = "-" })
  for _, a in ipairs(M.accounts) do
    local provider = M.PROVIDERS[a.provider]
    local inst = M.instances[a.id]
    local email = inst and inst.s and inst.s.account and inst.s.account.email
    local sub = {
      { title = statusLine(a) .. (email and (" · " .. email) or ""), disabled = true },
      { title = "-" },
    }
    if a.cookie then
      table.insert(sub, { title = "Refresh now", disabled = not inst, fn = function() if inst then inst.refresh() end end })
      table.insert(sub, { title = #M.accounts > 1 and "Log out & remove" or "Log out", fn = function() M.logoutAccount(a) end })
    else
      table.insert(sub, { title = "Log in to " .. provider.loginLabel .. "…", fn = function()
        loginInto(a, provider, function() local i = M.instances[a.id]; if i then i.refresh() end end)
      end })
    end
    table.insert(sub, { title = "Rename…", fn = function()
      local btn, text = hs.dialog.textPrompt("Account label", "Short label shown on the menubar icon (up to 7 chars):", a.label or "", "OK", "Cancel")
      if btn == "OK" then
        a.label = text ~= "" and text or nil
        M.save()
        local i = M.instances[a.id]; if i then i.applyTitle() end
      end
    end })
    table.insert(sub, { title = "Show in menu bar", checked = not a.hidden, fn = function() M.setHidden(a, not a.hidden) end })
    if not a.cookie then
      table.insert(sub, { title = "-" })
      table.insert(sub, { title = "Remove account", disabled = #M.accounts <= 1, fn = function() M.removeAccount(a.id) end })
    end
    table.insert(items, { title = (a.label or provider.label) .. "  ·  " .. provider.loginLabel .. "  ·  " .. statusLine(a), menu = sub })
  end
  return items
end

---------------------------------------------------------------------
-- Per-instance machinery
---------------------------------------------------------------------

-- acct is a live entry of M.accounts (mutated in place, then M.save()).
function M.start(acct)
  if acct.hidden then return nil end
  local provider = assert(M.PROVIDERS[acct.provider], "unknown provider " .. tostring(acct.provider))
  local pid = provider.id
  local instance = { acct = acct, provider = provider, s = { status = "init" } }
  local function label() return acct.label or provider.label end
  local function getState() return instance.s end

  local function formatTitle()
    local s = getState()
    if s.status == "needs_login" then return "⚠ login" end
    if s.status == "init" then return "… loading" end
    if s.status == "error" and not (s.fiveHour or s.weekly) then return "⚠ err" end
    local fmt = get("format", DEFAULT_FORMAT)
    if (not s.fiveHour) ~= (not s.weekly) then
      local w = (s.fiveHour or s.weekly).percentUsed
      local st = run(tostring(w), colorForUsed(w))
      if fmt == "labeled" then return run("1w", NEUTRAL_COLOR) .. st end
      if fmt == "compact_reset" then
        return st .. run(" " .. (fiveHourResetClock(s) or "—"), NEUTRAL_COLOR)
      end
      return st
    end
    local fh = s.fiveHour and s.fiveHour.percentUsed or "?"
    local w = s.weekly and s.weekly.percentUsed or "?"
    if fmt == "labeled" then return labeledStyled(fh, w) end
    if fmt == "compact_reset" then return compactStyled(fh, w, fiveHourResetClock(s) or "—") end
    return compactStyled(fh, w, nil)
  end

  -- Codex with Spark enabled composites the two blocks into one image.
  local function currentBarIcon()
    local s = getState()
    if s.status ~= "ok" or not (s.fiveHour or s.weekly) then return nil end
    local showReset = get("format", DEFAULT_FORMAT) == "compact_reset"
    local blocks = { { label = label(), w5h = s.fiveHour, w1w = s.weekly, showReset = showReset } }
    if pid == "codex" and get("spark_bar", false) then
      local a = sparkEntry(s)
      if a and (a.fiveHour or a.weekly) then
        blocks[#blocks + 1] = { label = "spark", w5h = a.fiveHour, w1w = a.weekly, showReset = showReset }
      end
    end
    if #blocks == 1 then
      local b = blocks[1]
      return (buildBlockIcon(b.label, b.w5h, b.w1w, b.showReset))
    end
    return buildComboIcon(blocks)
  end

  local function applyTitle()
    if not instance.bar then return end
    local icon = currentBarIcon()
    if icon then
      instance.bar:setIcon(icon, false)
      instance.bar:setTitle("")
    else
      instance.bar:setIcon(nil, false)
      instance.bar:setTitle(formatTitle())
    end
  end

  local function refresh()
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
      applyTitle()
    end)
  end

  local function doLogin() loginInto(acct, provider, refresh) end

  local function doLogout() M.logoutAccount(acct) end

  local function toggleExtraUsage()
    if not provider.toggleExtraUsage then return end
    hs.alert.show("Extra usage: updating…", 2)
    provider.toggleExtraUsage(acct, getState(), function(ok, msg)
      hs.alert.show(msg)
      refresh()
    end)
  end

  local function windowBlock(items, title, win)
    if win then
      table.insert(items, { title = title, disabled = true })
      table.insert(items, { title = "    " .. win.percentUsed .. "% used", disabled = true })
      table.insert(items, { title = "    resets in " .. resetStr(win), disabled = true })
    else
      table.insert(items, { title = title .. ": —", disabled = true })
    end
  end

  local function buildMenu(compact)
    local s = getState()

    if compact then
      local m = {
        { title = "5h: " .. tupleOrDash(s.fiveHour), disabled = true },
        { title = "1w: " .. tupleOrDash(s.weekly),   disabled = true },
      }
      if get("spark_bar", false) and s.additional then
        for _, a in ipairs(s.additional) do
          table.insert(m, { title = "-" })
          table.insert(m, { title = a.label or "additional", disabled = true })
          table.insert(m, { title = "5h: " .. tupleOrDash(a.fiveHour), disabled = true })
          table.insert(m, { title = "1w: " .. tupleOrDash(a.weekly),   disabled = true })
        end
      end
      table.insert(m, { title = "-" })
      table.insert(m, { title = "Refresh now", fn = refresh })
      return m
    end

    local items = {}
    local loggedIn = s.status == "ok" and s.account and s.account.email ~= nil

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
        table.insert(items, {
          title = "Open " .. provider.openSettingsLabel,
          fn = function() openUrl(provider.openSettingsUrl) end,
        })
      end
      local logoutLabel = (#M.accounts > 1 and "Log out & remove (" or "Log out (") .. s.account.email
                       .. (s.account.orgName and (" · " .. s.account.orgName) or "") .. ")"
      table.insert(items, { title = logoutLabel, fn = doLogout })
    else
      table.insert(items, {
        title = (s.status == "needs_login" and "⚠  " or "") .. "Log in to " .. provider.loginLabel .. "…",
        fn = doLogin,
      })
    end

    table.insert(items, { title = "Accounts", menu = M.accountsMenu() })

    local fmtItems = {}
    for _, f in ipairs(FORMATS) do
      table.insert(fmtItems, {
        title = FORMAT_LABELS[f] or f,
        checked = get("format", DEFAULT_FORMAT) == f,
        fn = function() set("format", f); M.applyAllTitles() end,
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
    table.insert(items, { title = "Updates", menu = upItems })

    local debugItems = {
      { title = "Open Hammerspoon console", fn = function() hs.openConsole() end },
      { title = "Dump fetcher response to debug/<account>-last-fetcher.json",
        checked = get("dump_fetcher", false) == true,
        fn = function() set("dump_fetcher", not (get("dump_fetcher", false) == true)) end },
      { title = "-" },
      { title = "Force re-fetch now", fn = refresh },
      { title = "Copy state JSON", fn = function()
          hs.pasteboard.setContents(hs.json.encode(getState(), true))
          hs.alert.show("state JSON copied (" .. acct.id .. ")")
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
    table.insert(items, { title = "Debug", menu = debugItems })

    table.insert(items, { title = "-" })
    local verLine = "About claude-usage v" .. M.VERSION .. " · " .. acct.id
    if us.sha then verLine = verLine .. " · " .. us.sha end
    table.insert(items, { title = verLine, disabled = true })
    table.insert(items, { title = "    " .. os.getenv("HOME") .. "/.hammerspoon/claude_usage", disabled = true })
    table.insert(items, { title = "Quit", fn = function() M.stopAll() end })

    return items
  end

  instance.bar = hs.menubar.new()
  if not instance.bar then
    log.e("hs.menubar.new returned nil for " .. acct.id)
    return nil
  end
  instance.bar:setTitle("… loading")
  instance.bar:setMenu(function(mods) return buildMenu(mods and (mods.ctrl or mods.alt)) end)

  if not M._updaterStarted then
    updater.start()
    M._updaterStarted = true
  end

  instance.refresh = refresh
  instance.applyTitle = applyTitle
  instance.stop = function()
    if instance.fetchTimer then instance.fetchTimer:stop() end
    if instance.titleTimer then instance.titleTimer:stop() end
    if instance.bar then instance.bar:delete(); instance.bar = nil end
  end

  refresh()
  instance.fetchTimer = hs.timer.doEvery(60, refresh)
  instance.titleTimer = hs.timer.doEvery(60, applyTitle)

  M.instances[acct.id] = instance
  log.i("started v" .. M.VERSION .. " account=" .. acct.id)
  state.log("i", "started v" .. M.VERSION .. " (" .. acct.id .. ")")
  return instance
end

function M.applyAllTitles()
  for _, inst in pairs(M.instances) do
    if inst.applyTitle then inst.applyTitle() end
  end
end

function M.stopAll()
  for _, inst in pairs(M.instances) do inst.stop() end
  M.instances = {}
  if M._updaterStarted then
    updater.stop()
    M._updaterStarted = false
  end
end

return M
