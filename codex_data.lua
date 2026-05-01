-- Persistent chatgpt.com webview + direct-HTTP fetch for the Codex usage widget.
--
-- Mirrors data.lua's pattern but for OpenAI's Codex Cloud rate limits.
--
-- Endpoint:
--   GET /backend-api/wham/usage
--     → { email, plan_type,
--         rate_limit:{ primary_window:{used_percent,reset_at,..},
--                      secondary_window:{...} },
--         additional_rate_limits:[{ limit_name, rate_limit:{primary,secondary} }],
--         credits:{...}, spend_control:{...} }
--
-- Auth: shares chatgpt.com session cookies in the persistent webview. Same
-- credentials:'include' fetch pattern as Claude. The API returns "used_percent"
-- (not "remaining") so no inversion is needed - shape maps directly to Claude's
-- { percentUsed, percentLeft, resetsAt } window structure.

local state = require("claude_usage.state")
local log = state.logger("codex_data")

local M = {}

local HOME = os.getenv("HOME")
local TARGET_URL = "https://chatgpt.com/codex/cloud/settings/analytics"
local LOGIN_URL = "https://chatgpt.com/"
local FETCH_TIMEOUT_S = 5
local POLL_INTERVAL_S = 0.1
local DEBUG_DIR = HOME .. "/.hammerspoon/claude_usage/codex_debug"
local SAFARI_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_6) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

---------------------------------------------------------------------
-- Webview lifecycle
---------------------------------------------------------------------

local persistentWV = nil
local pageState = "cold"
local lastNavAt = 0
local pendingNav = nil
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
  return state.get("codex_debug_visible") == true
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
  pcall(function() wv:setCustomUserAgent(SAFARI_UA) end)
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
    state.log("i", "codex persistent webview destroyed")
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

local function makeWindow(w)
  if not w or type(w.used_percent) ~= "number" then return nil end
  return {
    percentUsed = w.used_percent,
    percentLeft = math.max(0, 100 - w.used_percent),
    resetsAt    = w.reset_at,  -- already epoch seconds
  }
end

