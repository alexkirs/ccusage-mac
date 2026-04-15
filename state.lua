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

M.logRing = {}
M.fetchTimings = {}

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
