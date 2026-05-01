-- Persistent claude.ai webview + direct-HTTP fetch for the usage widget.
--
-- Data path: a single persistent hs.webview holds the authenticated
-- claude.ai session. On every tick we inject a tiny JS snippet that calls
-- the three endpoints the menu needs, same-origin (so session cookies
-- auto-attach), and stashes the combined payload on window.__cu.
--
-- Endpoints (verified against the real SPA's network traffic):
--   GET /api/account
--       → { uuid, email_address, full_name, memberships:[{organization:{uuid,name,..}}] }
--   GET /api/organizations/{orgUuid}/usage
--       → { five_hour, seven_day, seven_day_sonnet, seven_day_opus, seven_day_haiku, extra_usage, .. }
--   GET /api/organizations/{orgUuid}/overage_spend_limit
--       → { is_enabled, monthly_credit_limit, used_credits, currency, .. }
--
-- Active-org selection: the SPA stores the user's last-used org in the
-- `lastActiveOrg` cookie. We prefer that; fall back to memberships[0].
--
-- Login flow lives here too (interactiveLogin / logoutSoft / logoutHard /
-- clearCookies) because it's the same webview lifecycle — split would just
-- cost two requires and an import cycle.

local state = require("claude_usage.state")
local log = state.logger("data")

local M = {}

local HOME = os.getenv("HOME")
local TARGET_URL = "https://claude.ai/settings/usage"
local FETCH_TIMEOUT_S = 5          -- direct HTTP is ~300ms typical
local POLL_INTERVAL_S = 0.1
local DEBUG_DIR = HOME .. "/.hammerspoon/claude_usage/debug"

-- Safari 18 UA — Google OAuth treats stock WKWebView as a bot without this.
local SAFARI_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_6) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

-- Lua patterns DON'T support `|` alternation — "(login|logout)" matches the
-- literal 7-char string "login|logout", not either word. We iterate a list
-- instead. This was a latent bug: isAuthedUrl/isLoginUrl never matched,
-- so login success detection relied entirely on the side-channel probe
-- (3–5s slower than URL-based detection).
local LOGIN_PATHS  = { "login", "logout", "auth", "sign%-in", "signin" }
local AUTHED_PATHS = { "settings", "new", "chat", "recents", "home" }

local function pathMatchesAny(u, paths)
  for _, p in ipairs(paths) do
    if u:match("/" .. p .. "[%?/]") or u:match("/" .. p .. "$") then
      return true
    end
  end
  return false
end

local function isLoginUrl(u)
  if type(u) ~= "string" then return false end
  if not u:match("claude%.ai/") then return false end  -- host check: OAuth popups may land on /signin paths on other hosts
  return pathMatchesAny(u, LOGIN_PATHS)
end

-- A successful-login landing page on claude.ai. Excludes login/auth paths
-- because those can appear mid-flow before cookies land.
local function isAuthedUrl(u)
  if type(u) ~= "string" then return false end
  if not u:match("claude%.ai/") then return false end
  if pathMatchesAny(u, LOGIN_PATHS) then return false end
  return pathMatchesAny(u, AUTHED_PATHS)
end

---------------------------------------------------------------------
-- Webview lifecycle
---------------------------------------------------------------------

local persistentWV = nil
local pageState = "cold"   -- cold | loading | ready
local lastNavAt = 0
local pendingNav = nil     -- { onFinish = fn(ok, errOrNil) }
local loginWV = nil

local function resolveNav(ok, err)
  if not pendingNav then return end
  local cb = pendingNav.onFinish
  pendingNav = nil
  pageState = ok and "ready" or "cold"
  if cb then cb(ok, err) end
end

local function navigationCallback(action, _, navID, err)
  if action == "didFinishNavigation" then
    log.d("nav finish (navID=" .. tostring(navID) .. ")")
    resolveNav(true)
  elseif action == "didFailNavigation" or action == "didFailProvisionalNavigation" then
    local msg = "nav fail: " .. hs.inspect(err)
    log.e(msg); state.log("e", msg)
    resolveNav(false, msg)
  end
