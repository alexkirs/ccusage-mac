local M = {}

M.logRing = {}
M.fetchTimings = {}

-- Settings wrappers. Every setting the widget owns lives under "claude_usage.*",
-- so all reads/writes go through here to keep the namespace consistent.
local NS = "claude_usage."

function M.get(k, default)
  local v = hs.settings.get(NS .. k)
  if v == nil then return default end
  return v
end

function M.set(k, v) hs.settings.set(NS .. k, v) end

-- Account registry. One entry per menubar item:
--   { id, provider, label?, cookie?, cookieExpires?, orgUuid? }
-- cookie is the ready-to-send "Cookie:" header value for that account's
-- session. Plaintext in the settings plist, same protection level WebKit's
-- own cookie file has.
function M.accounts() return M.get("accounts", {}) end
function M.saveAccounts(list) M.set("accounts", list) end

-- Logger factory. Honors the current log_level setting without each module
-- having to call hs.settings.get itself.
function M.logger(name)
  return hs.logger.new("cu." .. name, M.get("log_level", "info"))
end

function M.log(level, msg)
  local line = os.date("%H:%M:%S") .. " [" .. level .. "] " .. tostring(msg)
  table.insert(M.logRing, line)
  if #M.logRing > 200 then table.remove(M.logRing, 1) end
end

function M.recordTiming(ms)
  table.insert(M.fetchTimings, ms)
  if #M.fetchTimings > 20 then table.remove(M.fetchTimings, 1) end
end

function M.avgFetchMs()
  if #M.fetchTimings == 0 then return 0 end
  local s = 0
  for _, v in ipairs(M.fetchTimings) do s = s + v end
  return math.floor(s / #M.fetchTimings)
end

return M
