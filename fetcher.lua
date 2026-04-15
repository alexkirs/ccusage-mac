-- React Query reader. Walks the SPA's React fiber tree to find the
-- QueryClient, calls refetchQueries to ask Anthropic's backend for fresh
-- usage numbers, then reads the structured JSON straight out of the cache.
--
-- This is the only data-extraction path. The innerText scraper in
-- scraper.lua is now only used to drive WV navigation/login. If anything
-- in this path breaks, the widget surfaces a warning instead of falling
-- back to a worse path — the user can then debug or update the JS.

local state = require("claude_usage.state")
local scraper = require("claude_usage.scraper")
local log = hs.logger.new("cu.fetcher", hs.settings.get("claude_usage.log_level") or "info")

local M = {}

local FETCH_TIMEOUT_S = 15
local POLL_INTERVAL_S = 0.1

---------------------------------------------------------------------
-- ISO timestamp → epoch
---------------------------------------------------------------------

-- Compute local time's offset from UTC in seconds (positive if ahead).
local function utcOffset()
  local now = os.time()
  return os.difftime(now, os.time(os.date("!*t", now)))
end

-- "2026-04-15T14:00:00.590910+00:00" → epoch (assumes UTC source).
local function isoToEpoch(iso)
  if not iso or type(iso) ~= "string" then return nil end
  local y, mo, d, h, mi, s = iso:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then return nil end
  -- os.time interprets the components table as LOCAL time. Add the local
  -- UTC offset to convert to the true UTC epoch.
  return os.time({
    year = tonumber(y), month = tonumber(mo), day = tonumber(d),
    hour = tonumber(h), min = tonumber(mi), sec = tonumber(s),
  }) + utcOffset()
end

---------------------------------------------------------------------
-- Response → state shape
---------------------------------------------------------------------

local function makeWindow(d)
  if not d or type(d.utilization) ~= "number" then return nil end
  return {
    percentUsed = d.utilization,
    percentLeft = math.max(0, 100 - d.utilization),
    resetsAt = isoToEpoch(d.resets_at),
    resetsHuman = nil,
  }
end

local function mapResponse(data)
  if type(data) ~= "table" then
    return { status = "error", errorMsg = "fetcher: response not a table" }
  end
  local five = makeWindow(data.five_hour)
  local weekly = makeWindow(data.seven_day)
  if not five or not weekly then
    return {
      status = "error",
      errorMsg = "fetcher: missing five_hour/seven_day in response",
      warnings = {
        "API response shape changed — expected fields five_hour and seven_day with .utilization and .resets_at",
        "Open Debug → Copy state JSON and inspect the raw response in last-fetcher.json",
      },
    }
  end
  local spend = {}
  if data.extra_usage and data.extra_usage.is_enabled
      and type(data.extra_usage.utilization) == "number" then
    table.insert(spend, {
      percentUsed = data.extra_usage.utilization,
      percentLeft = math.max(0, 100 - data.extra_usage.utilization),
      resetsAt = nil,  -- API doesn't expose a reset for spend
      resetsHuman = nil,
      heading = "Extra usage",
    })
  end
  return {
    status = "ok",
    fiveHour = five,
    weekly = weekly,
    weeklySonnet = makeWindow(data.seven_day_sonnet),
    weeklyOpus = makeWindow(data.seven_day_opus),
    weeklyHaiku = makeWindow(data.seven_day_haiku),
    spend = spend,
    warnings = {},
  }
end

---------------------------------------------------------------------
-- JS payload
---------------------------------------------------------------------

