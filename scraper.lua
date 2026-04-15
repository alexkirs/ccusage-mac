local state = require("claude_usage.state")
local parser = require("claude_usage.parser")
local log = hs.logger.new("cu.scraper", hs.settings.get("claude_usage.log_level") or "info")

local M = {}

local HOME = os.getenv("HOME")
local DEBUG_DIR = HOME .. "/.hammerspoon/claude_usage/debug"
local TARGET_URL = "https://claude.ai/settings/usage"
local FETCH_TIMEOUT_S = 30

local currentFetchWV = nil
local fetchTimeoutTimer = nil
local contentPollTimer = nil
local loginWV = nil

-- Wait up to this long after didFinishNavigation for the SPA to render usage content.
local CONTENT_POLL_INTERVAL_S = 0.5
local CONTENT_POLL_MAX_TRIES = 30  -- 15s total

-- hs.webview:evaluateJavaScript always delivers a {code=0} error object alongside
-- valid results. Treat nil result as the actual failure signal.
local function jsFailed(resultStr, jsErr)
  if resultStr ~= nil then return false end
  if jsErr and jsErr.code and jsErr.code ~= 0 then return true end
  return jsErr ~= nil
end

-- Returns true once the SPA has rendered something that looks like usage content.
local READY_JS = [[
(function(){
  try {
    var href = location.href;
    if (/\/(login|auth|sign-in)/.test(href)) return true;
    var body = document.body;
    if (!body) return false;
    var txt = body.innerText || "";
    return txt.length > 400 && /\d+\s*%/.test(txt);
  } catch (e) { return false; }
})()
]]

-- The SPA renders async after didFinishNavigation. We need the DOM's computed
-- innerText, not raw HTML. JS is deliberately tiny here — all classification
-- happens in parser.lua for easy iteration via hot-reload and shared codepath
-- with replay mode.
local EXTRACT_JS = [[
(function(){
  try {
    var href = location.href;
    if (/\/(login|auth|sign-in)/.test(href)) {
      return JSON.stringify({needsLogin: true, href: href});
    }
    var body = document.body;
    if (!body) return JSON.stringify({innerText: "", href: href});
    return JSON.stringify({
      innerText: body.innerText || "",
      html: document.documentElement.outerHTML.slice(0, 200000),
      title: document.title,
      href: href,
    });
  } catch (e) {
    return JSON.stringify({error: String(e)});
  }
})()
]]

local function ensureDebugDir()
  hs.fs.mkdir(DEBUG_DIR)
end

local function writeFile(path, contents)
  local f, err = io.open(path, "w")
  if not f then log.e("write fail: " .. tostring(err)); return end
  f:write(contents or "")
  f:close()
end

local function saveArtifacts(raw, parsed, ok)
  if not hs.settings.get("claude_usage.save_artifacts") then return end
  ensureDebugDir()
  if raw.html then writeFile(DEBUG_DIR .. "/last.html", raw.html) end
  if raw.innerText then writeFile(DEBUG_DIR .. "/last.txt", raw.innerText) end
  if parsed then writeFile(DEBUG_DIR .. "/last-parsed.json", hs.json.encode(parsed, true)) end
  if not ok then
    local ts = os.date("%Y%m%d-%H%M%S")
    writeFile(DEBUG_DIR .. "/fail-" .. ts .. ".json",
              hs.json.encode({ raw = raw, parsed = parsed }, true))
    local files = {}
    for f in hs.fs.dir(DEBUG_DIR) do
      if f:match("^fail%-.*%.json$") then table.insert(files, f) end
    end
    table.sort(files)
    while #files > 10 do
      os.remove(DEBUG_DIR .. "/" .. files[1])
      table.remove(files, 1)
    end
  end
end

