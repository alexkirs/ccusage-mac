-- Grok Bot provider: the weekly Grok Bot allowance is metered on the
-- user's Cursor account (Grok Bot is Cursor's "sand" product under the
-- xAI brand), not on grok.com. cursor.com's dashboard exposes it through a
-- cookie-authenticated proxy of the Connect RPC:
--
--   POST https://cursor.com/api/dashboard/get-sand-usage-status  body {}
--     headers: Origin: https://cursor.com (CSRF check), Cookie: WorkosCursorSessionToken=…
--     → aiserver.v1.GetSandUsageStatusResponse as JSON:
--       { usagePercent, currentPeriodStart, nextResetTimestampUtc, hasNonZeroIncludedLimit,
--         includedUsageSuperGrokPlan?, grokPlanLabel?, usesPooledEnterpriseAllowance, .. }
--
-- Login: cursor.com/dashboard (WorkOS). Use the same identity the Grok Bot
-- app linked; usage lives on that Cursor account.
local PREFIX = ((...) or "claude_usage"):gsub("%.[^.]+$", "")
local session = require(PREFIX .. ".session")

local M = {
  id = "grokbot",
  label = "grokb",
  loginLabel = "cursor.com (Grok Bot)",
  openSettingsLabel = "cursor.com/dashboard/usage",
  openSettingsUrl = "https://cursor.com/dashboard/usage",
  hasExtraUsage = false,
  domain = "cursor.com",
  cookiePrefix = "WorkosCursorSessionToken",
  wipeDomains = { "cursor.com", "authenticator.cursor.sh" },
}

M.login = {
  title = "Log in to cursor.com (Grok Bot usage)",
  startUrl = "https://cursor.com/dashboard",
  isAuthedUrl = function(u)
    return type(u) == "string" and u:match("^https://cursor%.com/dashboard") ~= nil
  end,
  probeUrl = nil,  -- cookie landing in the jar is the detector
}

local USAGE_URL = "https://cursor.com/api/dashboard/get-sand-usage-status"
local HEADERS = { ["Content-Type"] = "application/json", Origin = "https://cursor.com",
                  Referer = "https://cursor.com/dashboard/usage" }

local function pct(n) return math.tointeger(n) or n end

-- Connect-JSON timestamps arrive as RFC3339 strings; be lenient about
-- {seconds} objects and bare numbers too.
local function toEpoch(v)
  if type(v) == "number" then return math.floor(v) end
  if type(v) == "table" then return tonumber(v.seconds) end
  if type(v) ~= "string" then return nil end
  local y, mo, d, h, mi, s = v:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then return nil end
  local utc = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d),
                        hour = tonumber(h), min = tonumber(mi), sec = tonumber(s) })
  return utc + os.difftime(os.time(), os.time(os.date("!*t", os.time())))
end

local function field(t, camel, snake) local v = t[camel]; if v == nil then v = t[snake] end; return v end

function M.mapResponse(r)
  if type(r) ~= "table" then
    return { status = "error", errorMsg = "grokbot: response not an object",
             warnings = { "get-sand-usage-status did not return JSON" } }
  end
  local usage = tonumber(field(r, "usagePercent", "usage_percent"))
  if usage == nil then
    return { status = "error", errorMsg = "grokbot: usagePercent missing",
             warnings = { "Grok Bot usage not reported (pooled enterprise allowance or no plan?)" },
             raw = r }
  end
  local used = pct(math.floor(math.max(usage, 0) + 0.5))
  local plan = field(r, "grokPlanLabel", "grok_plan_label")
  return {
    status   = "ok",
    fiveHour = nil,
    weekly   = { percentUsed = used, percentLeft = pct(100 - used),
                 resetsAt = toEpoch(field(r, "nextResetTimestampUtc", "next_reset_timestamp_utc")),
                 startsAt = toEpoch(field(r, "currentPeriodStart", "current_period_start")) },
    additional = {},
    account  = { email = "cursor.com", orgName = plan and ("Grok Bot · " .. tostring(plan)) or "Grok Bot" },
    warnings = {},
    raw      = r,
  }
end

function M.fetch(acct, cb)
  if not acct.cookie then return cb({ status = "needs_login" }) end
  session.request("POST", USAGE_URL, acct.cookie, HEADERS, "{}", function(st, body)
    if st ~= 200 then return cb(session.failure("get-sand-usage-status", st, body)) end
    local j = session.json(body)
    -- cursor.com serves the login HTML with 200 when the session is gone.
    if not j then return cb({ status = "needs_login" }) end
    cb(M.mapResponse(j))
  end)
end

function M.logout(acct, cb) cb() end

return M