end

local function visibleMode()
  return state.get("debug_visible") == true
end

local function createPersistentWV()
  local visible = visibleMode()
  local rect = visible and { x = 120, y = 120, w = 820, h = 920 }
                        or { x = -9000, y = -9000, w = 900, h = 900 }
  local wv = hs.webview.new(rect, { developerExtrasEnabled = true, javaScriptEnabled = true })
  if not wv then return nil end
  if visible then
    wv:windowStyle({ "titled", "closable", "resizable" })
  else
    wv:windowStyle({ "borderless" })
  end
  wv:allowTextEntry(true)
  wv:navigationCallback(navigationCallback)
  wv:show()
  return wv
end

local function chainPendingNav(newCb)
  local prev = pendingNav.onFinish
  pendingNav.onFinish = function(ok, err)
    if prev then prev(ok, err) end
    newCb(ok, err)
  end
end

function M.runJS(js, cb)
  if not persistentWV then return cb and cb(nil, "no persistent webview") end
  persistentWV:evaluateJavaScript(js, cb or function() end)
end

function M.ensureLoaded(onReady)
  if pageState == "ready" and persistentWV then onReady(true); return end
  if pendingNav then chainPendingNav(onReady); return end
  if not persistentWV then
    persistentWV = createPersistentWV()
    if not persistentWV then onReady(false, "hs.webview.new returned nil"); return end
  end
  pageState = "loading"
  lastNavAt = hs.timer.secondsSinceEpoch()
  pendingNav = { onFinish = onReady }
  log.i("ensureLoaded: navigating")
  persistentWV:url(TARGET_URL)
end

function M.reload(onReady)
  if not persistentWV then return M.ensureLoaded(onReady) end
  if pendingNav then chainPendingNav(onReady); return end
  pageState = "loading"
  lastNavAt = hs.timer.secondsSinceEpoch()
  pendingNav = { onFinish = onReady }
  log.i("reload: wv:reload()")
  persistentWV:reload()
end

function M.destroyPersistent()
  if persistentWV then
    pcall(function() persistentWV:delete() end)
    log.i("persistent webview destroyed")
    state.log("i", "persistent webview destroyed")
  end
  persistentWV = nil
  pageState = "cold"
  lastNavAt = 0
  pendingNav = nil
end

function M.pageState() return pageState end
function M.hasPersistent() return persistentWV ~= nil end
function M.lastNavAt() return lastNavAt end

function M.debugState()
  local now = hs.timer.secondsSinceEpoch()
  return {
    persistentWV    = persistentWV ~= nil,
    pageState       = pageState,
    lastNavAt       = lastNavAt,
    secondsSinceNav = lastNavAt > 0 and math.floor(now - lastNavAt) or nil,
    pendingNav      = pendingNav ~= nil,
  }
end

---------------------------------------------------------------------
-- Response shape transforms
---------------------------------------------------------------------

local function utcOffset()
  local now = os.time()
  return os.difftime(now, os.time(os.date("!*t", now)))
end

local function isoToEpoch(iso)
  if not iso or type(iso) ~= "string" then return nil end
  local y, mo, d, h, mi, s = iso:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then return nil end
  return os.time({
    year = tonumber(y), month = tonumber(mo), day = tonumber(d),
    hour = tonumber(h), min = tonumber(mi), sec = tonumber(s),
  }) + utcOffset()
end

local function makeWindow(d)
  if not d or type(d.utilization) ~= "number" then return nil end
  return {
    percentUsed = d.utilization,
    percentLeft = math.max(0, 100 - d.utilization),
    resetsAt    = isoToEpoch(d.resets_at),
  }
end