-- Run the parser over whatever innerText we got (live or replay) and convert
-- the parser's public shape into the state shape the rest of the app uses.
local function toUsageState(raw)
  if raw.needsLogin then
    return { status = "needs_login", errorMsg = nil, warnings = nil }
  end
  if raw.error then
    return { status = "error", errorMsg = "js: " .. raw.error, warnings = nil }
  end
  local parsed = parser.parse(raw.innerText or "")
  if parsed.status ~= "ok" then
    return { status = "error", errorMsg = parsed.errorMsg or "parser failure",
             warnings = parsed.warnings }
  end
  return {
    status = "ok",
    errorMsg = nil,
    fiveHour = parsed.fiveHour,
    weekly = parsed.weekly,
    weeklySonnet = parsed.weeklySonnet,
    weeklyOpus = parsed.weeklyOpus,
    weeklyHaiku = parsed.weeklyHaiku,
    spend = parsed.spend,
    warnings = parsed.warnings,
  }
end

local function loadReplay()
  local p = hs.settings.get("claude_usage.replay_path")
  if not p or p == "" then return nil end
  local f = io.open(p, "r")
  if not f then
    log.w("replay path not readable: " .. p)
    return nil
  end
  local content = f:read("*a") or ""
  f:close()
  local innerText = p:match("%.html?$") and parser.stripHtml(content) or content
  return {
    href = "replay://" .. p,
    innerText = innerText,
    html = content,
    title = "replay",
  }
end

function M.fetch(onDone)
  local t0 = hs.timer.secondsSinceEpoch()
  state.log("i", "fetch start")
  log.i("fetch start")

  local replay = loadReplay()
  if replay then
    log.i("replay mode active")
    local parsed = toUsageState(replay)
    saveArtifacts(replay, parsed, parsed.status == "ok")
    parsed.lastFetch = os.time()
    state.recordTiming(math.floor((hs.timer.secondsSinceEpoch() - t0) * 1000))
    onDone(parsed)
    return
  end

  if currentFetchWV then
    log.w("fetch already in flight, skipping")
    state.log("w", "fetch skipped: in flight")
    return
  end

  local visible = hs.settings.get("claude_usage.debug_visible") == true
  local keepOpen = hs.settings.get("claude_usage.keep_webview") == true
  -- WKWebView throttles/pauses JS on unshown views. Must :show() to run the SPA.
  -- For headless, show at a large negative offset + borderless so there's no visible UI.
  local rect = visible and {x=120, y=120, w=820, h=920} or {x=-9000, y=-9000, w=900, h=900}

  local wv = hs.webview.new(rect, { developerExtrasEnabled = true, javaScriptEnabled = true })
  if not wv then
    local err = "hs.webview.new returned nil"
    log.e(err)
    state.log("e", err)
    onDone({ status = "error", errorMsg = err, lastFetch = os.time() })
    return
  end
  if visible then
    wv:windowStyle({"titled", "closable", "resizable"})
  else
    wv:windowStyle({"borderless"})
  end
  wv:allowTextEntry(true)
  wv:show()
  currentFetchWV = wv

  local finished = false
  local function finish(parsed)
    if finished then return end
    finished = true
    if fetchTimeoutTimer then fetchTimeoutTimer:stop(); fetchTimeoutTimer = nil end
    if contentPollTimer then contentPollTimer:stop(); contentPollTimer = nil end
    local dt = math.floor((hs.timer.secondsSinceEpoch() - t0) * 1000)
    state.recordTiming(dt)
    state.data.fetchTiming = { totalMs = dt }
    local summary = string.format("fetch done status=%s dt=%dms", parsed.status or "?", dt)
    log.i(summary); state.log("i", summary)
    if not (visible and keepOpen) then pcall(function() wv:delete() end) end
    currentFetchWV = nil
    parsed.lastFetch = os.time()
    onDone(parsed)
  end

  local function runExtract(webview)
    webview:evaluateJavaScript(EXTRACT_JS, function(resultStr, jsErr)
      if jsFailed(resultStr, jsErr) then
        local m = "js error: " .. hs.inspect(jsErr)
        log.e(m); state.log("e", m)
        saveArtifacts({ error = m }, nil, false)
        finish({ status = "error", errorMsg = m })
        return
      end
      local ok, raw = pcall(hs.json.decode, resultStr or "{}")
      if not ok or type(raw) ~= "table" then
        local m = "json decode fail: " .. tostring(resultStr):sub(1, 200)
        log.e(m); state.log("e", m)
        saveArtifacts({ innerText = tostring(resultStr) }, nil, false)
        finish({ status = "error", errorMsg = m })
        return
      end
      local parsed = toUsageState(raw)
      saveArtifacts(raw, parsed, parsed.status == "ok")
      finish(parsed)
    end)
  end

  local function startContentPoll(webview)
    if contentPollTimer then contentPollTimer:stop(); contentPollTimer = nil end
    local tries = 0
    contentPollTimer = hs.timer.doEvery(CONTENT_POLL_INTERVAL_S, function()
      tries = tries + 1
      if finished then
        contentPollTimer:stop(); contentPollTimer = nil; return
      end
      webview:evaluateJavaScript(READY_JS, function(ready, _err)
        if finished then return end
        if ready == true then
          log.d("content ready after " .. tries .. " polls")
          contentPollTimer:stop(); contentPollTimer = nil
          runExtract(webview)
        elseif tries >= CONTENT_POLL_MAX_TRIES then
          log.w("content poll gave up after " .. tries .. " tries — extracting anyway")
          state.log("w", "content poll gave up at try " .. tries)
          contentPollTimer:stop(); contentPollTimer = nil
          runExtract(webview)
        end
      end)
    end)
  end

  wv:navigationCallback(function(action, webview, navID, err)
    if action == "didFinishNavigation" then
      log.d("nav finish, start content poll")
      startContentPoll(webview)
    elseif action == "didFailNavigation" or action == "didFailProvisionalNavigation" then
      local m = "nav fail: " .. hs.inspect(err)
      log.e(m); state.log("e", m)
      finish({ status = "error", errorMsg = m })
    end
  end)

  wv:url(TARGET_URL)

  fetchTimeoutTimer = hs.timer.doAfter(FETCH_TIMEOUT_S, function()
    log.w("fetch timeout"); state.log("w", "fetch timeout")
    finish({ status = "error", errorMsg = "timeout after " .. FETCH_TIMEOUT_S .. "s" })
  end)
