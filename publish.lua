-- Publishes the full parsed state to an HTTP endpoint (web/worker.js on
-- Cloudflare) so a phone can read everything the menu shows, not just the
-- strip.
--
--   POST <publish.url>  X-Token: <publish.token>
--   { ts, accounts: [ { id, provider, label, tag, s } ] }
--
-- `s` is the provider's own parsed result minus `raw`/`fetchTiming`: status,
-- fiveHour, weekly, additional[] (per-model windows), account, extraUsage,
-- resets, warnings, lastFetch. Accounts come in registry order; hidden ones
-- have no instance and never appear.
--
-- Enable:
--   hs -c 'require("claude_usage.state").set("publish.url", "https://limits.kirs.online/push")'
--   hs -c 'require("claude_usage.state").set("publish.token", "<secret>")'
local PREFIX = ((...) or "claude_usage"):gsub("%.[^.]+$", "")
local state = require(PREFIX .. ".state")
local log = state.logger("publish")

local M = {
  -- The worker stores in D1 now: ~3 rows written per push against a free
  -- allowance of 100k a day, so a push a minute costs nothing.
  period = 60,      -- how often the payload is rebuilt
  heartbeat = 600,  -- force a push this often even when nothing changed
}

local timer, lastSig, lastSent = nil, nil, 0

local SKIP = { raw = true, fetchTiming = true }

-- The page is public: nobody needs the whole address to tell the accounts
-- apart, the labels already do that.
local function mask(str)
  if type(str) ~= "string" then return str end
  return (str:gsub("([%w._%%+-])[%w._%%+-]*(@[%w.-]+)", "%1***%2"))
end

local function accounts(menubar)
  local out = {}
  for _, a in ipairs(menubar.accounts) do
    local inst = menubar.instances[a.id]
    if inst then
      local s = {}
      for k, v in pairs(inst.s) do if not SKIP[k] then s[k] = v end end
      if s.account then
        s.account = { email = mask(s.account.email), orgName = mask(s.account.orgName) }
      end
      out[#out + 1] = { id = a.id, provider = a.provider, label = a.label or inst.provider.label,
                        tag = a.tag, s = s }
    end
  end
  return out
end

-- Deterministic fingerprint. hs.json.encode does not promise key order, so the
-- payload itself is no good for "did anything change".
local function canon(v)
  if type(v) ~= "table" then return tostring(v) end
  local parts = {}
  for k, val in pairs(v) do parts[#parts + 1] = tostring(k) .. "=" .. canon(val) end
  table.sort(parts)
  return "{" .. table.concat(parts, ",") .. "}"
end

local function push(menubar)
  local url, token = state.get("publish.url"), state.get("publish.token")
  if not (url and token) then return end
  local list = accounts(menubar)
  -- lastFetch moves every cycle; it alone is not a reason to spend a KV write.
  local s = canon(list):gsub("lastFetch=%d+", "")
  local now = os.time()
  if s == lastSig and now - lastSent < M.heartbeat then return end
  hs.http.doAsyncRequest(url, "POST", hs.json.encode({ ts = now, accounts = list }),
    { ["Content-Type"] = "application/json", ["X-Token"] = token },
    function(st, b)
      if st == 200 then lastSig, lastSent = s, now
      else log.w("push failed st=" .. tostring(st) .. " " .. tostring(b)) end
    end)
end

function M.start(menubar)
  if timer then timer:stop() end
  timer = hs.timer.doEvery(M.period, function() push(menubar) end)
  M.pushNow = function() push(menubar) end
end

function M.stop() if timer then timer:stop(); timer = nil end end

return M
