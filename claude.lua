-- claude.ai provider: session cookie → three JSON endpoints.
--
--   GET /api/account
--       → { email_address, full_name, memberships:[{organization:{uuid,name}}] }
--   GET /api/organizations/{orgUuid}/usage
--       → { five_hour, seven_day, seven_day_sonnet, seven_day_opus, seven_day_haiku, .. }
--   GET /api/organizations/{orgUuid}/overage_spend_limit
--       → { is_enabled, monthly_credit_limit, used_credits, currency }
--
-- Auth is the `sessionKey` cookie (30-day, not extended by any request the
-- SPA or we make; re-login monthly is inherent to claude.ai).
local PREFIX = ((...) or "claude_usage"):gsub("%.[^.]+$", "")
local session = require(PREFIX .. ".session")

local M = {
  id = "claude",
  label = "claude",
  loginLabel = "claude.ai",
  openSettingsLabel = "claude.ai/settings/usage",
  openSettingsUrl = "https://claude.ai/settings/usage",
  hasExtraUsage = true,
  domain = "claude.ai",
  cookiePrefix = "sessionKey",
}

local LOGIN_PATHS  = { "login", "logout", "auth", "sign%-in", "signin" }
local AUTHED_PATHS = { "settings", "new", "chat", "recents", "home" }
local function pathMatchesAny(u, paths)
  for _, p in ipairs(paths) do
    if u:match("/" .. p .. "[%?/]") or u:match("/" .. p .. "$") then return true end
  end
  return false
end

M.login = {
  title = "Log in to claude.ai",
  -- /settings/usage forces a /logout → /login redirect chain that races the
  -- provisional nav (NSURLError -999); start at /login directly.
  startUrl = "https://claude.ai/login",
  isAuthedUrl = function(u)
    if type(u) ~= "string" or not u:match("claude%.ai/") then return false end
    if pathMatchesAny(u, LOGIN_PATHS) then return false end
    return pathMatchesAny(u, AUTHED_PATHS)
  end,
  -- authed → 200 '[...]'; unauthed → '{"type":"error",..account_session_invalid..}'
  probeUrl = "https://claude.ai/api/organizations",
  probeIsAuthed = function(body)
    return body:sub(1, 1) == "[" and not body:match("account_session_invalid")
  end,
}

-- The SPA remembers the user's last-used org in a plain cookie; adopt it so
-- multi-org accounts report the org the user actually works in.
function M.afterLogin(acct, domainCookies)
  local c = domainCookies and domainCookies.lastActiveOrg
  if c then acct.orgUuid = c.value end
end

---------------------------------------------------------------------
-- Response shape transforms
---------------------------------------------------------------------

local function utcOffset()
  local now = os.time()
  return os.difftime(now, os.time(os.date("!*t", now)))
end

local function isoToEpoch(iso)
  if type(iso) ~= "string" then return nil end
  local y, mo, d, h, mi, s = iso:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then return nil end
  return os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d),
                   hour = tonumber(h), min = tonumber(mi), sec = tonumber(s) }) + utcOffset()
end

-- hs.json.decode yields 18.0 for "18.0"; show integers as integers.
local function pct(n) return math.tointeger(n) or n end

local function makeWindow(d)
  if not d or type(d.utilization) ~= "number" then return nil end
  local u = pct(d.utilization)
  return {
    percentUsed = u,
    percentLeft = math.max(0, 100 - u),
    resetsAt    = isoToEpoch(d.resets_at),
  }
end

local function mapOverage(raw)
  if type(raw) ~= "table" then return nil end
  local cents = tonumber(raw.monthly_credit_limit)
  local used  = tonumber(raw.used_credits)
  return {
    isEnabled    = raw.is_enabled == true,
    monthlyLimit = cents and (cents / 100) or nil,
    usedCredits  = used and (used / 100) or nil,
    utilization  = (cents and cents > 0 and used) and math.floor(used / cents * 100 + 0.5) or nil,
    currency     = raw.currency or "USD",
  }