end

function M.interactiveLogin(onClosed)
  if loginWV then
    loginWV:show():bringToFront(true)
    return
  end
  log.i("interactive login opened")
  loginWV = hs.webview.new({x=160, y=140, w=820, h=900}, { developerExtrasEnabled = true, javaScriptEnabled = true })
  if not loginWV then return end
  loginWV:windowStyle({"titled", "closable", "resizable"})
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
      if onClosed then onClosed() end
    end
  end)
end

local function rmTree(path)
  -- No shell. hs.task uses posix_spawn-style exec, no shell injection surface.
  local t = hs.task.new("/bin/rm", function(code)
    log.i("rm -rf " .. path .. " exit=" .. tostring(code))
  end, {"-rf", path})
  t:start()
end

function M.clearCookies()
  -- hs.webview doesn't expose per-site WKWebsiteDataStore removal.
  -- Remove Hammerspoon's WebKit data dirs. Requires Hammerspoon relaunch for full effect.
  log.w("clearCookies: wiping Hammerspoon WebKit data (relaunch Hammerspoon after)")
  state.log("w", "cookies cleared (relaunch Hammerspoon)")
  rmTree(HOME .. "/Library/WebKit/org.hammerspoon.Hammerspoon")
  rmTree(HOME .. "/Library/HTTPStorages/org.hammerspoon.Hammerspoon")
end

function M.inFlight()
  return currentFetchWV ~= nil
end

return M
