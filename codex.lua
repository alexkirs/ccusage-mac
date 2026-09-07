-- chatgpt.com (Codex) provider: NextAuth session cookie → JWT → usage.
--
--   GET /api/auth/session            (cookie auth)  → { accessToken, user, .. }
--   GET /backend-api/wham/usage      (Bearer JWT)   →
--     { email, plan_type,
--       rate_limit:{ primary_window:{used_percent,limit_window_seconds,reset_at}, secondary_window|null },
--       additional_rate_limits:[{ limit_name, rate_limit:{..} }] }
--
-- Windows are classified by limit_window_seconds (≤6h → 5h slot, else
-- weekly), not by position: since 2026-07 primary_window carries the weekly
-- limit and secondary_window is null.
--
-- NextAuth rotates the session-token chunks via Set-Cookie on /api/auth/session;
-- fetch returns them as parsed.newCookie so the account gets updated.
local PREFIX = ((...) or "claude_usage"):gsub("%.[^.]+$", "")
local session = require(PREFIX .. ".session")

local TARGET_URL = "https://chatgpt.com/codex/cloud/settings/analytics"

local M = {
  id = "codex",
  label = "codex",
  loginLabel = "chatgpt.com",
  openSettingsLabel = "chatgpt.com/codex/cloud/settings/analytics",
  openSettingsUrl = TARGET_URL .. "#usage",
  hasExtraUsage = false,
  domain = "chatgpt.com",
  cookiePrefix = "__Secure-next-auth.session-token",
  -- auth.openai.com keeps its own session; left alone, a second login just
  -- pre-fills the first account's email.
  wipeDomains = { "chatgpt.com", "auth.openai.com", "openai.com" },
}

M.login = {
  title = "Log in to chatgpt.com (Codex)",
  startUrl = "https://chatgpt.com/",
  -- chatgpt.com keeps the login dialog overlaid on / so the URL never says
  -- "authed"; the probe does the detection.
  isAuthedUrl = function() return false end,
  probeUrl = "https://chatgpt.com/api/auth/session",
  probeIsAuthed = function(body) return body:match('"accessToken"%s*:%s*"') ~= nil end,
}

---------------------------------------------------------------------
-- Response shape transforms
---------------------------------------------------------------------

local function pct(n) return math.tointeger(n) or n end

local function makeWindow(w)
  if not w or type(w.used_percent) ~= "number" then return nil end
  local u = pct(w.used_percent)
  return {
    percentUsed = u,
    percentLeft = math.max(0, 100 - u),
    resetsAt    = w.reset_at,  -- already epoch seconds
  }
end

local function splitWindows(rl)
  local fiveHour, weekly
  for i, raw in ipairs({ rl.primary_window or false, rl.secondary_window or false }) do
    local win = raw and makeWindow(raw) or nil
    if win then
      local secs = raw.limit_window_seconds
      local isShort = secs and secs <= 6 * 3600 or (not secs and i == 1)
      if isShort and not fiveHour then fiveHour = win
      elseif not weekly then weekly = win
      elseif not fiveHour then fiveHour = win end
    end
  end
  return fiveHour, weekly
end

local function mapResponse(u)
  if type(u) ~= "table" then
    return { status = "error", errorMsg = "usage response missing or not an object",
             warnings = { "/backend-api/wham/usage did not return an object" } }
  end
  local rl = u.rate_limit
  if type(rl) ~= "table" then
    return { status = "error", errorMsg = "rate_limit field missing",
             warnings = { "API shape changed - rate_limit missing on /backend-api/wham/usage" } }
  end
  local fiveHour, weekly = splitWindows(rl)
  if not fiveHour and not weekly then
    return { status = "error", errorMsg = "no usable rate-limit window",
             warnings = { "API shape changed - expected used_percent in primary_window or secondary_window" } }
  end
  local additional = {}
  for _, arl in ipairs(type(u.additional_rate_limits) == "table" and u.additional_rate_limits or {}) do
    if type(arl.rate_limit) == "table" then
      local afh, awk = splitWindows(arl.rate_limit)
      additional[#additional + 1] = { label = arl.limit_name or "additional", fiveHour = afh, weekly = awk }
    end
  end
  return {
    status     = "ok",
    fiveHour   = fiveHour,
    weekly     = weekly,
    additional = additional,
    account    = { email = u.email, orgName = u.plan_type and ("Plan: " .. u.plan_type) or nil },
    warnings   = {},
    raw        = { usage = u },
  }
end

---------------------------------------------------------------------
-- Fetch
---------------------------------------------------------------------

function M.fetch(acct, cb)
  if not acct.cookie then return cb({ status = "needs_login" }) end
  session.get("https://chatgpt.com/api/auth/session", acct.cookie, nil, function(st, body, headers)
    if st ~= 200 then return cb(session.failure("/api/auth/session", st, body)) end
    local sess = session.json(body)
    if not (sess and sess.accessToken) then return cb({ status = "needs_login" }) end
    local rotated = session.setCookies(headers, M.cookiePrefix)
    session.get("https://chatgpt.com/backend-api/wham/usage", acct.cookie,
      { Authorization = "Bearer " .. sess.accessToken }, function(s2, b2)
        if s2 ~= 200 then return cb(session.failure("/backend-api/wham/usage", s2, b2)) end
        local parsed = mapResponse(session.json(b2))
        if rotated then parsed.newCookie = session.mergeCookie(acct.cookie, rotated) end
        cb(parsed)
      end)
  end)
end

-- Server-side logout endpoint was never confirmed; dropping the stored
-- cookie is what actually signs the widget out. Best-effort POST anyway.
function M.logout(acct, cb)
  if not acct.cookie then return cb() end
  session.request("POST", "https://chatgpt.com/api/auth/signout", acct.cookie,
    { ["Content-Type"] = "application/json" }, "{}", function() cb() end)
end

return M
