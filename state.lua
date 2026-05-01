local M = {}

M.data = {
  fiveHour = nil,
  weekly = nil,
  weeklySonnet = nil,
  weeklyOpus = nil,
  weeklyHaiku = nil,
  spend = nil,
  account = nil,     -- { email, fullName, orgUuid, orgName }
  extraUsage = nil,  -- { isEnabled, monthlyLimit, usedCredits, utilization, currency }
  warnings = nil,
  lastFetch = nil,
  status = "init",
  errorMsg = nil,
  fetchTiming = { totalMs = 0 },
}

-- Parallel state for the Codex provider. Same shape as M.data; populated by
-- codex_data.lua. additional[] is a list of { label, fiveHour, weekly } for
-- per-model rate limits the API returns alongside the primary windows.
M.codexData = {
  fiveHour = nil,
  weekly = nil,
  additional = nil,  -- list of { label, fiveHour, weekly }
  account = nil,     -- { email, orgName }
  warnings = nil,
  lastFetch = nil,
  status = "init",
  errorMsg = nil,
  fetchTiming = { totalMs = 0 },
}

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