local function mapResponse(info)
  local u = info.usage
  if type(u) ~= "table" then
    return {
      status = "error",
      errorMsg = "codex: usage response missing or not a table",
      warnings = { "API shape changed - /backend-api/wham/usage did not return an object" },
    }
  end
  local rl = u.rate_limit
  if type(rl) ~= "table" then
    return {
      status = "error",
      errorMsg = "codex: rate_limit field missing",
      warnings = { "API shape changed - rate_limit field missing on /backend-api/wham/usage" },
    }
  end
  local fiveHour = makeWindow(rl.primary_window)
  local weekly   = makeWindow(rl.secondary_window)
  if not fiveHour or not weekly then
    return {
      status = "error",
      errorMsg = "codex: missing primary_window/secondary_window",
      warnings = { "API shape changed - expected primary_window.used_percent and secondary_window.used_percent" },
    }
  end

  -- additional_rate_limits is a list of per-model windows (e.g. GPT-5.3-Codex-Spark).
  -- Map each to { label, fiveHour, weekly } so the menubar can render them as
  -- extra weekly blocks analogous to Claude's "1w · Sonnet only".
  local additional = {}
  if type(u.additional_rate_limits) == "table" then
    for _, arl in ipairs(u.additional_rate_limits) do
      local n = arl.rate_limit
      if type(n) == "table" then
        table.insert(additional, {
          label    = arl.limit_name or "additional",
          fiveHour = makeWindow(n.primary_window),
          weekly   = makeWindow(n.secondary_window),
        })
      end
    end
  end

  return {
    status   = "ok",
    fiveHour = fiveHour,
    weekly   = weekly,
    additional = additional,
    account = {
      email   = u.email,
      orgName = u.plan_type and ("Plan: " .. u.plan_type) or nil,
    },
    warnings = {},
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
  if not state.get("codex_dump_fetcher") then return end
  writeFile(DEBUG_DIR .. "/last-fetcher.json", hs.json.encode(info, true))
end

-- Two same-origin fetches: /api/auth/session (cookie auth, returns the JWT
-- accessToken) → /backend-api/wham/usage (needs `Authorization: Bearer <jwt>`).
-- Cookies alone don't authenticate /backend-api/* - the React app uses the
-- access token from the NextAuth session response.
local FETCH_JS_TEMPLATE = [[
(function(){
  var TOKEN = "%s";
  window.__cu_codex = window.__cu_codex || {};
  window.__cu_codex.lastFetch = {stage:"starting", token: TOKEN};

  fetch("/api/auth/session", { credentials: "include" })
    .then(function(r){ return r.json(); })
    .then(function(sess){
      if (!sess || !sess.accessToken) {
        window.__cu_codex.lastFetch = {stage:"done", token: TOKEN, needsLogin: true};
        return null;
      }
      return fetch("/backend-api/wham/usage", {
        credentials: "include",
        headers: { "Authorization": "Bearer " + sess.accessToken },
      }).then(function(r){
        if (r.status === 401 || r.status === 403) {
          window.__cu_codex.lastFetch = {stage:"done", token: TOKEN, needsLogin: true};
          return null;
        }
        return r.json().then(function(usage){
          window.__cu_codex.lastFetch = {stage:"done", token: TOKEN, usage: usage};
        });
      });
    })
    .catch(function(e){
      window.__cu_codex.lastFetch = {stage:"done", token: TOKEN, err: String(e)};
    });
})()
]]

local READ_JS = [[JSON.stringify({
  fetch: (window.__cu_codex && window.__cu_codex.lastFetch) || null,
  url: location.href,
})]]

local function isLoginUrl(u)
  if type(u) ~= "string" then return false end
  -- chatgpt.com keeps the login dialog overlaid on / so URL doesn't change
  -- on session loss. We mostly rely on the fetch's 401/403 to detect it.
  -- These paths are still useful for detecting an active OAuth bounce.
  if u:match("/auth/login") or u:match("/auth/signin") or u:match("/auth/signout") then
    return true
  end
  return false
end

local function runOnce(onDone)
  local t0 = hs.timer.secondsSinceEpoch()
  local token = string.format("%d_%d", os.time(), math.random(1000000))
  local fetchJs = FETCH_JS_TEMPLATE:format(token)

  local function finish(parsed)
    local dt = math.floor((hs.timer.secondsSinceEpoch() - t0) * 1000)
    state.recordTiming(dt)
    if state.codexData then state.codexData.fetchTiming = { totalMs = dt } end
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
          log.i("fetcher: page navigated, re-injecting")
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
            "Direct /backend-api/wham/usage fetch failed: " .. info.err,
            "Likely cause: endpoint moved or session invalidated",
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
        "Codex fetcher exceeded " .. FETCH_TIMEOUT_S .. "s - page may be unresponsive",
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
        warnings = { "Persistent WebKit view failed to load /codex/cloud/settings/analytics" },
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
  local line = "[codex loginWV] " .. string.format(fmt, ...)
  log.i(line); state.log("i", line)
end

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
  loginWV:windowTitle("Log in to chatgpt.com (Codex)")
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
    M.destroyPersistent()
    pcall(function() hs.closeConsole() end)
    if onClosed then
      hs.timer.doAfter(0.4, onClosed)
    end
  end

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
        pcall(function() newWV:windowTitle("Sign in - OAuth provider") end)
        setNormalWindowLevel(newWV)
        setUA(newWV, SAFARI_UA)
        pcall(function() newWV:allowTextEntry(true) end)
        pcall(function()
          newWV:windowCallback(function(wact)
            if wact == "closing" then oauthPopup = nil end
          end)
        end)
        pcall(function() newWV:show() end)
        pcall(function() newWV:bringToFront() end)
      end
      return true
    end
    return true
  end)

  loginWV:windowCallback(function(action)
    loginLog("window %s", tostring(action))
    if action == "closing" then onLoginSuccess("window closed") end
  end)

  -- Side-channel probe: hit /api/auth/session (NextAuth, cookie-authed).
  -- Authed → 200 + JSON containing accessToken + user fields. Unauthed → {}.
  -- URL-based detection won't work because chatgpt.com keeps the login dialog
  -- overlaid on / so the URL doesn't change on session loss.
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
        wv:evaluateJavaScript(
          "document.body && document.body.innerText ? document.body.innerText.slice(0,300) : ''",
          function(body)
            if done then teardown(); return end
            body = type(body) == "string" and body or ""
            local authed = body:match('"accessToken"%s*:%s*"') ~= nil
            loginLog("probe body[0..160]=%q authed=%s", body:sub(1, 160), tostring(authed))
            if authed then
              onLoginSuccess("probe authed")
              if urlTick then urlTick:stop(); urlTick = nil end
            end
            teardown()
          end)
      elseif action == "didFailNavigation" or action == "didFailProvisionalNavigation" then
        loginLog("probe nav failed action=%s", tostring(action))
        teardown()
      end
    end)
    probeWV:url("https://chatgpt.com/api/auth/session")
    probeWV:show()
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
    if tickCount >= 3 and (tickCount % 5) == 0 then runProbe() end
  end)

  loginWV:url(LOGIN_URL)
  loginWV:show()
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
  state.log("w", "codex cookies cleared (relaunch Hammerspoon)")
  for _, p in ipairs(webkitPaths()) do rmSync(p) end
