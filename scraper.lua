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

function M.interactiveLogin(onClosed)
  if loginWV then
    loginWV:show():bringToFront(true)
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
  loginWV:url(TARGET_URL)
  loginWV:show()
  loginWV:bringToFront(true)

  local poll
  poll = hs.timer.doEvery(1, function()
    if not loginWV then poll:stop(); return end
    local hswin = loginWV:hswindow()
    if not hswin then
      log.i("login window closed")
      loginWV = nil
      poll:stop()
      -- Force the persistent WV to pick up new cookies on its next tick.
      pageState = "cold"
      if onClosed then onClosed() end
    end
  end)
end

local function rmTree(path)
  local t = hs.task.new("/bin/rm", function(code)
    log.i("rm -rf " .. path .. " exit=" .. tostring(code))
  end, { "-rf", path })
  t:start()
end

function M.clearCookies()
  log.w("clearCookies: wiping Hammerspoon WebKit data (relaunch Hammerspoon after)")
  state.log("w", "cookies cleared (relaunch Hammerspoon)")
  rmTree(HOME .. "/Library/WebKit/org.hammerspoon.Hammerspoon")
  rmTree(HOME .. "/Library/HTTPStorages/org.hammerspoon.Hammerspoon")
end

-- Log out: destroy webview, wipe cookies, relaunch Hammerspoon so the next
-- boot has no session and prompts for login. WebKit keeps cookies in process
-- memory, so a Lua reload alone isn't enough — we must restart the app.
function M.logout()
  log.i("logout: destroying webview + wiping cookies + relaunching")
  state.log("i", "logout requested")
  M.destroyPersistent()
  M.clearCookies()
  hs.alert.show("Logging out — Hammerspoon will relaunch")
  hs.execute("nohup /bin/bash -c 'sleep 1 && /usr/bin/open -a Hammerspoon' >/dev/null 2>&1 &")
  hs.timer.doAfter(0.5, function() os.exit(0) end)
end

return M
