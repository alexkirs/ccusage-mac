-- WebKit session lifecycle for the claude.ai usage widget.
--
-- Responsibilities: create and hold the persistent hs.webview at
-- /settings/usage (off-screen so it renders but is invisible), navigate,
-- reload, handle login, expose a minimal JS eval for fetcher.lua.
--
-- No data extraction lives here anymore — fetcher.lua owns that path. This
-- module exists because:
--   * WKWebView shared cookies only persist inside a live hs.webview.
--   * Login + Cloudflare require a real browser engine.
--   * hs.webview pauses JS in a webview that was never :show()n, so we
--     show a borderless window at (-9000,-9000) to keep it rendering.

local state = require("claude_usage.state")
local log = hs.logger.new("cu.scraper", hs.settings.get("claude_usage.log_level") or "info")

local M = {}

local HOME = os.getenv("HOME")
local TARGET_URL = "https://claude.ai/settings/usage"

local persistentWV = nil
local pageState = "cold"   -- cold | loading | ready
local lastNavAt = 0
local pendingNav = nil     -- { onFinish = fn(ok, errOrNil) }
local loginWV = nil

---------------------------------------------------------------------
-- Navigation plumbing
---------------------------------------------------------------------

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
  return hs.settings.get("claude_usage.debug_visible") == true
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

-- Chain a second callback onto an existing pendingNav (both fire on finish).
local function chainPendingNav(newCb)
  local prev = pendingNav.onFinish
  pendingNav.onFinish = function(ok, err)
    if prev then prev(ok, err) end
    newCb(ok, err)
  end
end

---------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------

-- Run a JavaScript snippet on the persistent WV. Callback receives (result, err).
function M.runJS(js, cb)
  if not persistentWV then return cb and cb(nil, "no persistent webview") end
  persistentWV:evaluateJavaScript(js, cb or function() end)
end

-- Ensure the WV is loaded at TARGET_URL. Callback: (ok, errOrNil).
-- Concurrent callers are chained onto the same in-flight navigation.
function M.ensureLoaded(onReady)
  if pageState == "ready" and persistentWV then
    onReady(true)
    return
  end
  if pendingNav then
    chainPendingNav(onReady)
    return
  end
  if not persistentWV then
    persistentWV = createPersistentWV()
    if not persistentWV then
      onReady(false, "hs.webview.new returned nil")
      return
    end
  end
  pageState = "loading"
  lastNavAt = hs.timer.secondsSinceEpoch()
  pendingNav = { onFinish = onReady }
  log.i("ensureLoaded: navigating")
  persistentWV:url(TARGET_URL)
end

-- Force-reload the persistent WV. Callback: (ok, errOrNil).
function M.reload(onReady)
  if not persistentWV then return M.ensureLoaded(onReady) end
  if pendingNav then
    chainPendingNav(onReady)
    return
  end
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
    persistentWV   = persistentWV ~= nil,
    pageState      = pageState,
    lastNavAt      = lastNavAt,
    secondsSinceNav = lastNavAt > 0 and math.floor(now - lastNavAt) or nil,
    pendingNav     = pendingNav ~= nil,
  }
end

---------------------------------------------------------------------
-- Login + cookies
---------------------------------------------------------------------

-- Match the post-login landing pages claude.ai sends authenticated users to.
-- /login|/auth|/sign-in means the flow is still mid-stream.
local function isAuthedUrl(u)
  if type(u) ~= "string" then return false end
  if u:match("/(login|auth|sign%-in|signin)") then return false end
  return u:match("claude%.ai/(settings|new|chat|recents|home)") ~= nil
end

