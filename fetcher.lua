-- Data path: walks the SPA's React fiber tree once to find the TanStack
-- QueryClient, then on every tick forces a fresh server round-trip for the
-- three queries that drive the widget:
--   unified_limits_utilization  → 5h / weekly / weekly-sonnet windows
--   overage_spend_limit         → "Extra usage" balance + on/off
--   current_account             → logged-in email + org (stable, not refetched)
--
-- No innerText parsing, no anchor table, no shape classifier. The SPA's own
-- queryFn handles auth / CSRF / URL — we only read the decoded result.
--
-- Failure mode: surface a specific warning; no fallback.

local state = require("claude_usage.state")
local scraper = require("claude_usage.scraper")
local log = hs.logger.new("cu.fetcher", hs.settings.get("claude_usage.log_level") or "info")

local M = {}

local FETCH_TIMEOUT_S = 20  -- generous so the JS-side 6 s mount-wait never races this
local POLL_INTERVAL_S = 0.1
local SAFETY_RELOAD_INTERVAL_S = 3 * 3600   -- reload the WV every 3h for hygiene
local DEBUG_DIR = os.getenv("HOME") .. "/.hammerspoon/claude_usage/debug"

---------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------

local function utcOffset()
  local now = os.time()
  return os.difftime(now, os.time(os.date("!*t", now)))
end

-- "2026-04-15T14:00:00.590910+00:00" → epoch (source always UTC in practice).
local function isoToEpoch(iso)
  if not iso or type(iso) ~= "string" then return nil end
  local y, mo, d, h, mi, s = iso:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then return nil end
  return os.time({
    year = tonumber(y), month = tonumber(mo), day = tonumber(d),
    hour = tonumber(h), min = tonumber(mi), sec = tonumber(s),
  }) + utcOffset()
end

local function writeFile(path, contents)
  hs.fs.mkdir(DEBUG_DIR)
  local f = io.open(path, "w")
  if not f then return end
  f:write(contents or "")
  f:close()
end

local function dumpArtifact(info)
  if not hs.settings.get("claude_usage.dump_fetcher") then return end
  writeFile(DEBUG_DIR .. "/last-fetcher.json", hs.json.encode(info, true))
end

---------------------------------------------------------------------
-- Response → state shape
---------------------------------------------------------------------

local function makeWindow(d)
  if not d or type(d.utilization) ~= "number" then return nil end
  return {
    percentUsed = d.utilization,
    percentLeft = math.max(0, 100 - d.utilization),
    resetsAt    = isoToEpoch(d.resets_at),
    resetsHuman = nil,
  }
end

local function mapOverage(raw)
  if type(raw) ~= "table" then return nil end
  local cents = tonumber(raw.monthly_credit_limit)
  local used  = tonumber(raw.used_credits)
  return {
    isEnabled     = raw.is_enabled == true,
    monthlyLimit  = cents and (cents / 100) or nil,
    usedCredits   = used and (used / 100) or nil,
    utilization   = (cents and cents > 0 and used) and math.floor(used / cents * 100 + 0.5) or nil,
    currency      = raw.currency or "USD",
  }
end

local function mapResponse(info)
  local usage = info.usage
  if type(usage) ~= "table" then
    return {
      status = "error",
      errorMsg = "fetcher: unified_limits_utilization missing or not a table",
      warnings = {
        "Response shape changed — unified_limits_utilization.data was not an object",
        "Inspect Debug → Dump fetcher response; check debug/last-fetcher.json",
      },
    }
  end
  local five   = makeWindow(usage.five_hour)
  local weekly = makeWindow(usage.seven_day)
  if not five or not weekly then
    return {
      status = "error",
      errorMsg = "fetcher: missing five_hour/seven_day fields",
      warnings = {
        "API response shape changed — expected five_hour.utilization and seven_day.utilization",
        "Enable Debug → Dump fetcher response to see the raw shape",
      },
    }
  end
  return {
    status       = "ok",
    fiveHour     = five,
    weekly       = weekly,
    weeklySonnet = makeWindow(usage.seven_day_sonnet),
    weeklyOpus   = makeWindow(usage.seven_day_opus),
    weeklyHaiku  = makeWindow(usage.seven_day_haiku),
    account      = info.account,
    extraUsage   = mapOverage(info.overage),
    spend        = {},
    warnings     = {},
  }
end

---------------------------------------------------------------------
-- JS payload
---------------------------------------------------------------------

