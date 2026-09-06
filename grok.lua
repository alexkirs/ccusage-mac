-- grok.com provider: `sso` cookies → weekly usage pool via gRPC-web.
--
-- The SuperGrok weekly pool (Settings → Usage) is served by
--   POST /grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig
-- as gRPC-web. There is no JSON/REST variant (the descriptor's
-- /rest/grok/credits annotation 404s). We speak grpc-web-text (base64
-- framed protobuf) because hs.http cannot carry binary bodies, and decode
-- the handful of fields we need with a tiny protobuf wire-format parser.
--
--   GetGrokCreditsConfigResponse { 1: config GrokCreditsConfig }
--   GrokCreditsConfig { 1: credit_usage_percent float, 7: product_usage[] ProductUsage,
--                       8: current_period UsagePeriod }
--   UsagePeriod { 1: type enum (1 MONTHLY, 2 WEEKLY), 2: start Timestamp, 3: end Timestamp }
--   ProductUsage { 1: product enum, 2: usage_percent float }
--   Timestamp { 1: seconds }
--
-- Per-model 2h windows (POST /rest/rate-limits) still exist alongside the
-- pool; one of them is shown as an additional block behind the toggle.
local PREFIX = ((...) or "claude_usage"):gsub("%.[^.]+$", "")
local session = require(PREFIX .. ".session")

local M = {
  id = "grok",
  label = "grok",
  loginLabel = "grok.com",
  openSettingsLabel = "grok.com usage",
  openSettingsUrl = "https://grok.com/?_s=usage",
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
  probeUrl = nil,  -- login.lua falls back to the sso cookie landing in the jar
}

local CREDITS_URL = "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig"
local EMPTY_FRAME = "AAAAAAA="      -- grpc-web frame: flag 0, length 0 (empty request)
local RATE_MODEL = "grok-4-auto"     -- per-model 2h window shown as an extra block

local function pct(n) return math.tointeger(n) or n end

---------------------------------------------------------------------
-- grpc-web-text + protobuf wire format
---------------------------------------------------------------------