function M.interactiveLogin(onClosed)
  if loginWV then
    loginWV:show():bringToFront()
    return
  end
  log.i("interactive login opened")
  loginWV = hs.webview.new(
    { x = 160, y = 140, w = 820, h = 900 },
    { developerExtrasEnabled = true, javaScriptEnabled = true }
  )
  if not loginWV then return end
  loginWV:windowStyle({ "titled", "closable", "resizable" })
  loginWV:allowTextEntry(true)
  loginWV:windowTitle("Log in to claude.ai")
  loginWV:allowNewWindows(true)

  local done = false
  local function onLoginSuccess(reason)
    if done then return end
    done = true
    log.i("login success (" .. reason .. ")")
    state.log("i", "login success (" .. reason .. ")")
    -- Force the persistent WV to re-read the data store so fresh cookies land.
    pageState = "cold"
    if loginWV then
      pcall(function() loginWV:delete() end)
      loginWV = nil
    end
    -- Kick an immediate reload of the persistent WV so the menubar flips
    -- from "⚠ login" to usage numbers within a second or two, rather than
    -- waiting on the 60 s fetch timer.
    if persistentWV then
      pcall(function() M.reload(function(_, _) end) end)
    end
    if onClosed then onClosed() end
  end

  -- OAuth popups: claude.ai's "Continue with Google/Apple/GitHub" buttons
  -- trigger window.open(). WKWebView blocks those by default. Redirect the
  -- requested URL into this same webview so the consent flow completes
  -- instead of hanging forever on a blank "waiting…" popup.
  loginWV:policyCallback(function(action, _, details)
    if action == "newWindow" then
      local url = details and details.request and details.request.URL
      if url and loginWV then
        log.i("oauth popup intercepted → " .. url)
        loginWV:url(url)
      end
      return false
    end
    return true
  end)

  -- URL-based success detection. Fires the moment a finished navigation
  -- lands on an authed claude.ai page (e.g. /settings/usage, /new, /chat).
  loginWV:navigationCallback(function(action, wv)
    if action == "didFinishNavigation" then
      local u = wv and wv:url() or ""
      if isAuthedUrl(u) then onLoginSuccess("authed url: " .. u) end
    end
  end)

  -- Manual close OR window.close() from a provider page.
  loginWV:windowCallback(function(action)
    if action == "closing" then onLoginSuccess("window closed") end
  end)

  loginWV:url(TARGET_URL)
  loginWV:show()
  loginWV:bringToFront()
end

local function rmTree(path)
  local t = hs.task.new("/bin/rm", function(code)
    log.i("rm -rf " .. path .. " exit=" .. tostring(code))
  end, { "-rf", path })
  t:start()
end

-- Remove path if it exists (file OR directory). Synchronous so callers can
-- sequence a relaunch after deletion actually completes.
local function rmSync(path)
  local out, ok, _, rc = hs.execute("/bin/rm -rf " .. string.format("%q", path))
  log.i(string.format("rm -rf %s rc=%s ok=%s", path, tostring(rc), tostring(ok)))
  return ok, out
end

-- Every path WebKit uses for per-app session state. Covers the binarycookies
-- FILE (not a dir), the WebsiteData store, and the HTTP cache. Missing any
-- one of these leaves Claude's auth cookie in place and "logout" is a no-op.
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

-- Log out: destroy webview, wipe cookies, relaunch Hammerspoon so the next
-- boot has no session and prompts for login. WebKit keeps cookies in process
-- memory, so a Lua reload alone isn't enough — we must restart the app.
-- Order matters: webview torn down BEFORE rm so no live handle re-writes the
-- file, rm is synchronous, THEN relaunch + exit.
function M.logout()
  log.i("logout: destroying webview + wiping cookies + relaunching")
  state.log("i", "logout requested")
  M.destroyPersistent()
  for _, p in ipairs(webkitPaths()) do rmSync(p) end
  hs.alert.show("Logging out — Hammerspoon will relaunch")
  hs.execute("nohup /bin/bash -c 'sleep 2 && /usr/bin/open -a Hammerspoon' >/dev/null 2>&1 &")
  hs.timer.doAfter(0.5, function() os.exit(0) end)
end

return M
