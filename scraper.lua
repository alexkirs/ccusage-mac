local state = require("claude_usage.state")
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

local EXTRACT_JS = [[
(function(){
  try {
    var href = location.href;
    if (/\/(login|auth|sign-in)/.test(href)) {
      return JSON.stringify({needsLogin: true, href: href});
    }
    var body = document.body || {};
    var txt = body.innerText || "";
    var lines = txt.split(/\n+/).map(function(s){return s.trim();}).filter(Boolean);

    // Find a named block and return the nearest following "Resets ..." + "N% used" pair.
    function findBlock(labels, startIdx) {
      for (var i = startIdx || 0; i < lines.length; i++) {
        if (labels.indexOf(lines[i]) < 0) continue;
        var resets = null, used = null;
        for (var j = i + 1; j < Math.min(i + 12, lines.length); j++) {
          var l = lines[j];
          var rm = l.match(/^Resets\s+(?:in\s+)?(.+?)\.?$/i);
          if (rm && resets === null) resets = rm[1].trim();
          var um = l.match(/^(\d+)\s*%\s*used/i);
          if (um && used === null) used = parseInt(um[1], 10);
          if (resets !== null && used !== null) return { idx: i, resets: resets, used: used };
        }
      }
      return null;
    }

    var session = findBlock(["Current session"]);
    // "Weekly limits" has sub-blocks labelled "All models" and "Sonnet only".
    var weeklyAll = findBlock(["All models"]);
    var weeklySonnet = findBlock(["Sonnet only"]);

    return JSON.stringify({
      href: href,
      raw: txt.slice(0, 8000),
      html: document.documentElement.outerHTML,
      title: document.title,
      blocks: { session: session, weeklyAll: weeklyAll, weeklySonnet: weeklySonnet },
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

local function saveArtifacts(result, ok)
  if not hs.settings.get("claude_usage.save_artifacts") then return end
  ensureDebugDir()
  if result.html then writeFile(DEBUG_DIR .. "/last.html", result.html) end
  if result.raw then writeFile(DEBUG_DIR .. "/last.txt", result.raw) end
  writeFile(DEBUG_DIR .. "/last-parsed.json", hs.json.encode(result, true))
  if not ok then
    local ts = os.date("%Y%m%d-%H%M%S")
    writeFile(DEBUG_DIR .. "/fail-" .. ts .. ".json", hs.json.encode(result, true))
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

local function winFromBlock(b)
  if not b then return nil end
  local used = tonumber(b.used)
  if not used then return nil end
  return {
    percentUsed = used,
    percentLeft = math.max(0, 100 - used),
    resetsHuman = b.resets,
    resetsAt = nil,
  }
end

local function parseUsage(result)
  if result.needsLogin then
    return { status = "needs_login", errorMsg = nil, warnings = nil }
  end
  if result.error then
    return { status = "error", errorMsg = "js: " .. result.error, warnings = nil }
  end
  local blocks = result.blocks or {}
  local five = winFromBlock(blocks.session)
  local wkAll = winFromBlock(blocks.weeklyAll)
  local wkSon = winFromBlock(blocks.weeklySonnet)
  if not five or not wkAll then
    return {
      status = "error",
      errorMsg = "parser drift: missing session or weekly/all blocks — page HTML likely changed",
      warnings = nil,
    }
  end

  -- Landmark sanity checks: the page changed if these strings go away.
  local txt = result.raw or ""
  local warnings = {}
  if not txt:find("Plan usage limits", 1, true) then
    table.insert(warnings, "landmark 'Plan usage limits' not found")
  end
  if not txt:find("Weekly limits", 1, true) then
    table.insert(warnings, "landmark 'Weekly limits' not found")
  end
  if not wkSon then
    table.insert(warnings, "Sonnet-only block not found (label renamed or removed)")
  end

  return {
    status = "ok",
    errorMsg = nil,
    fiveHour = five,
    weekly = wkAll,
    weeklySonnet = wkSon,
    warnings = warnings,
  }
end

local function parseLabelBlocksLua(txt)
  local lines = {}
  for line in txt:gmatch("[^\n]+") do
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    if line ~= "" then table.insert(lines, line) end
  end
  local function findBlock(labels)
    for i = 1, #lines do
      local match = false
      for _, lab in ipairs(labels) do if lines[i] == lab then match = true; break end end
      if match then
        local resets, used = nil, nil
        for j = i + 1, math.min(i + 12, #lines) do
          local l = lines[j]
          if not resets then
            local r = l:match("^[Rr]esets%s+[Ii]n%s+(.-)%.?$")
                   or l:match("^[Rr]esets%s+(.-)%.?$")
            if r and r ~= "" then resets = r end
          end
          if not used then
            local u = l:match("^(%d+)%s*%%%s*used")
            if u then used = tonumber(u) end
          end
          if resets and used then return { idx = i, resets = resets, used = used } end
        end
      end
    end
    return nil
  end
  return {
    session = findBlock({ "Current session" }),
    weeklyAll = findBlock({ "All models" }),
    weeklySonnet = findBlock({ "Sonnet only" }),
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
  local txt
  if p:match("%.html?$") then
    txt = content:gsub("<script.->.-</script>", " ")
                 :gsub("<style.->.-</style>", " ")
                 :gsub("<br%s*/?>", "\n")
                 :gsub("</p>", "\n")
                 :gsub("</div>", "\n")
                 :gsub("</li>", "\n")
                 :gsub("<[^>]*>", " ")
                 :gsub("&nbsp;", " ")
  else
    txt = content
  end
  return {
    href = "replay://" .. p,
    raw = txt:sub(1, 8000),
    html = content,
    title = "replay",
    blocks = parseLabelBlocksLua(txt),
  }
end

function M.fetch(onDone)
  local t0 = hs.timer.secondsSinceEpoch()
  state.log("i", "fetch start")
  log.i("fetch start")

  local replay = loadReplay()
  if replay then
    log.i("replay mode active")
    saveArtifacts(replay, true)
    local parsed = parseUsage(replay)
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
        saveArtifacts({ error = m }, false)
        finish({ status = "error", errorMsg = m })
        return
      end
      local ok, result = pcall(hs.json.decode, resultStr or "{}")
      if not ok or type(result) ~= "table" then
        local m = "json decode fail: " .. tostring(resultStr):sub(1, 200)
        log.e(m); state.log("e", m)
        saveArtifacts({ raw = tostring(resultStr) }, false)
        finish({ status = "error", errorMsg = m })
        return
      end
      local parsed = parseUsage(result)
      saveArtifacts(result, parsed.status == "ok")
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
