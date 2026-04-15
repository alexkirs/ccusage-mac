local state = require("claude_usage.state")
local parser = require("claude_usage.parser")
local log = hs.logger.new("cu.scraper", hs.settings.get("claude_usage.log_level") or "info")

local M = {}

local HOME = os.getenv("HOME")
local DEBUG_DIR = HOME .. "/.hammerspoon/claude_usage/debug"
local TARGET_URL = "https://claude.ai/settings/usage"
local FETCH_TIMEOUT_S = 30
local CONTENT_POLL_INTERVAL_S = 0.3
local CONTENT_POLL_MAX_TRIES = 20   -- ≈ 6 s hard cap
local HARD_RELOAD_INTERVAL_S = 15 * 60  -- safety-net full reload every 15 min

---------------------------------------------------------------------
-- Module-local state. One persistent WKWebView instead of one per fetch.
---------------------------------------------------------------------

local persistentWV = nil
local pageState = "cold"   -- "cold" | "loading" | "ready" | "needs_login"
local lastHardReloadAt = 0
local lastExtractMs = 0

-- Anchor duration-based reset strings to the first time we observed them, so
-- warm extracts that re-read a stale "Resets in X min" text still count down.
-- Keyed by window slot; { human = "1 hr 15 min", at = os.time() }.
local resetAnchors = {}

local fetchInProgress = false
local fetchTimeoutTimer = nil
local contentPollTimer = nil

-- Single navigation handler wired once; per-nav logic is routed through this.
local pendingNav = nil  -- { onFinish = fn(webview), onFail = fn(err) }

local loginWV = nil

---------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------

-- hs.webview:evaluateJavaScript delivers a {code=0} error object alongside
-- valid results. Treat nil result as the actual failure signal.
local function jsFailed(resultStr, jsErr)
  if resultStr ~= nil then return false end
  if jsErr and jsErr.code and jsErr.code ~= 0 then return true end
  return jsErr ~= nil
end

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

-- HTML is 200 KB per IPC roundtrip; only send it when artifact saving is on.
local EXTRACT_JS_WITH_HTML = [[
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

local EXTRACT_JS_LEAN = [[
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
      title: document.title,
      href: href,
    });
  } catch (e) {
    return JSON.stringify({error: String(e)});
  }
})()
]]

local function extractJs()
  if hs.settings.get("claude_usage.save_artifacts") then return EXTRACT_JS_WITH_HTML end
  return EXTRACT_JS_LEAN
end

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

---------------------------------------------------------------------
-- Persistent webview lifecycle
---------------------------------------------------------------------

local function visibleMode()
  return hs.settings.get("claude_usage.debug_visible") == true
end

local function navigationCallback(action, webview, navID, err)
  if action == "didFinishNavigation" then
    log.d("nav finish (navID=" .. tostring(navID) .. ")")
    if pendingNav and pendingNav.onFinish then
      local cb = pendingNav; pendingNav = nil
      cb.onFinish(webview)
    end
  elseif action == "didFailNavigation" or action == "didFailProvisionalNavigation" then
    local m = "nav fail: " .. hs.inspect(err)
    log.e(m); state.log("e", m)
    if pendingNav and pendingNav.onFail then
      local cb = pendingNav; pendingNav = nil
      cb.onFail(m)
    end
  end
end

local function createPersistentWV()
  local visible = visibleMode()
  local rect = visible and {x = 120, y = 120, w = 820, h = 920}
                        or {x = -9000, y = -9000, w = 900, h = 900}
  local wv = hs.webview.new(rect, { developerExtrasEnabled = true, javaScriptEnabled = true })
  if not wv then return nil end
  if visible then
    wv:windowStyle({"titled", "closable", "resizable"})
  else
    wv:windowStyle({"borderless"})
  end
  wv:allowTextEntry(true)
  wv:navigationCallback(navigationCallback)
  wv:show()
  return wv
end

function M.destroyPersistent()
  if persistentWV then
    pcall(function() persistentWV:delete() end)
    log.i("persistent webview destroyed")
    state.log("i", "persistent webview destroyed")
  end
  persistentWV = nil
  pageState = "cold"
  lastHardReloadAt = 0
  pendingNav = nil
end

function M.debugState()
  local now = hs.timer.secondsSinceEpoch()
  return {
    persistentWV = persistentWV ~= nil,
    pageState = pageState,
    lastHardReloadAt = lastHardReloadAt,
    secondsSinceReload = lastHardReloadAt > 0 and math.floor(now - lastHardReloadAt) or nil,
    lastExtractMs = lastExtractMs,
    fetchInProgress = fetchInProgress,
    pendingNav = pendingNav ~= nil,
  }
end

