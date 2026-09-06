-- grok.com provider: `sso` cookies → POST /rest/rate-limits.
--
--   POST /rest/rate-limits  body {"requestKind":"DEFAULT","modelName":"<model>"}
--     → { remainingQueries, totalQueries, windowSizeSeconds, waitTimeSeconds?,
--         highEffortRateLimits?:{..same..}, lowEffortRateLimits?:{..same..} }
--
-- The model list on grok.com churns; we try candidates until one answers 200
-- and keep the raw body so the mapping can be corrected from a real dump.
-- ponytail: model candidates are a guess list; fix from Debug → Copy state JSON.
local PREFIX = ((...) or "claude_usage"):gsub("%.[^.]+$", "")
local session = require(PREFIX .. ".session")

local M = {
  id = "grok",
  label = "grok",
  loginLabel = "grok.com",
  openSettingsLabel = "grok.com",
  openSettingsUrl = "https://grok.com/",
  hasExtraUsage = false,
  domain = "grok.com",
  cookiePrefix = "sso",          -- matches `sso` and `sso-rw`
  -- Sign-in bounces through accounts.x.ai; wipe it too so a second account
  -- gets a real login form instead of the SSO auto-signin.
  wipeDomains = { "grok.com", "accounts.x.ai", "x.ai" },
}

M.login = {
  title = "Log in to grok.com",
  startUrl = "https://grok.com/",
  isAuthedUrl = function() return false end,
  -- No GET endpoint known that says "authed"; login.lua falls back to the
  -- sso cookie landing in the jar, or the user closing the window.
  probeUrl = nil,
}

local MODELS = { "grok-4-auto", "grok-420", "grok-4", "grok-3" }
local REQUEST_KIND = "DEFAULT"

local function pct(n) return math.tointeger(n) or n end

-- One rate-limit object → window. remaining/total → % used; reset is
-- "wait" seconds from now (falls back to the window size).
local function makeWindow(r)
  if type(r) ~= "table" or type(r.remainingQueries) ~= "number" then return nil end
  local total = r.totalQueries or r.maxQueries or r.limit
  if type(total) ~= "number" or total <= 0 then return nil end
  local used = math.floor((total - r.remainingQueries) / total * 100 + 0.5)
  local wait = r.waitTimeSeconds or r.resetAfterSeconds or r.windowSizeSeconds
  return {
    percentUsed = pct(used),
    percentLeft = pct(100 - used),
    resetsAt    = type(wait) == "number" and (os.time() + wait) or nil,
    windowSecs  = r.windowSizeSeconds,
    remaining   = r.remainingQueries,
    total       = total,
  }
end

-- Short windows (≤6h) go to the 5h slot, longer ones to weekly.
local function slot(win)
  if not win then return nil, nil end
  local secs = win.windowSecs
  if secs and secs > 6 * 3600 then return nil, win end
  return win, nil
end

local function mapResponse(model, body)
  local main = makeWindow(body.highEffortRateLimits) or makeWindow(body)
  if not main then
    return { status = "error", errorMsg = "grok: no remainingQueries/totalQueries in response",
             warnings = { "/rest/rate-limits shape unknown — Debug → Copy state JSON and inspect raw" },
             raw = { model = model, rateLimits = body } }
  end
  local fiveHour, weekly = slot(main)
  local additional = {}
  local low = makeWindow(body.lowEffortRateLimits)
  if low then
    local l5, lw = slot(low)
    additional[1] = { label = model .. " · low effort", fiveHour = l5, weekly = lw }
  end
  return {
    status     = "ok",
    fiveHour   = fiveHour,
    weekly     = weekly,
    additional = additional,
    account    = { email = "grok.com", orgName = model },  -- API exposes no email here
    warnings   = {},
    raw        = { model = model, rateLimits = body },
  }
end

function M.fetch(acct, cb)
  if not acct.cookie then return cb({ status = "needs_login" }) end
  local tried = {}
  local function try(i)
    local model = MODELS[i]
    if not model then
      return cb({ status = "error", errorMsg = "grok: no model answered /rest/rate-limits",
                  warnings = tried })
    end
    session.request("POST", "https://grok.com/rest/rate-limits", acct.cookie,
      { ["Content-Type"] = "application/json" },
      hs.json.encode({ requestKind = REQUEST_KIND, modelName = model }),
      function(st, body)
        local j = session.json(body)
        if st == 200 and j then return cb(mapResponse(model, j)) end
        if st == 401 or (st == 403 and j) then return cb({ status = "needs_login" }) end
        tried[#tried + 1] = model .. " → HTTP " .. st .. " " .. body:sub(1, 80):gsub("%s+", " ")
        try(i + 1)
      end)
  end
  try(1)
end

function M.logout(acct, cb) cb() end

return M