local function mapOverage(raw)
  if type(raw) ~= "table" then return nil end
  local cents = tonumber(raw.monthly_credit_limit)
  local used  = tonumber(raw.used_credits)
  return {
    isEnabled    = raw.is_enabled == true,
    monthlyLimit = cents and (cents / 100) or nil,
    usedCredits  = used and (used / 100) or nil,
    utilization  = (cents and cents > 0 and used) and math.floor(used / cents * 100 + 0.5) or nil,
    currency     = raw.currency or "USD",
  }
end

local function mapResponse(info)
  local usage = info.usage
  if type(usage) ~= "table" then
    return {
      status = "error",
      errorMsg = "fetcher: usage response missing or not a table",
      warnings = {
        "Response shape changed — /api/organizations/{uuid}/usage did not return an object",
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
-- Fetch path
---------------------------------------------------------------------

local function writeFile(path, contents)
  hs.fs.mkdir(DEBUG_DIR)
  local f = io.open(path, "w"); if not f then return end
  f:write(contents or ""); f:close()
end

local function dumpArtifact(info)
  if not state.get("dump_fetcher") then return end
  writeFile(DEBUG_DIR .. "/last-fetcher.json", hs.json.encode(info, true))
end

-- JS snippet: three same-origin fetches, result on window.__cu.lastFetch.
-- Same-origin so credentials:'include' attaches the session cookie auto.
-- Active-org picked from the lastActiveOrg cookie (falls back to memberships[0]).
local FETCH_JS_TEMPLATE = [[
(function(){
  var TOKEN = "%s";
  window.__cu = window.__cu || {};
  window.__cu.lastFetch = {stage:"starting", token: TOKEN};

  function isLoginUrl() {
    return /\/(login|logout|auth|sign-in|signin)(\?|$|\/)/.test(location.href);
  }
  if (isLoginUrl()) {
    window.__cu.lastFetch = {stage:"done", token: TOKEN, needsLogin: true};
    return;
  }

  function cookie(name) {
    var m = document.cookie.match(new RegExp("(?:^|; )" + name + "=([^;]*)"));
    return m ? decodeURIComponent(m[1]) : null;
  }

  fetch("/api/account", { credentials: "include" })
    .then(function(r){
      if (r.status === 401 || r.status === 403) return null;
      return r.json();
    })
    .then(function(account){
      if (!account) {
        window.__cu.lastFetch = {stage:"done", token: TOKEN, needsLogin: true};
        return;
      }
      var ms = account.memberships || [];
      var activeUuid = cookie("lastActiveOrg");
      var orgUuid = null, orgName = null;
      if (activeUuid) {
        for (var i = 0; i < ms.length; i++) {
          var m = ms[i];
          if (m && m.organization && m.organization.uuid === activeUuid) {
            orgUuid = m.organization.uuid; orgName = m.organization.name; break;
          }
        }
      }
      if (!orgUuid && ms[0] && ms[0].organization) {
        orgUuid = ms[0].organization.uuid; orgName = ms[0].organization.name;
      }
      if (!orgUuid) throw new Error("no org uuid on memberships");

      var acct = {
        email: account.email_address || null,
        fullName: account.full_name || null,
        orgUuid: orgUuid,
        orgName: orgName,
      };

      return Promise.all([
        fetch("/api/organizations/" + orgUuid + "/usage",               { credentials:"include" }).then(function(r){ return r.json(); }),
        fetch("/api/organizations/" + orgUuid + "/overage_spend_limit", { credentials:"include" }).then(function(r){ return r.json(); }),
      ]).then(function(vals){
        window.__cu.lastFetch = {
          stage:"done", token: TOKEN,
          usage: vals[0], overage: vals[1], account: acct,
        };
      });
    })
    .catch(function(e){
      window.__cu.lastFetch = {stage:"done", token: TOKEN, err: String(e)};
    });
})()
]]

-- Read both window.__cu.lastFetch AND the URL, so we can detect mid-fetch
-- navigation to /login (which wipes window.__cu).
local READ_JS = [[JSON.stringify({
  fetch: (window.__cu && window.__cu.lastFetch) || null,
  url: location.href,
})]]

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

  M.runJS(fetchJs, function() end)

  local pollTimer, timeoutTimer
  local done = false
  local lastUrl = nil

  pollTimer = hs.timer.doEvery(POLL_INTERVAL_S, function()
    if done then if pollTimer then pollTimer:stop(); pollTimer = nil end; return end
    M.runJS(READ_JS, function(resultStr)
      if done or not resultStr then return end
      local ok, decoded = pcall(hs.json.decode, resultStr)
      if not ok or type(decoded) ~= "table" then return end

      if isLoginUrl(decoded.url) then
        done = true
        if pollTimer then pollTimer:stop(); pollTimer = nil end
        if timeoutTimer then timeoutTimer:stop(); timeoutTimer = nil end
        finish({ status = "needs_login" })
        return
      end

      if decoded.fetch == nil then
        if lastUrl and decoded.url ~= lastUrl then
          log.i("fetcher: page navigated (" .. tostring(lastUrl) .. " -> " .. tostring(decoded.url) .. "), re-injecting")
        end
        lastUrl = decoded.url
        M.runJS(fetchJs, function() end)
        return
      end
      lastUrl = decoded.url

      local info = decoded.fetch
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
            "Direct /api fetch failed: " .. info.err,
            "Likely cause: endpoint moved or session invalidated",
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

function M.fetch(onDone)
  M.ensureLoaded(function(ok, err)
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
    runOnce(onDone)
  end)
end

---------------------------------------------------------------------
-- Login + cookies
---------------------------------------------------------------------

local function loginLog(fmt, ...)
  local line = "[loginWV] " .. string.format(fmt, ...)
  log.i(line); state.log("i", line)
end

-- Single canonical UA-setter + level-setter on this Hammerspoon version.
-- The previous defensive 3-way fallbacks stayed after we picked these.
local function setUA(wv, ua)
  pcall(function() wv:setCustomUserAgent(ua) end)
end
local function setNormalWindowLevel(wv)
  pcall(function() wv:level(hs.drawing.windowLevels.normal) end)
end

function M.interactiveLogin(onClosed)
  if loginWV then loginWV:show():bringToFront(); return end
  loginLog("open")
  loginWV = hs.webview.new(
    { x = 160, y = 140, w = 820, h = 900 },
    { developerExtrasEnabled = true, javaScriptEnabled = true }
  )
  if not loginWV then loginLog("hs.webview.new returned nil"); return end

  loginWV:windowStyle({ "titled", "closable", "resizable", "miniaturizable" })
  loginWV:allowTextEntry(true)
  loginWV:windowTitle("Log in to claude.ai")
  loginWV:allowNewWindows(true)
  setNormalWindowLevel(loginWV)
  setUA(loginWV, SAFARI_UA)

  local done = false
  local oauthPopup = nil
  local function onLoginSuccess(reason)
    if done then return end
    done = true
    loginLog("success (%s)", reason)
    pageState = "cold"
    if loginWV then pcall(function() loginWV:delete() end); loginWV = nil end
    if oauthPopup then pcall(function() oauthPopup:delete() end); oauthPopup = nil end
    -- Destroy persistent WV so next fetch navigates cleanly with new cookies.
    M.destroyPersistent()
    -- The loginWV had focus, which made Hammerspoon the active app.
    -- Deleting it leaves the app with no visible window, and macOS
    -- falls back to the Hammerspoon console. Close it preemptively —
    -- no-op if the user never had it open.
    pcall(function() hs.closeConsole() end)
    if onClosed then
      hs.timer.doAfter(0.4, onClosed)  -- debounce past loginWV teardown
    end
  end

  -- newWindow policy: OAuth popups (Google / Apple) need a live child WV
  -- with our cookies; otherwise the provider SDK can't postMessage the auth
  -- code back to the opener and the page hangs on "One moment please…".
  loginWV:policyCallback(function(action, newWV, details, features)
    local reqURL = details and details.request and details.request.URL or "?"
    if action == "newWindow" then
      loginLog("policy newWindow → %s ALLOW", reqURL)
      if newWV then
        if oauthPopup then pcall(function() oauthPopup:delete() end); oauthPopup = nil end
        oauthPopup = newWV
        local fx = (features and features.x) or 240
        local fy = (features and features.y) or 160
        local fw = (features and features.w) or 500
        local fh = (features and features.h) or 600
        pcall(function() newWV:frame({ x = fx, y = fy, w = fw, h = fh }) end)
        pcall(function() newWV:windowStyle({ "titled", "closable", "resizable", "miniaturizable" }) end)
        pcall(function() newWV:windowTitle("Sign in — OAuth provider") end)
        setNormalWindowLevel(newWV)
        pcall(function() newWV:allowTextEntry(true) end)
        pcall(function()
          newWV:windowCallback(function(wact)
            loginLog("popup window %s", tostring(wact))
            if wact == "closing" then oauthPopup = nil end
          end)
        end)
        pcall(function()
          newWV:navigationCallback(function(nact, nwv, _, nerr)
            local nu = nwv and nwv:url() or "?"
            loginLog("popup nav %s url=%s err=%s", tostring(nact), tostring(nu), tostring(nerr))
          end)
        end)
        pcall(function() newWV:show() end)
        pcall(function() newWV:bringToFront() end)
      end
      return true
    end
    loginLog("policy %s url=%s", tostring(action), reqURL)
    return true
  end)

  -- err is a table ({code, domain, description}); stringify via hs.inspect
  -- so the -999 match actually hits. NSURLError -999 fires when claude.ai's
  -- SPA-level redirect chain (/settings/usage → /logout → /login) races
  -- the provisional nav. WKWebView paints a built-in error page in that
  -- window — recover by loading /login directly.
  loginWV:navigationCallback(function(action, wv, navID, err)
    local u = wv and wv:url() or "?"
    local errStr = err and hs.inspect(err):gsub("\n", " ") or "nil"
    loginLog("nav %s navID=%s url=%s err=%s", tostring(action), tostring(navID), tostring(u), errStr)
    if action == "didFinishNavigation" and isAuthedUrl(u) then
      onLoginSuccess("authed url: " .. u)
      return
    end
    if action == "didFailNavigation" or action == "didFailProvisionalNavigation" then
      if errStr:find("-999") or errStr:find("NSURLErrorCancelled") or errStr:find("NSURLErrorDomain") then
        loginLog("nav -999 (cancelled); recovering by loading /login")
        pcall(function() wv:url("https://claude.ai/login") end)
      end
    end
  end)

  loginWV:windowCallback(function(action)
    loginLog("window %s", tostring(action))
    if action == "closing" then onLoginSuccess("window closed") end
  end)

  -- Side-channel probe. Google's GSI flow often leaves the visible page
  -- stuck on "One moment please…" inside a WKWebView, but an XHR to
  -- claude.ai still redeems the auth code server-side and the session
  -- cookie lands. A hidden probe fetch detects that.
  local urlTick, lastTickURL, tickCount, probing, probeWV = nil, nil, 0, false, nil

  local function runProbe()
    if probing or done or not loginWV then return end
    probing = true
    probeWV = hs.webview.new({ x = -9000, y = -9000, w = 400, h = 400 }, { javaScriptEnabled = true })
    if not probeWV then probing = false; return end
    probeWV:windowStyle({ "borderless" })
    setUA(probeWV, SAFARI_UA)
    local teardown = function()
      if probeWV then pcall(function() probeWV:delete() end); probeWV = nil end
      probing = false
    end
    probeWV:navigationCallback(function(action, wv)
      if done then teardown(); return end
      if action == "didFinishNavigation" then
        local purl = wv and wv:url() or ""
        if purl:match("/login") then
          loginLog("probe redirected to /login — unauthed"); teardown(); return
        end
        -- /api/organizations responds:
        --   authed   → 200, body starts with '[' (JSON array)
        --   unauthed → 200, body '{"type":"error","error":{"error_code":"account_session_invalid"...}}'
        wv:evaluateJavaScript(
          "document.body && document.body.innerText ? document.body.innerText.slice(0,200) : ''",
          function(body)
            if done then teardown(); return end
            body = type(body) == "string" and body or ""
            local authed = body:sub(1, 1) == "[" and not body:match("account_session_invalid")
            loginLog("probe body[0..200]=%q authed=%s", body:sub(1, 160), tostring(authed))
            if authed then
              onLoginSuccess("probe authed via " .. purl)
              if urlTick then urlTick:stop(); urlTick = nil end
            end
            teardown()
          end)
      elseif action == "didFailNavigation" or action == "didFailProvisionalNavigation" then
        loginLog("probe nav failed action=%s", tostring(action))
        teardown()
      end
    end)
    probeWV:url("https://claude.ai/api/organizations")
    probeWV:show()  -- JS pauses in never-shown WVs; off-screen+shown avoids that
  end

  urlTick = hs.timer.doEvery(1, function()
    if done or not loginWV then
      if urlTick then urlTick:stop(); urlTick = nil end
      if probeWV then pcall(function() probeWV:delete() end); probeWV = nil end
      return
    end
    tickCount = tickCount + 1
    local u = loginWV:url() or "?"
    if u ~= lastTickURL then loginLog("tick url=%s", u); lastTickURL = u end
    if isAuthedUrl(u) then
      onLoginSuccess("tick authed url: " .. u)
      if urlTick then urlTick:stop(); urlTick = nil end
      return
    end
    -- Start probing at tick 3, every 5s thereafter.
    if tickCount >= 3 and (tickCount % 5) == 0 then runProbe() end
  end)

  -- Start at /login directly. TARGET_URL (/settings/usage) forces claude.ai
  -- into a /settings/usage → /logout → /login redirect chain that races
  -- the WKWebView provisional nav and emits NSURLError -999.
  loginWV:url("https://claude.ai/login")
  loginWV:show()
  -- Focus just the login window. Previously we used
  -- hs.application.launchOrFocus("Hammerspoon"), which activates the whole
  -- app and, on some setups, re-opens the Hammerspoon console as a side
  -- effect. hswindow():focus() brings only the login WV forward.
  pcall(function()
    local w = loginWV:hswindow()
    if w then w:focus() end
  end)
  loginLog("shown; initial url=%s", loginWV:url() or "?")
end

local function rmSync(path)
  local out, ok, _, rc = hs.execute("/bin/rm -rf " .. string.format("%q", path))
  log.i(string.format("rm -rf %s rc=%s ok=%s", path, tostring(rc), tostring(ok)))
  return ok, out
end

-- Every path WebKit uses for per-app session state.
local function webkitPaths()
  return {
    HOME .. "/Library/WebKit/org.hammerspoon.Hammerspoon",
    HOME .. "/Library/HTTPStorages/org.hammerspoon.Hammerspoon",
    HOME .. "/Library/HTTPStorages/org.hammerspoon.Hammerspoon.binarycookies",
    HOME .. "/Library/Caches/org.hammerspoon.Hammerspoon",
  }
end

function M.clearCookies()
  log.w("clearCookies: wiping Hammerspoon WebKit data (relaunch Hammerspoon after)")
  state.log("w", "cookies cleared (relaunch Hammerspoon)")
  for _, p in ipairs(webkitPaths()) do rmSync(p) end
end

-- Soft logout: POST /api/auth/logout. The SPA's actual logout mutation.
-- GET /logout is just a client-side route that redirects without clearing
-- the server-side session. Tested: before=200 → POST=200 {success:true} →
-- after=403 account_session_invalid.
function M.logoutSoft(onDone)
  log.i("logoutSoft: POST /api/auth/logout")
  state.log("i", "logout (soft) requested")
  if not persistentWV then
    log.w("logoutSoft: no persistent WV; nothing to do")
    if onDone then onDone() end
    return
  end

  local function destroy()
    M.destroyPersistent()
    if onDone then onDone() end
  end

  local function doLogout()
    local js = [[
      (function(){
        window.__cu_logout_result = 'pending';
        fetch('/api/auth/logout', {
          method: 'POST',
          credentials: 'include',
          headers: {'Content-Type': 'application/json'},
          body: '{}'
        })
        .then(function(r){ window.__cu_logout_result = 'http:' + r.status; })
        .catch(function(e){ window.__cu_logout_result = 'err:' + String(e); });
      })()
    ]]
    persistentWV:evaluateJavaScript(js, function() end)
    hs.timer.doAfter(1.2, function()
      persistentWV:evaluateJavaScript(
        "String(window.__cu_logout_result || 'missing')",
        function(status)
          log.i("logoutSoft: " .. tostring(status))
          state.log("i", "logout result: " .. tostring(status))
          destroy()
        end)
    end)
  end

  if pendingNav then chainPendingNav(function() doLogout() end) else doLogout() end
end

-- Hard logout: nuke WebKit data store + relaunch Hammerspoon. Reserved for
-- "wipe all identity state" (shared machine, privacy reset). Kills any
-- Google/Apple/GitHub SSO cookies too.
--
-- Relaunch via detached shell script (reparented to launchd) because
-- os.exit(0) alone was unreliable — if skipped, `open -a Hammerspoon`
-- just re-focuses the still-running app.
function M.logoutHard()
  log.i("logoutHard: destroying webview + wiping cookies + force-relaunching")
  state.log("i", "logout (hard) requested")
  M.destroyPersistent()
  for _, p in ipairs(webkitPaths()) do rmSync(p) end

  local quotedRms = {}
  for _, p in ipairs(webkitPaths()) do
    table.insert(quotedRms, "/bin/rm -rf " .. string.format("%q", p))
  end
  local script = table.concat({
    "sleep 0.8",
    "killall Hammerspoon 2>/dev/null",
    "sleep 1",
    table.concat(quotedRms, "; "),
    "/usr/bin/open -a Hammerspoon",
  }, "; ")
  log.i("logoutHard: scheduling " .. script)
  hs.execute("nohup /bin/bash -c " .. string.format("%q", script)
          .. " >/tmp/claude_usage_logout.log 2>&1 &")
  hs.alert.show("Hard logout — Hammerspoon will relaunch")
end

-- Alias kept for backward compat with any external caller.
M.logout = M.logoutSoft

---------------------------------------------------------------------
-- Provider interface (consumed by menubar.lua)
---------------------------------------------------------------------

-- Fields wiped before each fetch so a stale value (e.g. earlier errorMsg)
-- from a prior tick never bleeds into a later successful tick.
local FETCH_KEYS = {
  "fiveHour", "weekly", "weeklySonnet", "weeklyOpus", "weeklyHaiku",
  "spend", "account", "extraUsage", "warnings", "errorMsg",
}

function M.providerFetch(cb)
  M.fetch(function(parsed)
    for _, k in ipairs(FETCH_KEYS) do state.data[k] = nil end
    for k, v in pairs(parsed) do state.data[k] = v end
    if cb then cb() end
  end)
end

-- Flip Extra usage via direct PUT /api/organizations/<uuid>/overage_spend_limit.
-- Moved from menubar.lua so the provider owns its Claude-specific mutations.
-- onSuccess fires after the PUT lands so the menubar can refresh + re-render.
local TOGGLE_EXTRA_JS_TEMPLATE = [[
(function(){
  var TOKEN = "%s";
  var ORG = "%s";
  var desired = %s;
  window.__cu_toggle = {stage:"starting", token: TOKEN};
  fetch("/api/organizations/" + ORG + "/overage_spend_limit", {
    method: "PUT",
    headers: {"content-type": "application/json"},
    credentials: "include",
    body: JSON.stringify({is_enabled: desired}),
  }).then(function(r){
    return r.text().then(function(body){
      var parsed = null; try { parsed = JSON.parse(body); } catch (e) {}
      var ok = r.status === 200 && parsed && parsed.is_enabled === desired;
      window.__cu_toggle = {
        stage:"done", token: TOKEN,
        ok: ok, status: r.status, desired: desired,
        actual: parsed && parsed.is_enabled,
        bodySnippet: body.slice(0, 200),
      };
    });
  }).catch(function(e){
    window.__cu_toggle = {stage:"done", token: TOKEN, err: "fetch_err: " + String(e)};
  });
})()
]]
local TOGGLE_READ_JS = "JSON.stringify(window.__cu_toggle || {stage:'none'})"

function M.toggleExtraUsage(onSuccess)
  local acct = state.data.account
  local orgUuid = acct and acct.orgUuid
  if not orgUuid then
    hs.alert.show("Toggle blocked: no orgUuid yet - refresh first")
    return
  end
  local before = state.data.extraUsage and state.data.extraUsage.isEnabled
  local desired = not before
  log.i("toggle extra usage: " .. tostring(before) .. " → " .. tostring(desired))
  hs.alert.show("Extra usage: updating to " .. (desired and "on" or "off") .. "…", 2)
  local token = string.format("%d_%d", os.time(), math.random(1000000))
  local js = string.format(TOGGLE_EXTRA_JS_TEMPLATE, token, orgUuid, tostring(desired))
  M.runJS(js, function() end)

  local tries = 0
  local poll
  poll = hs.timer.doEvery(0.2, function()
    tries = tries + 1
    if tries > 75 then
      poll:stop()
      log.w("toggle poll timed out; refreshing to confirm actual state")
      if onSuccess then onSuccess() end
      return
    end
    M.runJS(TOGGLE_READ_JS, function(resultStr)
      if not resultStr then return end
      local ok, info = pcall(hs.json.decode, resultStr)
      if not ok or type(info) ~= "table" then return end
      if info.stage ~= "done" or info.token ~= token then return end
      poll:stop()
      log.i("toggle result: " .. hs.inspect(info))
      state.log("i", "extra_usage PUT → " .. hs.json.encode(info))
      if not info.ok then
        hs.alert.show("Extra usage toggle failed (HTTP " .. tostring(info.status or "?") .. ")")
        state.data.warnings = state.data.warnings or {}
        table.insert(state.data.warnings,
          "Extra usage PUT failed: " .. (info.err or ("status=" .. tostring(info.status)))
          .. " · desired=" .. tostring(desired) .. " · actual=" .. tostring(info.actual))
        if onSuccess then onSuccess() end
        return
      end
      if state.data.extraUsage then state.data.extraUsage.isEnabled = desired end
      hs.alert.show("Extra usage " .. (desired and "on" or "off"))
      if onSuccess then onSuccess() end
    end)
  end)
end

function M.makeProvider()
  return {
    id = "claude",
    loginLabel = "claude.ai",
    openSettingsLabel = "claude.ai/settings/usage",
    openSettingsUrl = "https://claude.ai/settings/usage",
    hasExtraUsage = true,

    getState = function() return state.data end,
    fetch    = M.providerFetch,
    login    = M.interactiveLogin,
    logout   = M.logoutSoft,
    logoutHard = M.logoutHard,
    toggleExtraUsage = M.toggleExtraUsage,

    runJS = M.runJS,
    reload = M.reload,
    destroyPersistent = M.destroyPersistent,
    debugState = M.debugState,
    clearCookies = M.clearCookies,
  }
end

return M