---------------------------------------------------------------------
-- Fetch paths
---------------------------------------------------------------------

-- For windows whose reset string is a duration ("1 hr 15 min"), replace the
-- parser's now-anchored resetsAt with one anchored at the first time we saw
-- that exact text. Weekday+time and month+date resets are absolute and need
-- no adjustment.
local ANCHORED_KEYS = { "fiveHour", "weekly", "weeklySonnet", "weeklyOpus", "weeklyHaiku" }
local function applyResetAnchors(parsed)
  if parsed.status ~= "ok" then return end
  local now = os.time()
  for _, key in ipairs(ANCHORED_KEYS) do
    local win = parsed[key]
    if win and win.resetsHuman and parser._looksDuration(win.resetsHuman) then
      local secs = parser._durationSecs(win.resetsHuman)
      local prev = resetAnchors[key]
      if prev and prev.human == win.resetsHuman and secs then
        win.resetsAt = prev.at + secs
      else
        resetAnchors[key] = { human = win.resetsHuman, at = now }
        -- resetsAt already = now + secs (parser's default); leave as-is.
      end
    end
  end
end

-- All three paths funnel through this once the parser has produced a result.
local function completeFetch(t0, parsed, rawForArtifacts, onDone)
  if fetchTimeoutTimer then fetchTimeoutTimer:stop(); fetchTimeoutTimer = nil end
  if contentPollTimer then contentPollTimer:stop(); contentPollTimer = nil end
  local dt = math.floor((hs.timer.secondsSinceEpoch() - t0) * 1000)
  lastExtractMs = dt
  state.recordTiming(dt)
  state.data.fetchTiming = { totalMs = dt }
  local summary = string.format("fetch done status=%s dt=%dms pageState=%s",
    parsed.status or "?", dt, pageState)
  log.i(summary); state.log("i", summary)
  applyResetAnchors(parsed)
  saveArtifacts(rawForArtifacts or {}, parsed, parsed.status == "ok")
  fetchInProgress = false
  parsed.lastFetch = os.time()
  onDone(parsed)
end

-- Evaluate EXTRACT_JS on the persistent webview. Handles JSON / JS errors.
local function runExtract(t0, onDone, onExtracted)
  if not persistentWV then
    completeFetch(t0, { status = "error", errorMsg = "no persistent webview" }, nil, onDone)
    return
  end
  persistentWV:evaluateJavaScript(extractJs(), function(resultStr, jsErr)
    if jsFailed(resultStr, jsErr) then
      local m = "js error: " .. hs.inspect(jsErr)
      log.e(m); state.log("e", m)
      completeFetch(t0, { status = "error", errorMsg = m }, { error = m }, onDone)
      return
    end
    local ok, raw = pcall(hs.json.decode, resultStr or "{}")
    if not ok or type(raw) ~= "table" then
      local m = "json decode fail: " .. tostring(resultStr):sub(1, 200)
      log.e(m); state.log("e", m)
      completeFetch(t0, { status = "error", errorMsg = m },
        { innerText = tostring(resultStr) }, onDone)
      return
    end
    local parsed = toUsageState(raw)
    if parsed.status == "needs_login" then
      pageState = "needs_login"
    elseif parsed.status == "ok" then
      pageState = "ready"
    end
    onExtracted(raw, parsed)
  end)
end

-- Poll the page until it has usage content, then run the extract.
local function startContentPoll(t0, onDone)
  if contentPollTimer then contentPollTimer:stop(); contentPollTimer = nil end
  local tries = 0
  contentPollTimer = hs.timer.doEvery(CONTENT_POLL_INTERVAL_S, function()
    tries = tries + 1
    if not fetchInProgress or not persistentWV then
      if contentPollTimer then contentPollTimer:stop(); contentPollTimer = nil end
      return
    end
    persistentWV:evaluateJavaScript(READY_JS, function(ready, _err)
      if not fetchInProgress then return end
      if ready == true then
        log.d("content ready after " .. tries .. " polls")
        if contentPollTimer then contentPollTimer:stop(); contentPollTimer = nil end
        runExtract(t0, onDone, function(raw, parsed)
          completeFetch(t0, parsed, raw, onDone)
        end)
      elseif tries >= CONTENT_POLL_MAX_TRIES then
        log.w("content poll gave up after " .. tries .. " tries — extracting anyway")
        state.log("w", "content poll gave up at try " .. tries)
        if contentPollTimer then contentPollTimer:stop(); contentPollTimer = nil end
        runExtract(t0, onDone, function(raw, parsed)
          completeFetch(t0, parsed, raw, onDone)
        end)
      end
    end)
  end)
end

local function pathCold(t0, onDone)
  log.i("cold path — creating persistent webview")
  state.log("i", "cold path")
  persistentWV = createPersistentWV()
  if not persistentWV then
    completeFetch(t0, { status = "error", errorMsg = "hs.webview.new returned nil" }, nil, onDone)
    return
  end
  pageState = "loading"
  lastHardReloadAt = hs.timer.secondsSinceEpoch()
  pendingNav = {
    onFinish = function(_) startContentPoll(t0, onDone) end,
    onFail = function(m) completeFetch(t0, { status = "error", errorMsg = m }, nil, onDone) end,
  }
  persistentWV:url(TARGET_URL)
end

local function pathStale(t0, onDone, reason)
  log.i("stale path — reloading (" .. (reason or "?") .. ")")
  state.log("i", "stale path: " .. (reason or "?"))
  if not persistentWV then return pathCold(t0, onDone) end
  pageState = "loading"
  lastHardReloadAt = hs.timer.secondsSinceEpoch()
  pendingNav = {
    onFinish = function(_) startContentPoll(t0, onDone) end,
    onFail = function(m) completeFetch(t0, { status = "error", errorMsg = m }, nil, onDone) end,
  }
  persistentWV:reload()
end

local function pathWarm(t0, onDone)
  log.d("warm path — extract only")
  runExtract(t0, onDone, function(raw, parsed)
    -- Fall back to a reload if the SPA lost state or session expired.
    local needsReload = false
    local reason
    if parsed.status == "needs_login" then
      needsReload = true; reason = "warm extract says needs_login"
    elseif parsed.status == "error" then
      needsReload = true; reason = "warm extract error: " .. tostring(parsed.errorMsg)
    elseif parsed.status == "ok" and not parsed.fiveHour and not parsed.weekly then
      needsReload = true; reason = "warm extract empty"
    end
    if needsReload then
      log.w("warm→stale: " .. reason)
      state.log("w", "warm→stale: " .. reason)
      pathStale(t0, onDone, reason)
      return
    end
    completeFetch(t0, parsed, raw, onDone)
  end)
end

function M.fetch(onDone)
  -- Replay short-circuit (unchanged).
  local replay = loadReplay()
  if replay then
    local t0 = hs.timer.secondsSinceEpoch()
    log.i("replay mode active")
    local parsed = toUsageState(replay)
    saveArtifacts(replay, parsed, parsed.status == "ok")
    parsed.lastFetch = os.time()
    state.recordTiming(math.floor((hs.timer.secondsSinceEpoch() - t0) * 1000))
    onDone(parsed)
    return
  end

  if fetchInProgress then
    log.w("fetch already in flight, skipping")
    state.log("w", "fetch skipped: in flight")
    return
  end

  fetchInProgress = true
  local t0 = hs.timer.secondsSinceEpoch()
  state.log("i", "fetch start pageState=" .. pageState)
  log.i("fetch start pageState=" .. pageState)

  fetchTimeoutTimer = hs.timer.doAfter(FETCH_TIMEOUT_S, function()
    if not fetchInProgress then return end
    log.w("fetch timeout"); state.log("w", "fetch timeout")
    -- Mark page stale so next fetch triggers a reload.
    pageState = "cold"
    completeFetch(t0, { status = "error", errorMsg = "timeout after " .. FETCH_TIMEOUT_S .. "s" }, nil, onDone)
  end)

  local now = hs.timer.secondsSinceEpoch()
  if not persistentWV or pageState == "cold" then
    return pathCold(t0, onDone)
  end
  if pageState == "needs_login" then
    return pathStale(t0, onDone, "retry after needs_login")
  end
  if (now - lastHardReloadAt) >= HARD_RELOAD_INTERVAL_S then
    return pathStale(t0, onDone, "15-min safety reload")
  end
  if pageState == "loading" then
    -- Another fetch is mid-navigation; shouldn't normally happen due to inFlight guard.
    return pathStale(t0, onDone, "unexpected loading state")
  end
  -- pageState == "ready"
  return pathWarm(t0, onDone)
end

function M.forceReload(onDone)
  if fetchInProgress then
    log.w("forceReload requested but fetch in flight; will retry after completion")
    return
  end
  pageState = persistentWV and "ready" or "cold"  -- normalize; pathStale will handle nil
  -- Bias the next fetch to take the stale path regardless of interval.
  lastHardReloadAt = 0
  M.fetch(onDone or function() end)
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
      -- Login window shares the WKWebsiteDataStore with persistent WV.
      -- After login, force a fresh reload so persistent WV sees the new cookies.
      pageState = persistentWV and "needs_login" or "cold"
      lastHardReloadAt = 0
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
  return fetchInProgress
end

return M