-- Decodes concatenated, individually padded base64 chunks (grpc-web-text
-- puts each frame through base64 separately, so '=' can appear mid-stream).
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64V = {}
for i = 1, #B64 do B64V[B64:sub(i, i)] = i - 1 end
local function b64decode(s)
  local out, bits, nbits = {}, 0, 0
  for c in s:gmatch(".") do
    if c == "=" then
      bits, nbits = 0, 0  -- padding ends a chunk; drop leftover bits
    elseif B64V[c] then
      bits = (bits << 6) | B64V[c]; nbits = nbits + 6
      if nbits >= 8 then
        nbits = nbits - 8
        out[#out + 1] = string.char((bits >> nbits) & 0xFF)
        bits = bits & ((1 << nbits) - 1)
      end
    end
  end
  return table.concat(out)
end

-- Splits grpc-web frames: 1 byte flags (0x80 = trailers), 4 byte BE length.
local function frames(bin)
  local out, i = {}, 1
  while i + 5 <= #bin + 1 do
    local flag, len = string.unpack(">BI4", bin, i)
    out[#out + 1] = { flag = flag, data = bin:sub(i + 5, i + 4 + len) }
    i = i + 5 + len
  end
  return out
end

local function varint(b, i)
  local r, s = 0, 0
  repeat
    local c = b:byte(i); i = i + 1
    r = r | ((c & 0x7F) << s); s = s + 7
  until c < 0x80
  return r, i
end

-- Protobuf message → { [field] = value | {values...} }; length-delimited
-- values stay raw strings (decode nested messages with another call).
local function pb(b)
  local out, i = {}, 1
  while i <= #b do
    local key; key, i = varint(b, i)
    local f, w, v = key >> 3, key & 7, nil
    if w == 0 then v, i = varint(b, i)
    elseif w == 1 then v = string.unpack("<d", b, i); i = i + 8
    elseif w == 2 then local len; len, i = varint(b, i); v = b:sub(i, i + len - 1); i = i + len
    elseif w == 5 then v = string.unpack("<f", b, i); i = i + 4
    else return out end
    if out[f] == nil then out[f] = v
    elseif type(out[f]) == "table" and out[f].__rep then table.insert(out[f], v)
    else out[f] = { __rep = true, out[f], v } end
  end
  return out
end

local function repeated(v)
  if v == nil then return {} end
  if type(v) == "table" and v.__rep then return v end
  return { v }
end

local function tsSeconds(raw) return raw and pb(raw)[1] or nil end

-- billing_product.Product enum (from the frontend's descriptor).
local PRODUCT = { [1] = "API", [2] = "Build", [3] = "Plugins", [4] = "Chat", [5] = "Imagine", [6] = "Voice" }

-- Decodes a grpc-web-text response body into the widget's parsed shape.
function M.decodeCredits(bodyText)
  local data, trailer
  for _, fr in ipairs(frames(b64decode(bodyText))) do
    if fr.flag & 0x80 ~= 0 then trailer = fr.data else data = data or fr.data end
  end
  local gstatus = trailer and tonumber(trailer:match("grpc%-status:%s*(%d+)"))
  if not data then
    if gstatus == 16 or gstatus == 7 then return { status = "needs_login" } end
    return { status = "error", errorMsg = "grok: no data frame (grpc-status " .. tostring(gstatus) .. ")",
             warnings = { "GetGrokCreditsConfig returned no message; trailer: " .. tostring(trailer):sub(1, 120) } }
  end
  local resp = pb(data)
  local cfg = resp[1] and pb(resp[1]) or {}
  local period = cfg[8] and pb(cfg[8]) or {}
  local used = pct(math.floor((cfg[1] or 0) + 0.5))
  local win = {
    percentUsed = used,
    percentLeft = pct(100 - used),
    resetsAt    = tsSeconds(period[3]),
    startsAt    = tsSeconds(period[2]),
    periodType  = ({ [1] = "monthly", [2] = "weekly" })[period[1]] or "unknown",
  }
  local additional = {}
  for _, raw in ipairs(repeated(cfg[7])) do
    local pu = pb(raw)
    local u = pct(math.floor((pu[2] or 0) + 0.5))
    additional[#additional + 1] = {
      label = "pool · " .. (PRODUCT[pu[1]] or ("product " .. tostring(pu[1]))),
      weekly = { percentUsed = u, percentLeft = pct(100 - u), resetsAt = win.resetsAt },
    }
  end
  return {
    status     = "ok",
    fiveHour   = nil,
    weekly     = win,
    additional = additional,
    account    = { email = "grok.com", orgName = win.periodType .. " pool" },
    warnings   = {},
    raw        = { creditsConfig = { usagePercent = cfg[1] or 0, periodType = period[1],
                                     start = win.startsAt, ["end"] = win.resetsAt } },
  }
end

---------------------------------------------------------------------
-- Fetch
---------------------------------------------------------------------

local function rateLimitWindow(r)
  if type(r) ~= "table" or type(r.remainingQueries) ~= "number" then return nil end
  local total = r.totalQueries
  if type(total) ~= "number" or total <= 0 then return nil end
  local used = math.floor((total - r.remainingQueries) / total * 100 + 0.5)
  local wait = r.waitTimeSeconds or r.windowSizeSeconds
  return { percentUsed = pct(used), percentLeft = pct(100 - used),
           resetsAt = type(wait) == "number" and (os.time() + wait) or nil }
end

function M.fetch(acct, cb)
  if not acct.cookie then return cb({ status = "needs_login" }) end
  session.request("POST", CREDITS_URL, acct.cookie,
    { ["Content-Type"] = "application/grpc-web-text", Accept = "application/grpc-web-text", ["x-grpc-web"] = "1" },
    EMPTY_FRAME,
    function(st, body, headers)
      if st ~= 200 then return cb(session.failure("GetGrokCreditsConfig", st, body)) end
      local gstatus = tonumber(headers["grpc-status"] or headers["Grpc-Status"] or "")
      if gstatus == 16 or gstatus == 7 then return cb({ status = "needs_login" }) end
      local ok, parsed = pcall(M.decodeCredits, body)
      if not ok then
        return cb({ status = "error", errorMsg = "grok: decode failed: " .. tostring(parsed),
                    warnings = { "GetGrokCreditsConfig response could not be decoded" } })
      end
      if parsed.status ~= "ok" then return cb(parsed) end
      -- Best-effort extra block: the per-model 2h window.
      session.request("POST", "https://grok.com/rest/rate-limits", acct.cookie,
        { ["Content-Type"] = "application/json" },
        hs.json.encode({ requestKind = "DEFAULT", modelName = RATE_MODEL }),
        function(s2, b2)
          local win = s2 == 200 and rateLimitWindow(session.json(b2)) or nil
          if win then
            table.insert(parsed.additional, { label = RATE_MODEL .. " · 2h", fiveHour = win })
            parsed.raw.rateLimits = session.json(b2)
          end
          cb(parsed)
        end)
    end)
end

function M.logout(acct, cb) cb() end

return M