end

-- Soft logout: NextAuth-style POST. Untested at write time - the actual
-- chatgpt.com logout endpoint wasn't observed during inspection. If this
-- 404s the persistent WV gets destroyed anyway, so the client side clears.
-- Server-side session may persist; user can hard-logout to fully wipe.
function M.logoutSoft(onDone)
  log.i("logoutSoft: POST /api/auth/signout (NextAuth)")
  state.log("i", "codex logout (soft) requested")
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
        window.__cu_codex_logout = 'pending';
        fetch('/api/auth/signout', {
          method: 'POST',
          credentials: 'include',
          headers: {'Content-Type': 'application/json'},
          body: '{}'
        })
        .then(function(r){ window.__cu_codex_logout = 'http:' + r.status; })
        .catch(function(e){ window.__cu_codex_logout = 'err:' + String(e); });
      })()
    ]]
    persistentWV:evaluateJavaScript(js, function() end)
    hs.timer.doAfter(1.2, function()
      if persistentWV then
        persistentWV:evaluateJavaScript(
          "String(window.__cu_codex_logout || 'missing')",
          function(status)
            log.i("logoutSoft: " .. tostring(status))
            state.log("i", "codex logout result: " .. tostring(status))
            destroy()
          end)
      else
        destroy()
      end
    end)
  end

  if pendingNav then chainPendingNav(function() doLogout() end) else doLogout() end
end

function M.logoutHard()
  log.i("logoutHard: destroying webview + wiping cookies + force-relaunching")
  state.log("i", "codex logout (hard) requested")
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
  hs.execute("nohup /bin/bash -c " .. string.format("%q", script)
          .. " >/tmp/codex_usage_logout.log 2>&1 &")
  hs.alert.show("Hard logout - Hammerspoon will relaunch")
end

M.logout = M.logoutSoft

---------------------------------------------------------------------
-- Provider interface (consumed by menubar.lua)
---------------------------------------------------------------------

-- Fields wiped before each fetch so a stale errorMsg/warnings from a prior
-- tick doesn't bleed into a successful tick.
local FETCH_KEYS = {
  "fiveHour", "weekly", "additional", "account", "warnings", "errorMsg",
}

function M.providerFetch(cb)
  M.fetch(function(parsed)
    state.codexData = state.codexData or {}
    for _, k in ipairs(FETCH_KEYS) do state.codexData[k] = nil end
    for k, v in pairs(parsed) do state.codexData[k] = v end
    if cb then cb() end
  end)
end

function M.makeProvider()
  return {
    id = "codex",
    loginLabel = "chatgpt.com",
    openSettingsLabel = "chatgpt.com/codex/cloud/settings/analytics",
    openSettingsUrl = TARGET_URL .. "#usage",
    hasExtraUsage = false,

    getState = function() return state.codexData end,
    fetch    = M.providerFetch,
    login    = M.interactiveLogin,
    logout   = M.logoutSoft,
    logoutHard = M.logoutHard,

    runJS = M.runJS,
    reload = M.reload,
    destroyPersistent = M.destroyPersistent,
    debugState = M.debugState,
    clearCookies = M.clearCookies,
  }
end

return M
