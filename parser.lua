-- Classifier-based parser for claude.ai/settings/usage innerText.
--
-- Strategy: don't rely on exact label strings. Find every "Resets ..." line,
-- pair it with the nearest "N% used" below, tag each pair with category
-- inferred from the *shape* of the reset string (duration / weekday+time /
-- month+date) plus the nearest section heading and $-context.
--
-- parse(innerText) returns:
--   { status, fiveHour, weekly, weeklySonnet, weeklyOpus, weeklyHaiku,
--     spend = {...}, unknown = {...}, triples = {...}, warnings = {...} }

local M = {}

local WEEKDAYS = { sun = 0, mon = 1, tue = 2, wed = 3, thu = 4, fri = 5, sat = 6 }
local MONTHS = {
  jan = 1, feb = 2, mar = 3, apr = 4, may = 5, jun = 6,
  jul = 7, aug = 8, sep = 9, oct = 10, nov = 11, dec = 12,
}

---------------------------------------------------------------------
-- Line model
---------------------------------------------------------------------

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function splitLines(text)
  local lines = {}
  for raw in text:gmatch("[^\n]+") do
    local t = trim(raw)
    if t ~= "" then
      table.insert(lines, {
        text = t,
        lc = t:lower(),
        hasPct = t:match("%d+%s*%%") ~= nil,
        hasDollar = t:match("%$%d") ~= nil,
        hasReset = t:match("^[Rr]esets?%s") ~= nil or t:match("^[Rr]esets?%.?$") ~= nil,
      })
    end
  end
  return lines
end

---------------------------------------------------------------------
-- Shape detectors (public-ish — exposed for debug and unit testing)
---------------------------------------------------------------------

-- "1 hr 22 min", "45 min", "30 sec", "2 days 3 hr", "now"
function M._looksDuration(s)
  if not s then return false end
  if s:lower():match("^now$") then return true end
  local ls = s:lower()
  for _, token in ipairs({ "hr", "hour", "min", "sec", "day" }) do
    if ls:find(token, 1, true) then return true end
  end
  return false
end

-- "Sat 6:00 PM", "Mon 9:00 AM", "Tuesday 14:30"
function M._looksWeekday(s)
  if not s then return false end
  local wd = s:match("^(%a+)%s+%d+:%d+")
  if not wd then return false end
  return WEEKDAYS[wd:sub(1, 3):lower()] ~= nil
end

-- "May 1", "Jan 15", "May 1, 2026"
function M._looksMonthDate(s)
  if not s then return false end
  local mo = s:match("^(%a+)%s+%d+")
  if not mo then return false end
  return MONTHS[mo:sub(1, 3):lower()] ~= nil
end

---------------------------------------------------------------------
-- Shape → epoch conversion
---------------------------------------------------------------------

local function parseDuration(s)
  if not s then return nil end
  if s:lower():match("^now$") then return os.time() end
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
  return matched and (os.time() + secs) or nil
end

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
  local curWd = nowT.wday - 1
  local daysDelta = (target - curWd) % 7
  local cand = os.time({
    year = nowT.year, month = nowT.month, day = nowT.day + daysDelta,
    hour = h, min = m, sec = 0,
  })
  if cand <= now then cand = cand + 7 * 86400 end
  return cand
end

local function parseMonthDate(s)
  if not s then return nil end
  local mo, d, y = s:match("^(%a+)%s+(%d+),?%s*(%d*)")
  if not mo then return nil end
  local month = MONTHS[mo:sub(1, 3):lower()]
  if not month then return nil end
  local day = tonumber(d)
  local year = tonumber(y)
  if not year or year == 0 then
    local now = os.time()
    local t = os.date("*t", now)
    year = t.year
    local cand = os.time({ year = year, month = month, day = day, hour = 0, min = 0, sec = 0 })
    if cand <= now then year = year + 1 end
  end
  return os.time({ year = year, month = month, day = day, hour = 0, min = 0, sec = 0 })
end

function M._toEpoch(resetsHuman)
  if not resetsHuman or resetsHuman == "" then return nil end
  return parseDuration(resetsHuman)
      or parseWeekdayClock(resetsHuman)
      or parseMonthDate(resetsHuman)
end

---------------------------------------------------------------------
-- Triple extraction
---------------------------------------------------------------------

local RESET_LINE_PATTERNS = {
  "^[Rr]esets?%s+[Ii]n%s+(.-)%.?$",
  "^[Rr]esets?%s+[Aa]t%s+(.-)%.?$",
  "^[Rr]esets?%s+(.-)%.?$",
}

local USED_LINE_PATTERNS = {
  "^(%d+)%s*%%%s*used",
  "^(%d+)%s*%%%s*of",
  "(%d+)%s*%%%s*used",   -- anywhere on line, as last resort
}

local function matchReset(line)
  for _, p in ipairs(RESET_LINE_PATTERNS) do
    local m = line:match(p)
    if m and m ~= "" then return trim(m) end
  end
  return nil
end

local function matchUsed(line)
  for _, p in ipairs(USED_LINE_PATTERNS) do
    local n = line:match(p)
    if n then
      local num = tonumber(n)
      if num and num >= 0 and num <= 100 then return num end
    end
  end
  return nil
end