-- Walks the React fiber tree to find the QueryClient (cached on window.__cu),
-- refetches the two live queries in parallel, then reads the three queries we
-- care about and stashes the combined payload on window.__cu.lastFetch with
-- the supplied token (for read-poll ordering).
--
-- React hydration is async after didFinishNavigation, so the fiber walk is
-- wrapped in an internal setTimeout retry loop with a 6 s deadline.
local FETCH_JS_TEMPLATE = [[
(function(){
  var TOKEN = "%s";
  window.__cu = window.__cu || {};
  window.__cu.lastFetch = {stage:"starting", token: TOKEN};

  if (/\/(login|auth|sign-in)/.test(location.href)) {
    window.__cu.lastFetch = {stage:"done", token: TOKEN, needsLogin: true};
    return;
  }

  var deadline = Date.now() + 6000;

  function tryFindQc() {
    try {
      if (window.__cu.qc && window.__cu.qc.getQueryCache) return null; // already have it
      var root = document.getElementById("root");
      if (!root) return "no #root";
      var rkey = Object.keys(root).find(function(k){ return k.indexOf("__reactContainer") === 0; });
      if (!rkey) return "no __reactContainer";
      var fiber = root[rkey].stateNode && root[rkey].stateNode.current;
      if (!fiber) return "no fiber";
      var queue = [fiber], found = null, visited = 0;
      while (queue.length && !found && visited++ < 5000) {
        var n = queue.shift(); if (!n) continue;
        var mp = n.memoizedProps;
        if (mp && mp.client && mp.client.getQueryCache) found = mp.client;
        if (n.child) queue.push(n.child);
        if (n.sibling) queue.push(n.sibling);
      }
      if (!found) return "no QueryClient (visited " + visited + ")";
      window.__cu.qc = found;
      return null;
    } catch (e) {
      return "fiber walk: " + String(e);
    }
  }

  function readQuery(name) {
    var all = window.__cu.qc.getQueryCache().getAll();
    return all.find(function(q){
      return q.queryKey && q.queryKey[0] === name && q.queryKey.length === 2;
    });
  }

  function doRefetch() {
    var qc = window.__cu.qc;
    try {
      Promise.all([
        qc.refetchQueries({queryKey: ["unified_limits_utilization"]}),
        qc.refetchQueries({queryKey: ["overage_spend_limit"]}),
      ]).then(function(){
        try {
          var u = readQuery("unified_limits_utilization");
          var o = readQuery("overage_spend_limit");
          var a = readQuery("current_account");
          // Retry while the query is absent, still fetching, or has no data
          // yet. refetchQueries can resolve before the usage component has
          // mounted its query (Promise.all matches 0 and resolves instantly).
          var uStatus = u && u.state && u.state.status;
          var uHasData = !!(u && u.state && u.state.data);
          if (!u || uStatus === "pending" || uStatus === "fetching" || !uHasData) {
            if (Date.now() < deadline) { setTimeout(doRefetch, 200); return; }
            window.__cu.lastFetch = {stage:"done", token: TOKEN,
              err: "unified_limits_utilization not ready after 6s (status=" + uStatus + " hasData=" + uHasData + ")"};
            return;
          }
          if (uStatus === "error") {
            window.__cu.lastFetch = {stage:"done", token: TOKEN, err: "unified_limits_utilization state=error: " + String(u.state.error)};
            return;
          }
          var acct = null;
          if (a && a.state && a.state.data && a.state.data.account) {
            var d = a.state.data;
            var mem = (d.account.memberships || [])[0];
            acct = {
              email: d.account.email_address || null,
              fullName: d.account.full_name || null,
              orgUuid: mem && mem.organization && mem.organization.uuid || null,
              orgName: mem && mem.organization && mem.organization.name || null,
            };
          }
          window.__cu.lastFetch = {
            stage: "done", token: TOKEN,
            usage: u.state.data,
            overage: o && o.state && o.state.data || null,
            account: acct,
          };
        } catch (e) {
          window.__cu.lastFetch = {stage:"done", token: TOKEN, err: "extract: " + String(e)};
        }
      }).catch(function(e){
        window.__cu.lastFetch = {stage:"done", token: TOKEN, err: "refetch reject: " + String(e)};
      });
    } catch (e) {
      window.__cu.lastFetch = {stage:"done", token: TOKEN, err: "refetch throw: " + String(e)};
    }
  }

  function waitAndStart() {
    var err = tryFindQc();
    if (!window.__cu.qc) {
      if (Date.now() < deadline) { setTimeout(waitAndStart, 200); return; }
      window.__cu.lastFetch = {stage:"done", token: TOKEN, err: "SPA never mounted in 6s: " + (err || "unknown")};
      return;
    }
    doRefetch();
  }

  waitAndStart();
})()
]]

local READ_JS = "JSON.stringify(window.__cu && window.__cu.lastFetch || {stage:'none'})"

---------------------------------------------------------------------
-- Fetch orchestration
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

      dumpArtifact(info)

      if info.needsLogin then finish({ status = "needs_login" }); return end
      if info.err then
        log.e("fetcher: " .. info.err)
        finish({
          status = "error",
          errorMsg = "fetcher: " .. info.err,
          warnings = {
            "Fetcher path broken: " .. info.err,
            "Likely cause: SPA changed React internals, or a query key was renamed",
            "Debug: open Hammerspoon console; Debug → Copy state JSON",
          },
        })
        return
      end
      finish(mapResponse(info))
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

local function maybeSafetyReload(onContinue)
  local lastNav = scraper.lastNavAt()
  if lastNav <= 0 then return onContinue() end
  local now = hs.timer.secondsSinceEpoch()
  if now - lastNav < SAFETY_RELOAD_INTERVAL_S then return onContinue() end
  log.i(string.format("fetcher: %.0fs since last nav; running hygiene reload", now - lastNav))
  scraper.reload(function(ok, err)
    if not ok then log.w("safety reload failed: " .. tostring(err)) end
    onContinue()
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
    maybeSafetyReload(function() runOnce(onDone) end)
  end)
end

return M