-- Walks the React fiber tree to find the TanStack QueryClient, calls
-- refetchQueries to force a fresh server fetch, then stashes the resolved
-- query state on window.__cu.lastFetch with the supplied token.
local FETCH_JS_TEMPLATE = [[
(function(){
  var TOKEN = "%s";
  window.__cu = window.__cu || {};
  window.__cu.lastFetch = {stage:"starting", token: TOKEN};

  if (/\/(login|auth|sign-in)/.test(location.href)) {
    window.__cu.lastFetch = {stage:"done", token: TOKEN, needsLogin: true};
    return;
  }

  // Cache the queryClient on window so we don't re-walk the fiber every tick.
  if (!window.__cu.qc || !window.__cu.qc.getQueryCache) {
    try {
      var root = document.getElementById("root");
      if (!root) {
        window.__cu.lastFetch = {stage:"done", token: TOKEN, err: "no #root element"};
        return;
      }
      var key = Object.keys(root).find(function(k){ return k.indexOf("__reactContainer") === 0; });
      if (!key) {
        window.__cu.lastFetch = {stage:"done", token: TOKEN, err: "no __reactContainer key on #root"};
        return;
      }
      var fiber = root[key].stateNode && root[key].stateNode.current;
      if (!fiber) {
        window.__cu.lastFetch = {stage:"done", token: TOKEN, err: "no fiber on react container"};
        return;
      }
      var queue = [fiber], found = null, visited = 0;
      while (queue.length && !found && visited++ < 5000) {
        var n = queue.shift(); if (!n) continue;
        var mp = n.memoizedProps;
        if (mp && mp.client && mp.client.getQueryCache) found = mp.client;
        if (n.child) queue.push(n.child);
        if (n.sibling) queue.push(n.sibling);
      }
      if (!found) {
        window.__cu.lastFetch = {stage:"done", token: TOKEN, err: "no QueryClient (visited " + visited + " fibers)"};
        return;
      }
      window.__cu.qc = found;
    } catch (e) {
      window.__cu.lastFetch = {stage:"done", token: TOKEN, err: "fiber walk: " + String(e)};
      return;
    }
  }

  try {
    window.__cu.qc.refetchQueries({queryKey: ["unified_limits_utilization"]})
      .then(function(){
        try {
          var all = window.__cu.qc.getQueryCache().getAll();
          var q = all.find(function(q){
            return q.queryKey && q.queryKey[0] === "unified_limits_utilization";
          });
          if (!q) {
            window.__cu.lastFetch = {stage:"done", token: TOKEN, err: "unified_limits_utilization query not in cache after refetch"};
            return;
          }
          if (q.state.status === "error") {
            window.__cu.lastFetch = {stage:"done", token: TOKEN, err: "query state=error: " + String(q.state.error)};
            return;
          }
          window.__cu.lastFetch = {
            stage: "done", token: TOKEN,
            queryStatus: q.state.status,
            updatedAt: q.state.dataUpdatedAt,
            data: q.state.data,
          };
        } catch (e) {
          window.__cu.lastFetch = {stage:"done", token: TOKEN, err: "extract: " + String(e)};
        }
      })
      .catch(function(e){
        window.__cu.lastFetch = {stage:"done", token: TOKEN, err: "refetch reject: " + String(e)};
      });
  } catch (e) {
    window.__cu.lastFetch = {stage:"done", token: TOKEN, err: "refetch throw: " + String(e)};
  }
})()
]]

local READ_JS = "JSON.stringify(window.__cu && window.__cu.lastFetch || {stage:'none'})"

---------------------------------------------------------------------
-- Fetch path
---------------------------------------------------------------------

local function runOnce(onDone)
  local t0 = hs.timer.secondsSinceEpoch()
  local token = string.format("%d_%d", os.time(), math.random(1000000))
  local fetchJs = FETCH_JS_TEMPLATE:format(token)

  local function finish(parsed)
    local dt = math.floor((hs.timer.secondsSinceEpoch() - t0) * 1000)
    state.recordTiming(dt)
    state.data.fetchTiming = { totalMs = dt }
    parsed.lastFetch = os.time()
    log.i(string.format("fetcher done dt=%dms status=%s", dt, parsed.status or "?"))
    onDone(parsed)
  end

  scraper.runJS(fetchJs, function(_, _) end)

  local pollTimer, timeoutTimer
  local done = false

  pollTimer = hs.timer.doEvery(POLL_INTERVAL_S, function()
    if done then if pollTimer then pollTimer:stop(); pollTimer = nil end; return end
    scraper.runJS(READ_JS, function(resultStr, _)
      if done or not resultStr then return end
      local ok, info = pcall(hs.json.decode, resultStr)
      if not ok or type(info) ~= "table" then return end
      if info.stage ~= "done" or info.token ~= token then return end
      done = true
      if pollTimer then pollTimer:stop(); pollTimer = nil end
      if timeoutTimer then timeoutTimer:stop(); timeoutTimer = nil end

      if info.needsLogin then
        finish({ status = "needs_login" })
        return
      end
      if info.err then
        log.e("fetcher: " .. info.err)
        finish({
          status = "error",
          errorMsg = "fetcher: " .. info.err,
          warnings = {
            "Fetcher path broken: " .. info.err,
            "Likely cause: SPA changed React internals, or the unified_limits_utilization query key was renamed",
            "Debug: open Hammerspoon console; Debug → Copy state JSON",
          },
        })
        return
      end
      finish(mapResponse(info.data))
    end)
  end)

  timeoutTimer = hs.timer.doAfter(FETCH_TIMEOUT_S, function()
    if done then return end
    done = true
    if pollTimer then pollTimer:stop(); pollTimer = nil end
    log.w("fetcher timeout")
    finish({
      status = "error",
      errorMsg = "fetcher timeout after " .. FETCH_TIMEOUT_S .. "s",
      warnings = {
        "Fetcher exceeded " .. FETCH_TIMEOUT_S .. "s — page may be unresponsive",
        "Try Debug → Reload page now (hard) or Debug → Destroy persistent webview",
      },
    })
  end)
end

function M.fetch(onDone)
  scraper.ensureLoaded(function(ok, err)
    if not ok then
      onDone({
        status = "error",
        errorMsg = "page load failed: " .. tostring(err),
        warnings = {
          "Persistent WebKit view failed to load /settings/usage",
          "Check network, then Debug → Destroy persistent webview to retry from scratch",
        },
        lastFetch = os.time(),
      })
      return
    end
    if err == "needs_login" then
      onDone({ status = "needs_login", lastFetch = os.time() })
      return
    end
    runOnce(onDone)
  end)
end

return M