end

local function mapResponse(usage, overage, account)
  if type(usage) ~= "table" then
    return { status = "error", errorMsg = "usage response missing or not an object",
             warnings = { "/api/organizations/{uuid}/usage did not return an object" } }
  end
  local five, weekly = makeWindow(usage.five_hour), makeWindow(usage.seven_day)
  if not five or not weekly then
    return { status = "error", errorMsg = "missing five_hour/seven_day fields",
             warnings = { "API shape changed — expected five_hour.utilization and seven_day.utilization" } }
  end
  return {
    status       = "ok",
    fiveHour     = five,
    weekly       = weekly,
    weeklySonnet = makeWindow(usage.seven_day_sonnet),
    weeklyOpus   = makeWindow(usage.seven_day_opus),
    weeklyHaiku  = makeWindow(usage.seven_day_haiku),
    account      = account,
    extraUsage   = mapOverage(overage),
    warnings     = {},
    raw          = { usage = usage, overage = overage },
  }
end

---------------------------------------------------------------------
-- Fetch
---------------------------------------------------------------------

local function orgBase(uuid) return "https://claude.ai/api/organizations/" .. uuid end

-- cb(parsed). parsed.status ∈ ok | needs_login | error.
function M.fetch(acct, cb)
  if not acct.cookie then return cb({ status = "needs_login" }) end
  session.get("https://claude.ai/api/account", acct.cookie, nil, function(st, body)
    if st ~= 200 then return cb(session.failure("/api/account", st, body)) end
    local account = session.json(body) or {}
    local ms, org = account.memberships or {}, nil
    for _, m in ipairs(ms) do
      if m.organization and m.organization.uuid == acct.orgUuid then org = m.organization end
    end
    org = org or (ms[1] and ms[1].organization)
    if not org then
      return cb({ status = "error", errorMsg = "no organization on account",
                  warnings = { "/api/account returned no memberships" } })
    end
    local info = { email = account.email_address, fullName = account.full_name,
                   orgUuid = org.uuid, orgName = org.name }
    local usage, overage, pending = nil, nil, 2
    local function done()
      pending = pending - 1
      if pending == 0 then cb(mapResponse(usage, overage, info)) end
    end
    session.get(orgBase(org.uuid) .. "/usage", acct.cookie, nil, function(s, b)
      usage = s == 200 and session.json(b) or nil; done()
    end)
    session.get(orgBase(org.uuid) .. "/overage_spend_limit", acct.cookie, nil, function(s, b)
      overage = s == 200 and session.json(b) or nil; done()
    end)
  end)
end

-- Flip Extra usage. cb(ok, message)
function M.toggleExtraUsage(acct, s, cb)
  local orgUuid = s.account and s.account.orgUuid
  if not orgUuid then return cb(false, "no orgUuid yet - refresh first") end
  local desired = not (s.extraUsage and s.extraUsage.isEnabled)
  session.request("PUT", orgBase(orgUuid) .. "/overage_spend_limit", acct.cookie,
    { ["Content-Type"] = "application/json" },
    hs.json.encode({ is_enabled = desired }),
    function(st, body)
      local r = session.json(body)
      local ok = st == 200 and r and r.is_enabled == desired
      cb(ok, ok and ("Extra usage " .. (desired and "on" or "off"))
              or ("Extra usage toggle failed (HTTP " .. st .. ")"))
    end)
end

-- POST /api/auth/logout is the SPA's real logout mutation (GET /logout is a
-- client-side route). cb() always; the stored cookie is dropped regardless.
function M.logout(acct, cb)
  if not acct.cookie then return cb() end
  session.request("POST", "https://claude.ai/api/auth/logout", acct.cookie,
    { ["Content-Type"] = "application/json" }, "{}", function() cb() end)
end

return M