local function nearestUsed(lines, startIdx, forward)
  local window = 10
  if forward then
    for j = startIdx + 1, math.min(startIdx + window, #lines) do
      local u = matchUsed(lines[j].text)
      if u then return u, j end
    end
  else
    for j = startIdx - 1, math.max(startIdx - window, 1), -1 do
      local u = matchUsed(lines[j].text)
      if u then return u, j end
    end
  end
  return nil
end

local function nearestHeading(lines, resetIdx)
  local window = 10
  for j = resetIdx - 1, math.max(resetIdx - window, 1), -1 do
    local l = lines[j]
    if not l.hasReset and not l.hasPct and not l.hasDollar then
      local t = l.text
      if #t >= 2 and #t <= 48 and not t:match(":") then
        return t, j
      end
    end
  end
  return nil
end

local function contextHas(lines, centerIdx, radius, predicate)
  for j = math.max(centerIdx - radius, 1), math.min(centerIdx + radius, #lines) do
    if predicate(lines[j]) then return true end
  end
  return false
end

function M._extractTriples(lines)
  local triples = {}
  for i, line in ipairs(lines) do
    if line.hasReset then
      local resetsHuman = matchReset(line.text)
      if resetsHuman then
        local used, usedIdx = nearestUsed(lines, i, true)
        if not used then used, usedIdx = nearestUsed(lines, i, false) end
        if used then
          local heading = nearestHeading(lines, i)
          local hasSpend = contextHas(lines, i, 5, function(l) return l.hasDollar end)
          table.insert(triples, {
            resetIdx = i,
            resetsHuman = resetsHuman,
            percentUsed = used,
            usedIdx = usedIdx,
            heading = heading,
            hasSpendContext = hasSpend,
          })
        end
      end
    end
  end
  return triples
end

---------------------------------------------------------------------
-- Classification
---------------------------------------------------------------------

local function classifyShape(resetsHuman)
  if M._looksDuration(resetsHuman) then return "duration"
  elseif M._looksWeekday(resetsHuman) then return "weekday"
  elseif M._looksMonthDate(resetsHuman) then return "monthdate"
  else return "unknown"
  end
end

local MODEL_KEYWORDS = {
  { keyword = "sonnet", slot = "weeklySonnet" },
  { keyword = "opus", slot = "weeklyOpus" },
  { keyword = "haiku", slot = "weeklyHaiku" },
}

function M._classify(triple)
  triple.shape = classifyShape(triple.resetsHuman)
  triple.resetsAt = M._toEpoch(triple.resetsHuman)
  local heading = (triple.heading or ""):lower()

  if triple.hasSpendContext or triple.shape == "monthdate" then
    return { slot = "spend" }
  end
  if triple.shape == "duration" then
    return { slot = "fiveHour" }
  end
  if triple.shape == "weekday" then
    for _, mk in ipairs(MODEL_KEYWORDS) do
      if heading:find(mk.keyword, 1, true) then return { slot = mk.slot } end
    end
    return { slot = "weekly" }
  end
  return { slot = "unknown" }
end

---------------------------------------------------------------------
-- Top-level
---------------------------------------------------------------------

local function tripleToWindow(t)
  return {
    percentUsed = t.percentUsed,
    percentLeft = math.max(0, 100 - t.percentUsed),
    resetsHuman = t.resetsHuman,
    resetsAt = t.resetsAt,
    heading = t.heading,
  }
end

function M.parse(innerText)
  innerText = innerText or ""
  local lines = splitLines(innerText)
  local triples = M._extractTriples(lines)

  local result = {
    status = "ok",
    triples = triples,
    unknown = {},
    spend = {},
    warnings = {},
    raw = innerText,
  }
  local seenSlots = {}

  for _, t in ipairs(triples) do
    local c = M._classify(t)
    t._slot = c.slot
    if c.slot == "unknown" then
      table.insert(result.unknown, t)
    elseif c.slot == "spend" then
      table.insert(result.spend, tripleToWindow(t))
    else
      if seenSlots[c.slot] then
        table.insert(result.warnings,
          ("duplicate %s block; keeping first (heading=%q reset=%q)"):format(
            c.slot, t.heading or "?", t.resetsHuman))
      else
        result[c.slot] = tripleToWindow(t)
        seenSlots[c.slot] = true
      end
    end
  end

  -- Hard requirements
  if not result.fiveHour then
    result.status = "error"
    result.errorMsg = "parser drift: no duration-reset (session) block found on page"
    return result
  end
  if not result.weekly then
    result.status = "error"
    result.errorMsg = "parser drift: no weekday-reset (weekly) block found on page"
    return result
  end

  -- Soft warnings
  if #result.unknown > 0 then
    for _, t in ipairs(result.unknown) do
      table.insert(result.warnings,
        ("unclassified reset block: heading=%q reset=%q used=%d%%"):format(
          t.heading or "?", t.resetsHuman, t.percentUsed))
    end
  end
  if result.fiveHour.resetsAt == nil then
    table.insert(result.warnings,
      "5h reset string unparseable: '" .. result.fiveHour.resetsHuman .. "'")
  end
  if result.weekly.resetsAt == nil then
    table.insert(result.warnings,
      "weekly reset string unparseable: '" .. result.weekly.resetsHuman .. "'")
  end

  -- Landmark checks (degraded when landmarks vanish — Anthropic redesign)
  if not innerText:find("Plan usage limits", 1, true) then
    table.insert(result.warnings, "landmark 'Plan usage limits' not found")
  end
  if not innerText:find("Weekly limits", 1, true) then
    table.insert(result.warnings, "landmark 'Weekly limits' not found")
  end

  return result
end

-- Convenience: strip HTML tags for replay on .html files.
function M.stripHtml(html)
  return html:gsub("<script.->.-</script>", " ")
             :gsub("<style.->.-</style>", " ")
             :gsub("<br%s*/?>", "\n")
             :gsub("</p>", "\n")
             :gsub("</div>", "\n")
             :gsub("</li>", "\n")
             :gsub("<[^>]*>", " ")
             :gsub("&nbsp;", " ")
end

return M
