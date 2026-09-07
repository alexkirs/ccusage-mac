-- Interactive login window, provider-agnostic.
--
-- The window uses the shared WebKit datastore. We wipe the provider's domain
-- first so the site starts signed out (otherwise adding a second account just
-- shows the first one), let the user log in (OAuth popups included), then
-- harvest the session cookies from the on-disk jar and hand them back.
local PREFIX = ((...) or "claude_usage"):gsub("%.[^.]+$", "")
local state = require(PREFIX .. ".state")
local session = require(PREFIX .. ".session")
local log = state.logger("login")

local M = {}
local loginWV = nil
M.providerId = nil  -- provider being logged into while the window is open

local function loginLog(fmt, ...)
  local line = "[login] " .. string.format(fmt, ...)
  log.i(line); state.log("i", line)
end

local function setUA(wv) pcall(function() wv:setCustomUserAgent(session.UA) end) end
local function setNormalWindowLevel(wv) pcall(function() wv:level(hs.drawing.windowLevels.normal) end) end

-- provider fields used: domain, cookiePrefix, login = { title, startUrl,
-- isAuthedUrl(u), probeUrl, probeIsAuthed(body) }.
-- onDone(cookieHeader|nil, expires, domainCookies)
function M.open(provider, onDone)
  if loginWV then loginWV:show():bringToFront(); return end
  M.providerId = provider.id
  local spec = provider.login
  local domains = provider.wipeDomains or { provider.domain }
  loginLog("wipe %s then open", table.concat(domains, ","))
  local pending = #domains
  for _, d in ipairs(domains) do
    session.wipe(d, function()
      pending = pending - 1
      if pending == 0 then M.openWindow(provider, spec, onDone) end
    end)
  end
end

function M.openWindow(provider, spec, onDone)
  loginWV = hs.webview.new(
    { x = 160, y = 140, w = 820, h = 900 },
    { developerExtrasEnabled = true, javaScriptEnabled = true }
  )
  if not loginWV then loginLog("hs.webview.new returned nil"); return end

  loginWV:windowStyle({ "titled", "closable", "resizable", "miniaturizable" })
  loginWV:allowTextEntry(true)
  loginWV:windowTitle("⚠  CLOSES AUTOMATICALLY WHEN LOGIN FINISHES — DO NOT CLOSE")
  loginWV:allowNewWindows(true)
  setNormalWindowLevel(loginWV)
  setUA(loginWV)

  local done = false
  local oauthPopup = nil
  local urlTick, probeWV = nil, nil

  local function finish(reason)
    if done then return end
    done = true
    loginLog("closing (%s)", reason)
    if urlTick then urlTick:stop(); urlTick = nil end
    if loginWV then pcall(function() loginWV:delete() end); loginWV = nil end
    M.providerId = nil
    if oauthPopup then pcall(function() oauthPopup:delete() end); oauthPopup = nil end
    if probeWV then pcall(function() probeWV:delete() end); probeWV = nil end
    -- The login window had focus; with no visible window left macOS falls
    -- back to the Hammerspoon console. Close it preemptively.
    pcall(function() hs.closeConsole() end)
    hs.alert.show("Reading session…", 2)
    session.waitFor(provider.domain, provider.cookiePrefix, 30, function(ck, exp, domainCookies)
      loginLog("harvest %s", ck and "ok" or "none")
      onDone(ck, exp, domainCookies)
    end)
  end

  -- OAuth popups (Google / Apple) need a live child WV with our cookies;
  -- otherwise the provider SDK can't postMessage the auth code back.
  loginWV:policyCallback(function(action, newWV, details, features)
    local reqURL = details and details.request and details.request.URL or "?"
    if action == "newWindow" and newWV then
      loginLog("policy newWindow → %s", reqURL)
      if oauthPopup then pcall(function() oauthPopup:delete() end) end
      oauthPopup = newWV
      local f = features or {}
      pcall(function() newWV:frame({ x = f.x or 240, y = f.y or 160, w = f.w or 500, h = f.h or 600 }) end)
      pcall(function() newWV:windowStyle({ "titled", "closable", "resizable", "miniaturizable" }) end)
      pcall(function() newWV:windowTitle("Sign in — OAuth provider") end)
      setNormalWindowLevel(newWV)
      setUA(newWV)
      pcall(function() newWV:allowTextEntry(true) end)
      pcall(function() newWV:windowCallback(function(w) if w == "closing" then oauthPopup = nil end end) end)
      pcall(function() newWV:show() end)
      pcall(function() newWV:bringToFront() end)
    end
    return true
  end)

  -- NSURLError -999 fires when the SPA's redirect chain races the provisional
  -- nav; WKWebView then paints its built-in error page. Recover by reloading
  -- the start URL.
  loginWV:navigationCallback(function(action, wv, navID, err)
    local u = wv and wv:url() or "?"
    local errStr = err and hs.inspect(err):gsub("\n", " ") or "nil"
    loginLog("nav %s url=%s err=%s", tostring(action), tostring(u), errStr)
    if action == "didFinishNavigation" and spec.isAuthedUrl(u) then
      finish("authed url: " .. u)
    elseif (action == "didFailNavigation" or action == "didFailProvisionalNavigation")
       and errStr:find("NSURLErrorDomain") then
      pcall(function() wv:url(spec.startUrl) end)
    end
  end)

  loginWV:windowCallback(function(action)
    if action == "closing" then finish("window closed") end
  end)

  -- Side-channel probe: OAuth flows often leave the visible page stuck on
  -- "One moment please…" while the session cookie has already landed. A
  -- hidden fetch of an authed endpoint detects that.
  local probing, tickCount, lastTickURL = false, 0, nil
  local function runProbe()
    if probing or done or not spec.probeUrl then return end
    probing = true
    probeWV = hs.webview.new({ x = -9000, y = -9000, w = 400, h = 400 }, { javaScriptEnabled = true })
    if not probeWV then probing = false; return end
    probeWV:windowStyle({ "borderless" })
    setUA(probeWV)
    local function teardown()
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
            local authed = spec.probeIsAuthed(body)
            loginLog("probe authed=%s", tostring(authed))
            if authed then finish("probe authed") end
            teardown()
          end)
      elseif action == "didFailNavigation" or action == "didFailProvisionalNavigation" then
        teardown()
      end
    end)
    probeWV:url(spec.probeUrl)
    probeWV:show()  -- JS pauses in never-shown WVs; off-screen+shown avoids that
  end

  urlTick = hs.timer.doEvery(1, function()
    if done or not loginWV then return end
    tickCount = tickCount + 1
    local u = loginWV:url() or "?"
    if u ~= lastTickURL then loginLog("tick url=%s", u); lastTickURL = u end
    if spec.isAuthedUrl(u) then finish("tick authed url: " .. u); return end
    if tickCount >= 3 and (tickCount % 5) == 0 then runProbe() end
    -- Fallback detector: the session cookie shows up in the on-disk jar. The
    -- probe fails to load on some providers (chatgpt.com), so this is the one
    -- that actually closes the window there. Safe against picking up another
    -- account's rotated token because same-provider refresh is paused while
    -- this window is open (see menubar instance.refresh) and the pre-login
    -- wipe cleared the jar first — hence the 20 s delay.
    if tickCount >= 20 and (tickCount % 3) == 0
       and session.pick(session.readJar(), provider.domain, provider.cookiePrefix) then
      finish("cookie landed in jar")
    end
  end)

  loginWV:url(spec.startUrl)
  loginWV:show()
  pcall(function()
    local w = loginWV:hswindow()
    if w then w:focus() end
  end)
end

return M
