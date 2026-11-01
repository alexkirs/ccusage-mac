-- Google (Gemini / Antigravity) provider via Google OAuth 2.0 + Cloud Code PA.
--
-- Like codex.lua, each account owns an isolated auth directory under
-- ~/.hammerspoon/claude_usage_auth/gemini/<acct.id> containing auth.json with
-- its own OAuth token chain (access_token + refresh_token). Multiple Google
-- accounts coexist independently of whatever the browser or IDE is signed into.
--
-- Endpoints (https://cloudcode-pa.googleapis.com):
--   POST /v1internal:loadCodeAssist           -> tier + cloudaicompanionProject
--   POST /v1internal:retrieveUserQuotaSummary -> grouped model quota windows
--   POST /v1internal:retrieveUserQuota        -> per-model quota buckets (fallback)
local PREFIX = ((...) or "claude_usage"):gsub("%.[^.]+$", "")
local session = require(PREFIX .. ".session")
local state = require(PREFIX .. ".state")
local log = state.logger("gemini")

local AUTH_URL        = "https://accounts.google.com/o/oauth2/v2/auth"
local TOKEN_URL       = "https://oauth2.googleapis.com/token"
local REVOKE_URL      = "https://oauth2.googleapis.com/revoke"
local USERINFO_URL    = "https://www.googleapis.com/oauth2/v2/userinfo"
local DAILY_API_BASE  = "https://daily-cloudcode-pa.googleapis.com"
local PROD_API_BASE   = "https://cloudcode-pa.googleapis.com"
local AICODE_API_BASE = "https://aicode.googleapis.com"
local AUTH_BASE       = os.getenv("HOME") .. "/.hammerspoon/claude_usage_auth/gemini"

local function clientCreds()
  local cid = state.get("gemini.client_id") or os.getenv("GEMINI_OAUTH_CLIENT_ID")
  local csec = state.get("gemini.client_secret") or os.getenv("GEMINI_OAUTH_CLIENT_SECRET")
  if cid and csec then return cid, csec end
  local fh = io.open(AUTH_BASE .. "/client.json", "r")
  if fh then
    local j = session.json(fh:read("a"))
    fh:close()
    if j and j.client_id and j.client_secret then return j.client_id, j.client_secret end
  end
  return cid, csec
end

local SCOPES = table.concat({
  "https://www.googleapis.com/auth/cloud-platform",
  "https://www.googleapis.com/auth/userinfo.email",
  "https://www.googleapis.com/auth/userinfo.profile",
  "https://www.googleapis.com/auth/cclog",
  "https://www.googleapis.com/auth/experimentsandconfigs",
  "https://www.googleapis.com/auth/aicode",
}, " ")

local M = {
  id = "gemini",
  label = "gemini",
  loginLabel = "Google (Gemini)",
  openSettingsLabel = "antigravity.google",
  openSettingsUrl = "https://antigravity.google/",
  hasExtraUsage = false,
  cliAuth = true,   -- menubar uses M.customLogin instead of the cookie webview flow
}

function M.homeFor(acct) return acct.codexHome or (AUTH_BASE .. "/" .. acct.id) end

---------------------------------------------------------------------
-- URL / base64url / JWT helpers
---------------------------------------------------------------------

local function urlEncode(s)
  return (tostring(s):gsub("[^%w%-_%.~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

local function urlDecode(s)
  return (tostring(s):gsub("+", " "):gsub("%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end))
end

local function encodeForm(tbl)
  local keys = {}
  for k in pairs(tbl) do keys[#keys + 1] = k end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    parts[#parts + 1] = urlEncode(k) .. "=" .. urlEncode(tbl[k])
  end
  return table.concat(parts, "&")
end

local function parseQuery(path)
  local q = {}
  local qs = type(path) == "string" and path:match("%?(.*)$") or nil
  if not qs then return q end
  for pair in qs:gmatch("[^&]+") do
    local k, v = pair:match("^([^=]+)=?(.*)$")
    if k then q[urlDecode(k)] = urlDecode(v or "") end
  end
  return q
end

local function base64url(bytes)
  return (hs.base64.encode(bytes):gsub("+", "-"):gsub("/", "_"):gsub("=+$", ""))
end

local function randomUrlSafe(nBytes)
  local fh = io.open("/dev/urandom", "rb")
  if fh then
    local b = fh:read(nBytes or 32)
    fh:close()
    if b and #b > 0 then return base64url(b) end
  end
  local t = {}
  for i = 1, (nBytes or 32) do t[i] = string.char(math.random(0, 255)) end
  return base64url(table.concat(t))
end

local function jwtClaims(tok)
  local payload = type(tok) == "string" and tok:match("^[^.]+%.([^.]+)%.")
  if not payload then return nil end
  payload = payload:gsub("-", "+"):gsub("_", "/")
  local pad = #payload % 4; if pad > 0 then payload = payload .. string.rep("=", 4 - pad) end
  return session.json(hs.base64.decode(payload) or "")
end

local function jwtExp(tok)
  local c = jwtClaims(tok)
  return c and tonumber(c.exp) or nil
end

---------------------------------------------------------------------
-- auth.json + token refresh
---------------------------------------------------------------------

local function readAuth(home)
  local fh = io.open(home .. "/auth.json", "r"); if not fh then return nil end
  local b = fh:read("a"); fh:close()
  return session.json(b)
end

local function writeAuth(home, auth)
  os.execute("mkdir -p '" .. home .. "'")
  local fh = io.open(home .. "/auth.json", "w")
  if not fh then return false end
  fh:write(hs.json.encode(auth))
  fh:close()
  return true
end

-- True when the token set is older than a day or the access token is within
-- 5 minutes of expiry.
function M.needsRefresh(mtime, exp, now)
  if mtime and now - mtime > 86400 then return true end
  return exp ~= nil and exp - now < 300
end

local lastFail = {}   -- home -> time of the last rejected refresh
local inFlight = {}   -- home -> callbacks waiting on the refresh in progress

function M.refreshToken(acct, cb)
  local home = M.homeFor(acct)
  if inFlight[home] then table.insert(inFlight[home], cb); return end
  if lastFail[home] and os.time() - lastFail[home] < 300 then return cb(false) end
  local auth = readAuth(home)
  local tokens = auth and (auth.tokens or auth)
  local rt = tokens and tokens.refresh_token
  if not rt then return cb(false) end
  local cid, csec = clientCreds()
  if not (cid and csec) then return cb(false) end
  inFlight[home] = { cb }
  local function done(ok)
    local cbs = inFlight[home]; inFlight[home] = nil
    for _, f in ipairs(cbs) do f(ok) end
  end
  local body = encodeForm({
    client_id = cid,
    client_secret = csec,
    grant_type = "refresh_token",
    refresh_token = rt,
  })
  session.request("POST", TOKEN_URL, nil, {
    ["Content-Type"] = "application/x-www-form-urlencoded",
  }, body, function(st, b)
    local j = session.json(b or "")
    if st ~= 200 or not (j and j.access_token) then
      if st == 400 or st == 401 then lastFail[home] = os.time() end
      log.w("refresh failed st=" .. tostring(st) .. " " .. tostring(b))
      return done(false)
    end
    lastFail[home] = nil
    auth.tokens = auth.tokens or {}
    auth.tokens.access_token = j.access_token
    auth.tokens.expires_at = os.time() + (tonumber(j.expires_in) or 3600)
    if j.scope then auth.tokens.scope = j.scope end
    if j.refresh_token then auth.tokens.refresh_token = j.refresh_token end
    if j.id_token then
      auth.tokens.id_token = j.id_token
      local claims = jwtClaims(j.id_token)
      if claims and claims.email then auth.email = claims.email end
    end
    auth.last_refresh = os.date("!%Y-%m-%dT%H:%M:%S.000000Z")
    writeAuth(home, auth)
    done(true)
  end)
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

local function pct(n) return math.tointeger(n) or n end

-- Converts a Cloud Code quota bucket into a { percentUsed, percentLeft, resetsAt } window.
-- Note: proto3 JSON omits remainingFraction when it equals 0.0 (exhausted), so a
-- bucket with resetTime (or disabled=true / remainingAmount=0) and nil
-- remainingFraction is 100% used.
local function bucketToWindow(b)
  if type(b) ~= "table" then return nil end
  local rf = tonumber(b.remainingFraction)
  local resetsAt = isoToEpoch(b.resetTime)
  if rf == nil then
    local remAmt = b.remainingAmount and tonumber(b.remainingAmount)
    if remAmt == 0 or b.disabled == true or resetsAt ~= nil then
      rf = 0
    else
      return nil
    end
  end
  rf = math.max(0, math.min(1, rf))
  local used = pct(math.floor((1 - rf) * 100 + 0.5))
  return {
    percentUsed = used,
    percentLeft = math.max(0, 100 - used),
    resetsAt    = resetsAt,
  }
end

-- Classifies a bucket as "weekly" (long window, >12h) or "fiveHour" (short window).
local function bucketSlot(b, resetsAt, now)
  local w = type(b) == "table" and (b.window or b.displayName or b.bucketId or ""):lower() or ""
  if w:match("%d+%s*[dw]") or w:find("week", 1, true) or w:find("day", 1, true) or w:find("month", 1, true) then
    return "weekly"
  end
  local hrs = w:match("(%d+)%s*h")
  if hrs then
    return tonumber(hrs) > 12 and "weekly" or "fiveHour"
  end
  if w:match("%d+%s*m") then return "fiveHour" end
  if resetsAt and now and (resetsAt - now) > 12 * 3600 then
    return "weekly"
  end
  return "fiveHour"
end

-- Picks the tighter of two windows for the same slot (higher percentUsed, or
-- earlier resetsAt on a tie).
local function tighterWindow(a, b)
  if not a then return b end
  if not b then return a end
  local ua, ub = a.percentUsed or 0, b.percentUsed or 0
  if ub > ua then return b end
  if ub < ua then return a end
  if b.resetsAt and (not a.resetsAt or b.resetsAt < a.resetsAt) then return b end
  return a
end

-- Splits a list of buckets for one group/model into fiveHour and weekly windows.
local function windowsFromBuckets(buckets, now)
  local fiveHour, weekly
  for _, b in ipairs(type(buckets) == "table" and buckets or {}) do
    local win = bucketToWindow(b)
    if win then
      local slot = bucketSlot(b, win.resetsAt, now)
      if slot == "weekly" then
        weekly = tighterWindow(weekly, win)
      else
        fiveHour = tighterWindow(fiveHour, win)
      end
    end
  end
  return fiveHour, weekly
end

-- Friendly model group name for raw modelId values in retrieveUserQuota.
local function friendlyModelLabel(modelId)
  if type(modelId) ~= "string" or modelId == "" then return "Gemini" end
  local m = modelId:lower()
  if m:match("^chat_%d+$") or m:match("^tab_") then return nil end
  local ver, tier = m:match("^gemini%-([%d%.]+)%-(pro)")
  if not ver then ver, tier = m:match("^gemini%-([%d%.]+)%-(flash%-lite)") end
  if not ver then ver, tier = m:match("^gemini%-([%d%.]+)%-(flash)") end
  if ver and tier then
    local tName = tier == "pro" and "Pro" or (tier == "flash-lite" and "Flash Lite" or "Flash")
    return "Gemini " .. ver .. " " .. tName
  end
  if m:find("gemini", 1, true) and m:find("pro", 1, true) then return "Gemini Pro" end
  if m:find("gemini", 1, true) and m:find("flash", 1, true) then return "Gemini Flash" end
  local cFamily, cVer = m:match("^claude%-(%a+)%-([%d%-]+)")
  if cFamily then
    local cleanVer = cVer:gsub("%-thinking$", ""):gsub("%-", ".")
    return "Claude " .. cFamily:gsub("^%l", string.upper) .. " " .. cleanVer
  end
  if m:find("claude", 1, true) then return "Claude" end
  if m:find("gpt", 1, true) then return "GPT-OSS" end
  return modelId
end

local function extractGroups(summary, quota, models, now)
  local groups = {}

  -- 1. Primary source: retrieveUserQuotaSummary.groups
  if type(summary) == "table" and type(summary.groups) == "table" and #summary.groups > 0 then
    for _, g in ipairs(summary.groups) do
      local fh, wk = windowsFromBuckets(g.buckets, now)
      if fh or wk then
        groups[#groups + 1] = {
          label = g.displayName or g.description or "Gemini",
          fiveHour = fh,
          weekly = wk,
        }
      end
    end
  end

  -- 2. Fallback: retrieveUserQuota.buckets (or summary.buckets if groups was empty)
  local rawBuckets = (#groups == 0) and (
    (type(quota) == "table" and type(quota.buckets) == "table" and #quota.buckets > 0 and quota.buckets)
    or (type(summary) == "table" and type(summary.buckets) == "table" and #summary.buckets > 0 and summary.buckets)
  ) or nil

  if rawBuckets then
    local byLabel, order = {}, {}
    for _, b in ipairs(rawBuckets) do
      -- Prefer REQUESTS or untyped buckets; skip duplicate TOKENS buckets if REQUESTS exists.
      if not b.tokenType or b.tokenType == "REQUESTS" then
        local lbl = b.displayName or friendlyModelLabel(b.modelId or b.bucketId)
        if lbl then
          if not byLabel[lbl] then
            byLabel[lbl] = {}
            order[#order + 1] = lbl
          end
          table.insert(byLabel[lbl], b)
        end
      end
    end
    for _, lbl in ipairs(order) do
      local fh, wk = windowsFromBuckets(byLabel[lbl], now)
      if fh or wk then
        groups[#groups + 1] = { label = lbl, fiveHour = fh, weekly = wk }
      end
    end
  end

  -- 3. Fallback: fetchAvailableModels.models
  if #groups == 0 and type(models) == "table" and type(models.models) == "table" then
    local byLabel, order = {}, {}
    for id, m in pairs(models.models) do
      if type(m) == "table" and type(m.quotaInfo) == "table" then
        local lbl = m.displayName or friendlyModelLabel(id)
        if lbl then
          if not byLabel[lbl] then
            byLabel[lbl] = {}
            order[#order + 1] = lbl
          end
          table.insert(byLabel[lbl], m.quotaInfo)
        end
      end
    end
    table.sort(order)
    for _, lbl in ipairs(order) do
      local fh, wk = windowsFromBuckets(byLabel[lbl], now)
      if fh or wk then
        groups[#groups + 1] = { label = lbl, fiveHour = fh, weekly = wk }
      end
    end
  end

  return groups
end

local function isGeminiGroup(label)
  local l = (label or ""):lower()
  return l:find("gemini", 1, true) ~= nil
end

local function isGeminiProGroup(label)
  local l = (label or ""):lower()
  return l:find("gemini", 1, true) ~= nil and l:find("pro", 1, true) ~= nil
end

local function extractTierName(codeAssist)
  if type(codeAssist) ~= "table" then return nil end
  local paid = type(codeAssist.paidTier) == "table" and codeAssist.paidTier or nil
  local cur  = type(codeAssist.currentTier) == "table" and codeAssist.currentTier or nil
  local name = (paid and (paid.name or paid.id))
            or (cur and (cur.name or cur.id))
            or (type(codeAssist.g1Tier) == "string" and codeAssist.g1Tier)
  return name
end

local function extractProject(codeAssist)
  if type(codeAssist) ~= "table" then return nil end
  local p = codeAssist.cloudaicompanionProject
  if type(p) == "string" and p ~= "" then return p end
  if type(p) == "table" then return p.id or p.name end
  return nil
end

function M.loadCodeAssistFromLicenses(licResp)
  if type(licResp) ~= "table" then return nil end
  local tier = { id = "free-tier", name = "free-tier" }
  if type(licResp.licenses) == "table" and type(licResp.licenses[1]) == "table" then
    local l = licResp.licenses[1]
    local id = l.userTier or l.tierId or l.id or "free-tier"
    local name = l.tierDisplayName or l.tierName or l.name or id
    tier = { id = id, name = name }
  end
  return { currentTier = tier, paidTier = tier }
end

function M.mapResponse(summary, quota, codeAssist, email, models, now)
  now = now or os.time()
  local hasTier = type(codeAssist) == "table" and (codeAssist.currentTier ~= nil or codeAssist.paidTier ~= nil)
  if type(summary) ~= "table" and type(quota) ~= "table" and type(models) ~= "table" and not hasTier then
    return {
      status = "error",
      errorMsg = "quota response missing or not an object",
      warnings = { "Cloud Code quota API did not return an object" },
    }
  end

  local groups = extractGroups(summary, quota, models, now)

  -- Top-level windows: prefer Gemini groups (and Gemini Pro when all are 0%),
  -- taking the tightest (most-used) window across Gemini groups so active usage
  -- on either Pro or Flash is always visible on the menubar block.
  local fiveHour, weekly
  local candidates = {}
  for _, g in ipairs(groups) do
    if isGeminiGroup(g.label) then candidates[#candidates + 1] = g end
  end
  if #candidates == 0 then candidates = groups end

  -- Sort candidates so Gemini Pro comes first on a 0% tie.
  local sorted = {}
  for i, g in ipairs(candidates) do sorted[i] = g end
  table.sort(sorted, function(a, b)
    local ap, bp = isGeminiProGroup(a.label), isGeminiProGroup(b.label)
    if ap ~= bp then return ap end
    return false
  end)

  for _, g in ipairs(sorted) do
    fiveHour = tighterWindow(fiveHour, g.fiveHour)
    weekly   = tighterWindow(weekly, g.weekly)
  end

  -- Also check top-level summary.buckets if groups yielded nothing.
  if not fiveHour and not weekly and type(summary) == "table" and type(summary.buckets) == "table" then
    fiveHour, weekly = windowsFromBuckets(summary.buckets, now)
  end

  -- If the user's account has valid Code Assist tier info or an empty bucket list
  -- (e.g. an untouched quota pool with no buckets emitted), synthesize a 0%
  -- window rather than failing with an error.
  if not fiveHour and not weekly then
    local hasEmpty = hasTier
                  or (type(summary) == "table" and (summary.groups ~= nil or summary.buckets ~= nil))
                  or (type(quota) == "table" and quota.buckets ~= nil)
                  or (type(models) == "table" and models.models ~= nil)
    if hasEmpty then
      fiveHour = { percentUsed = 0, percentLeft = 100, resetsAt = nil }
    else
      return {
        status = "error",
        errorMsg = "no usable quota window",
        warnings = { "Cloud Code quota response contained no recognizable buckets" },
      }
    end
  end

  local tier = extractTierName(codeAssist)
  return {
    status     = "ok",
    fiveHour   = fiveHour,
    weekly     = weekly,
    additional = groups,
    account    = { email = email, orgName = tier },
    warnings   = {},
    raw        = { summary = summary, quota = quota, codeAssist = codeAssist, models = models },
  }
end

---------------------------------------------------------------------
-- Fetch
---------------------------------------------------------------------

local USER_AGENT = "antigravity/hub/2.28.2 darwin/arm64"

local function postJson(url, tok, payload, cb)
  local body = (type(payload) == "table" and next(payload) ~= nil) and hs.json.encode(payload) or "{}"
  session.request("POST", url, nil, {
    Authorization = "Bearer " .. tok,
    ["Content-Type"] = "application/json",
    ["User-Agent"] = USER_AGENT,
  }, body, cb)
end

local function getJson(url, tok, cb)
  session.request("GET", url, nil, {
    Authorization = "Bearer " .. tok,
    ["User-Agent"] = USER_AGENT,
  }, nil, cb)
end

local function selectApiBase(codeAssist)
  if type(codeAssist) == "table" and type(codeAssist.currentTier) == "table" and codeAssist.currentTier.usesGcpTos == true then
    return PROD_API_BASE
  end
  return DAILY_API_BASE
end

local function callUsage(acct, cb)
  local home = M.homeFor(acct)
  local auth = readAuth(home)
  local tokens = auth and (auth.tokens or auth)
  local tok = tokens and tokens.access_token
  if not tok then return cb({ status = "needs_login" }) end

  local email = auth.email or (tokens.id_token and (jwtClaims(tokens.id_token) or {}).email)
  local metadata = {
    ideType = "ANTIGRAVITY",
    platform = "PLATFORM_UNSPECIFIED",
    pluginType = "GEMINI",
  }
  local loadBody = { metadata = metadata }
  local stLic, bLic, stLoad, bLoad, stLoadProd, bLoadProd

  local function fetchQuotas(apiBase, codeAssist, project, userTierId, scopeInsufficient)
    local reqBody = project and { project = project } or {}
    local modReqBody = {}
    if project then modReqBody.project = project end
    if userTierId then modReqBody.entitlement = { userTier = userTierId } end
    local summary, quota, models, stSum, stQuo, stMod, bSum, bQuo, bMod
    local stModProd, bModProd
    local pending = 4

    local function finishFetch()
      pending = pending - 1
      if pending > 0 then return end
      if stSum == 401 or stQuo == 401 or stMod == 401 or stModProd == 401 then
        return cb({ status = "needs_login", _retry = true })
      end
      local hasTier = type(codeAssist) == "table" and (codeAssist.currentTier ~= nil or codeAssist.paidTier ~= nil)
      if not summary and not quota and not models and not hasTier then
        if scopeInsufficient then
          return cb({
            status = "needs_login",
            errorMsg = "Re-login required to grant AI Code scope",
          })
        end
        return cb(session.failure("cloudcode-pa quota", stQuo ~= 200 and stQuo or stSum, bQuo or bSum or bMod))
      end
      local effectiveCodeAssist = codeAssist or (auth.tier and { currentTier = { name = auth.tier } } or nil)
      local parsed = M.mapResponse(summary, quota, effectiveCodeAssist, email, models)
      cb(parsed)
    end

    postJson(apiBase .. "/v1internal:retrieveUserQuotaSummary", tok, reqBody, function(st, b)
      stSum, bSum = st, b
      if st == 200 and not summary then summary = session.json(b) end
      finishFetch()
    end)

    postJson(apiBase .. "/v1internal:retrieveUserQuota", tok, reqBody, function(st, b)
      stQuo, bQuo = st, b
      if st == 200 then quota = session.json(b) end
      finishFetch()
    end)

    postJson(DAILY_API_BASE .. "/v1internal:fetchAvailableModels", tok, modReqBody, function(st, b)
      stMod, bMod = st, b
      if st == 200 and not models then models = session.json(b) end
      finishFetch()
    end)

    postJson(PROD_API_BASE .. "/v1internal:fetchAvailableModels", tok, modReqBody, function(st, b)
      stModProd, bModProd = st, b
      if st == 200 and not models then models = session.json(b) end
      finishFetch()
    end)
  end

  local initPending = 3

  local function finishInit()
    initPending = initPending - 1
    if initPending > 0 then return end
    if stLic == 401 or stLoad == 401 then
      return cb({ status = "needs_login", _retry = true })
    end

    local scopeInsufficient = (stLic == 403 and type(bLic) == "string" and bLic:find("ACCESS_TOKEN_SCOPE_INSUFFICIENT", 1, true) ~= nil)
    local licCodeAssist = (stLic == 200) and M.loadCodeAssistFromLicenses(session.json(bLic)) or nil
    local loadCodeAssist = (stLoad == 200 and session.json(bLoad)) or (stLoadProd == 200 and session.json(bLoadProd)) or nil

    -- Prefer loadCodeAssist when it carries a GCP project or active tier; otherwise fall back to fetchLicenses.
    local codeAssist = (loadCodeAssist and (loadCodeAssist.currentTier or loadCodeAssist.cloudaicompanionProject))
                       and loadCodeAssist
                       or licCodeAssist
                       or loadCodeAssist

    local apiBase = selectApiBase(codeAssist)
    local project = extractProject(loadCodeAssist) or extractProject(codeAssist) or auth.project
    local tier = extractTierName(codeAssist) or auth.tier
    local userTierId = (licCodeAssist and licCodeAssist.currentTier and licCodeAssist.currentTier.id)
                    or (codeAssist and codeAssist.currentTier and codeAssist.currentTier.id)

    if (project and project ~= auth.project) or (tier and tier ~= auth.tier) then
      auth.project = project or auth.project
      auth.tier = tier or auth.tier
      writeAuth(home, auth)
    end

    fetchQuotas(apiBase, codeAssist, project, userTierId, scopeInsufficient)
  end

  getJson(AICODE_API_BASE .. "/v1alpha:fetchLicenses", tok, function(st, b)
    stLic, bLic = st, b
    finishInit()
  end)

  postJson(DAILY_API_BASE .. "/v1internal:loadCodeAssist", tok, loadBody, function(st, b)
    stLoad, bLoad = st, b
    finishInit()
  end)

  postJson(PROD_API_BASE .. "/v1internal:loadCodeAssist", tok, loadBody, function(st, b)
    stLoadProd, bLoadProd = st, b
    finishInit()
  end)
end

function M.fetch(acct, cb)
  local home = M.homeFor(acct)
  local auth = readAuth(home)
  local tokens = auth and (auth.tokens or auth)
  if not (tokens and tokens.access_token) then
    return cb({ status = "needs_login" })
  end
  local mtime = hs.fs.attributes(home .. "/auth.json", "modification")
  local exp = tonumber(tokens.expires_at) or jwtExp(tokens.id_token) or jwtExp(tokens.access_token)
  local now = os.time()

  local function go()
    callUsage(acct, function(parsed)
      if parsed._retry then
        M.refreshToken(acct, function(ok)
          if ok then callUsage(acct, cb) else cb({ status = "needs_login" }) end
        end)
      else
        cb(parsed)
        if parsed.status == "ok" and M.needsRefresh(mtime, exp, now) then
          M.refreshToken(acct, function() end)
        end
      end
    end)
  end

  if M.needsRefresh(nil, exp, now) then
    M.refreshToken(acct, function() go() end)
  else
    go()
  end
end

---------------------------------------------------------------------
-- Login (Google OAuth 2.0 loopback with PKCE) + logout
---------------------------------------------------------------------

function M.loginWindow(label, authUrl)
  local esc = function(t) return (tostring(t):gsub("[&<>\"']", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&#39;" })) end
  local html = [[<!doctype html><meta charset="utf-8"><style>
    body{font:15px -apple-system,sans-serif;margin:0;padding:22px 26px;background:#1e1e1e;color:#eee}
    .warn{background:#5a3b00;border:1px solid #f0a020;color:#ffd27a;border-radius:8px;padding:10px 12px;font-weight:600}
    ol{padding-left:22px;line-height:1.6} li{margin:8px 0} b{color:#fff}
    a.btn{display:inline-block;background:#4285f4;color:#fff;text-decoration:none;font-weight:600;
      padding:8px 14px;border-radius:6px;margin-top:4px}
    .muted{color:#999;font-size:13px;margin-top:12px}</style>
    <div class="warn">⚠️ Sign in with the Google account for „]] .. esc(label) .. [[“.</div>
    <ol>
      <li>A browser tab opened for <b>Google Sign-In</b>.</li>
      <li>Pick the Google account you want this block to track and click <b>Allow</b>.</li>
      <li>This window will close automatically once sign-in finishes.</li>
    </ol>
    <p><a class="btn" href="]] .. esc(authUrl) .. [[">Re-open sign-in page</a></p>
    <div class="muted">Each Gemini account keeps its own isolated token, independent of your browser or IDE.</div>]]
  local sf = hs.screen.mainScreen():frame()
  local w, h = 360, 260
  return hs.webview.new({ x = sf.x + sf.w - w - 24, y = sf.y + sf.h - h - 40, w = w, h = h })
    :windowStyle({ "titled", "closable" }):windowTitle("Gemini login: " .. label)
    :deleteOnClose(true)
    :html(html):show()
end

local function callbackHtml(ok, msg)
  local title = ok and "Signed in to Gemini" or "Sign-in failed"
  local color = ok and "#10B981" or "#EF4444"
  return [[<!doctype html><meta charset="utf-8"><title>]] .. title .. [[</title><style>
    body{font:16px -apple-system,sans-serif;background:#18181b;color:#f4f4f5;display:flex;
      align-items:center;justify-content:center;height:100vh;margin:0}
    .card{background:#27272a;border:1px solid #3f3f46;border-radius:12px;padding:28px 36px;text-align:center;max-width:420px}
    h2{margin:0 0 10px;color:]] .. color .. [[} p{margin:0;color:#a1a1aa;line-height:1.5}</style>
    <div class="card"><h2>]] .. title .. [[</h2><p>]] .. msg .. [[</p></div>]]
end

function M.customLogin(acct, onDone)
  local home = M.homeFor(acct)
  os.execute("mkdir -p '" .. home .. "'")
  local cid, csec = clientCreds()
  if not (cid and csec) then
    hs.alert.show("Gemini OAuth client not configured in ~/.hammerspoon/claude_usage_auth/gemini/client.json", 4)
    return
  end

  local verifier = randomUrlSafe(32)
  local challenge = base64url(hs.hash.bSHA256(verifier))
  local stateParam = randomUrlSafe(16)
  local srv, timeoutTimer, win, finished = nil, nil, nil, false

  local function finish(ok, errMsg)
    if finished then return end
    finished = true
    if timeoutTimer then timeoutTimer:stop(); timeoutTimer = nil end
    if win then win:delete(); win = nil end
    if srv then
      hs.timer.doAfter(0.5, function()
        if srv then pcall(function() srv:stop() end); srv = nil end
      end)
    end
    if ok then
      hs.alert.show("Gemini account added", 2)
      if onDone then onDone() end
    else
      hs.alert.show("Gemini login failed: " .. (errMsg or "timed out or cancelled"), 3)
    end
  end

  srv = hs.httpserver.new(false, false)
  srv:setInterface("localhost")
  srv:setCallback(function(_, path)
    if path:match("^/favicon%.ico") then return "", 404, {} end
    local q = parseQuery(path)
    if q.error then
      hs.timer.doAfter(0.1, function() finish(false, q.error) end)
      return callbackHtml(false, "Google returned an error: " .. tostring(q.error)), 200,
        { ["Content-Type"] = "text/html; charset=utf-8" }
    end
    if not q.code or q.state ~= stateParam then
      return callbackHtml(false, "Invalid callback parameters."), 400,
        { ["Content-Type"] = "text/html; charset=utf-8" }
    end

    local redirectUri = "http://localhost:" .. tostring(srv:getPort()) .. "/oauth-callback"
    local body = encodeForm({
      client_id = cid,
      client_secret = csec,
      code = q.code,
      code_verifier = verifier,
      grant_type = "authorization_code",
      redirect_uri = redirectUri,
    })

    session.request("POST", TOKEN_URL, nil, {
      ["Content-Type"] = "application/x-www-form-urlencoded",
    }, body, function(st, b)
      local j = session.json(b or "")
      if st ~= 200 or not (j and j.access_token) then
        log.e("token exchange failed st=" .. tostring(st) .. " " .. tostring(b))
        return finish(false, "token exchange failed (HTTP " .. tostring(st) .. ")")
      end
      local claims = j.id_token and jwtClaims(j.id_token) or nil
      local email = claims and claims.email or nil
      local auth = {
        tokens = {
          access_token  = j.access_token,
          refresh_token = j.refresh_token,
          id_token      = j.id_token,
          scope         = j.scope,
          expires_at    = os.time() + (tonumber(j.expires_in) or 3600),
        },
        email = email,
        last_refresh = os.date("!%Y-%m-%dT%H:%M:%S.000000Z"),
      }
      if email then
        writeAuth(home, auth)
        finish(true)
      else
        session.get(USERINFO_URL, nil, { Authorization = "Bearer " .. j.access_token }, function(ust, ub)
          local uj = ust == 200 and session.json(ub or "") or nil
          if uj and uj.email then auth.email = uj.email end
          writeAuth(home, auth)
          finish(true)
        end)
      end
    end)

    return callbackHtml(true, "You can close this tab and return to Hammerspoon."), 200,
      { ["Content-Type"] = "text/html; charset=utf-8" }
  end)

  srv:start()
  local port = srv:getPort()
  if not port or port == 0 then
    return finish(false, "could not bind localhost callback port")
  end

  local redirectUri = "http://localhost:" .. tostring(port) .. "/oauth-callback"
  local authUrl = AUTH_URL .. "?" .. encodeForm({
    access_type = "offline",
    client_id = cid,
    code_challenge = challenge,
    code_challenge_method = "S256",
    prompt = "select_account consent",
    redirect_uri = redirectUri,
    response_type = "code",
    scope = SCOPES,
    state = stateParam,
  })

  hs.urlevent.openURL(authUrl)
  win = M.loginWindow(acct.label or M.label, authUrl)
  timeoutTimer = hs.timer.doAfter(300, function() finish(false, "timed out") end)
end

function M.logout(acct, cb)
  local home = M.homeFor(acct)
  local auth = readAuth(home)
  local tokens = auth and (auth.tokens or auth)
  local tok = tokens and (tokens.refresh_token or tokens.access_token)
  local function clean()
    os.execute("rm -rf '" .. home .. "'")
    if cb then cb() end
  end
  if not tok then return clean() end
  session.request("POST", REVOKE_URL, nil, {
    ["Content-Type"] = "application/x-www-form-urlencoded",
  }, "token=" .. urlEncode(tok), function() clean() end)
end

return M
