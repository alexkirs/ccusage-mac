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
local PROVIDER_LABEL = { claude = "claude", codex = "codex", spark = "spark" }

local function drawVerticalLabel(canvas, providerId)
  local text = PROVIDER_LABEL[providerId] or providerId or "?"
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
local function buildBlockIcon(providerId, w5h, w1w, showReset)
  -- Weekly-only providers (Codex since 2026-07 has no 5h window): render a
  -- single number driven by the weekly window instead of "?·N".
  local single = not w5h and w1w
  local fh = single and w1w.percentUsed or (w5h and w5h.percentUsed or "?")
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
  drawVerticalLabel(canvas, providerId)
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
-- blocks = list of { providerId, w5h, w1w, showReset }. Returns an hs.image.
local BLOCK_GAP = 7
local function buildComboIcon(blocks)
  local imgs, widths, total = {}, {}, 0
  for i, b in ipairs(blocks) do
    local img, wd = buildBlockIcon(b.providerId, b.w5h, b.w1w, b.showReset)
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
    if s.status == "error" and not (s.fiveHour or s.weekly) then return "⚠ err" end
    local fmt = get("format", DEFAULT_FORMAT)
    -- Weekly-only provider: single number instead of "?·N".
    if not s.fiveHour and s.weekly then
      local w = s.weekly.percentUsed
      local st = run(tostring(w), colorForUsed(w))
      if fmt == "labeled" then
        return run("1w", NEUTRAL_COLOR) .. st
      end
      if fmt == "compact_reset" then
        return st .. run(" " .. (fiveHourResetClock(s) or "—"), NEUTRAL_COLOR)
      end
      return st
    end
    local fh = s.fiveHour and s.fiveHour.percentUsed or "?"
    local w = s.weekly and s.weekly.percentUsed or "?"
    if fmt == "labeled" then return labeledStyled(fh, w) end
    if fmt == "compact_reset" then
      return compactStyled(fh, w, fiveHourResetClock(s) or "—")
    end
    return compactStyled(fh, w, nil)
  end

  -- Builds the item image. For Codex with Spark enabled, the Codex and Spark
  -- blocks are composited into one image (single item, no system gap between
  -- them). All other cases are a single block.
  local function currentBarIcon()
    local s = getState()
    if s.status ~= "ok" or not (s.fiveHour or s.weekly) then return nil end
    local showReset = get("format", DEFAULT_FORMAT) == "compact_reset"
    local blocks = { { providerId = pid, w5h = s.fiveHour, w1w = s.weekly, showReset = showReset } }
    if pid == "codex" and get("spark_bar", false) then
      local a = sparkEntry(s)
      if a and (a.fiveHour or a.weekly) then
        blocks[#blocks + 1] = { providerId = "spark", w5h = a.fiveHour, w1w = a.weekly, showReset = showReset }
      end
    end
    if #blocks == 1 then
      local b = blocks[1]
      return (buildBlockIcon(b.providerId, b.w5h, b.w1w, b.showReset))
    end
    return buildComboIcon(blocks)
  end

  local function applyTitle()
    if not instance.bar then return end
    -- silence: glyph()/glyphColor() values not currently rendered as text icon;
    -- the colored bar canvas via setIcon is the visible glyph. Keep helpers in
    -- case future modes need them.
    local _, _ = glyph(), glyphColor()
    local icon = currentBarIcon()
    if icon then
      -- Data lives in the stacked image; clear the text title.
      instance.bar:setIcon(icon, false)
      instance.bar:setTitle("")
    else
      -- Not-ok states (login/loading/error): show status text, no image.
      instance.bar:setIcon(nil, false)
      instance.bar:setTitle(formatTitle())
    end
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
      local m = {
        { title = "5h: " .. tupleOrDash(s.fiveHour), disabled = true },
        { title = "1w: " .. tupleOrDash(s.weekly),   disabled = true },
      }
      -- Codex Spark block, same compact format, gated by the same toggle.
      if pid == "codex" and get("spark_bar", false) and s.additional then
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
      -- Codex per-model windows (e.g. Spark), gated behind a toggle. When on,
      -- each model gets a full block in the SAME format as the main 5h/1w block
      -- above, plus the "S" bar on the icon (see currentBarIcon).
      local hasAdditional = s.additional and #s.additional > 0
      local showSpark = get("spark_bar", false) == true
      if hasAdditional and showSpark then
        for _, a in ipairs(s.additional) do
          table.insert(items, { title = "-" })
          table.insert(items, { title = a.label or "additional", disabled = true })
          if a.fiveHour then
            table.insert(items, { title = "5h window", disabled = true })
            table.insert(items, { title = "    " .. a.fiveHour.percentUsed .. "% used", disabled = true })
            table.insert(items, { title = "    resets in " .. resetStr(a.fiveHour), disabled = true })
          else
            table.insert(items, { title = "5h window: —", disabled = true })
          end
          if a.weekly then
            table.insert(items, { title = "1w window", disabled = true })
            table.insert(items, { title = "    " .. a.weekly.percentUsed .. "% used", disabled = true })
            table.insert(items, { title = "    resets in " .. resetStr(a.weekly), disabled = true })
          else
            table.insert(items, { title = "1w window: —", disabled = true })
          end
        end
      end
      -- Toggle for the whole Spark block (dropdown) + icon "S" bar.
      if pid == "codex" and hasAdditional then
        table.insert(items, { title = "-" })
        table.insert(items, {
          title = "Show Spark limits",
          checked = showSpark,
          fn = function()
            set("spark_bar", not showSpark)
            M.applyAllTitles()
          end,
        })
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
    -- codex_data.lua reads "codex_dump_fetcher"; data.lua reads "dump_fetcher".
    local dumpKey = pid == "codex" and "codex_dump_fetcher" or "dump_fetcher"
    local debugItems = {
      { title = "Open Hammerspoon console", fn = function() hs.openConsole() end },
      { title = "Dump fetcher response to debug/last-fetcher.json",
        checked = get(dumpKey, false) == true,
        fn = function() set(dumpKey, not (get(dumpKey, false) == true)) end },
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
  -- Shared menu callback: the main bar and the Spark companion both open it.
  instance.menuFn = function(mods)
    return buildMenu(mods and (mods.ctrl or mods.alt))
  end
  instance.bar:setMenu(instance.menuFn)

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
