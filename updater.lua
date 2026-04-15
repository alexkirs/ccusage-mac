-- Self-update via git. Two modes:
--   clone install   → fetch/pull/reload
--   symlink (dev)   → skip updates, enable .lua pathwatcher live-reload

local state = require("claude_usage.state")
local log = state.logger("updater")

local M = {}

local HS_DIR = os.getenv("HOME") .. "/.hammerspoon/claude_usage"
local GIT = "/usr/bin/git"

-- Updater lives under the "update." sub-namespace of claude_usage.
local function get(k, d) return state.get("update." .. k, d) end
local function set(k, v) state.set("update." .. k, v) end

-- repoPath: resolve symlinks. Used as CWD for all git calls.
local function repoPath() return hs.fs.pathToAbsolute(HS_DIR) end
M.repoPath = repoPath

-- isDev: true if install is a symlink (developer workflow).
local function isDev()
  local attrs = hs.fs.symlinkAttributes(HS_DIR)
  return attrs and attrs.mode == "link" or false
end
M.isDev = isDev

-- Non-blocking git. cb(ok, stdout, stderr, exitCode)
local function git(args, cb)
  local path = repoPath()
  if not path then return cb(false, "", "no repo path", -1) end
  local task = hs.task.new(GIT, function(code, out, err)
    cb(code == 0, out or "", err or "", code)
  end, args)
  task:setWorkingDirectory(path)
  task:start()
end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

-- Public synchronous snapshot for menu rendering.
function M.status()
  return {
    sha          = M.cachedSha,
    behind       = get("behind", 0),
    lastCheck    = get("lastCheck", nil),
    checking     = M.checking == true,
    dev          = isDev(),
    dirty        = M.cachedDirty == true,
    autoCheck    = get("autoCheck", true),
    autoApply    = get("autoApply", false),
    devWatch     = get("devWatch", isDev()),
    subjects     = get("subjects", {}),
    error        = M.lastError,
    updating     = M.updating == true,
  }
end

-- checkNow(cb?) - fetch origin + measure divergence. cb(status).
-- Rate-limited to 30 s to avoid spam.
local MIN_CHECK_INTERVAL = 30
function M.checkNow(cb)
  cb = cb or function() end
  if M.checking then return cb(M.status()) end
  local last = get("lastCheck", 0) or 0
  if os.time() - last < MIN_CHECK_INTERVAL and not M.forceCheck then
    return cb(M.status())
  end
  M.forceCheck = false
  M.checking = true
  M.lastError = nil

  git({ "fetch", "--quiet", "origin", "main" }, function(ok, _, err)
    if not ok then
      M.checking = false
      M.lastError = "fetch failed: " .. trim(err or "")
      state.log("w", "updater: " .. M.lastError)
      return cb(M.status())
    end
    git({ "rev-list", "HEAD..origin/main", "--count" }, function(ok2, out2)
      if not ok2 then
        M.checking = false
        M.lastError = "rev-list failed"
        return cb(M.status())
      end
      local behind = tonumber(trim(out2)) or 0
      set("behind", behind)
      set("lastCheck", os.time())
      if behind == 0 then
        set("subjects", {})
        M.checking = false
        return cb(M.status())
      end
      git({ "log", "--format=%s", "HEAD..origin/main" }, function(ok3, out3)
        local subjects = {}
        if ok3 then
          for line in (out3 or ""):gmatch("[^\n]+") do
            table.insert(subjects, line)
          end
        end
        set("subjects", subjects)
        M.checking = false
        state.log("i", string.format("updater: %d commit(s) behind", behind))
        -- Auto-apply if enabled and safe.
        if get("autoApply", false) and not isDev() and not M.cachedDirty then
          M.apply()
        end
        cb(M.status())
      end)
    end)
  end)
end

-- apply: fast-forward pull, then reload. No-op in dev/dirty.
function M.apply(cb)
  cb = cb or function() end
  if isDev() then
    hs.alert.show("Dev install — update disabled")
    return cb(false)
  end
  if M.updating then return cb(false) end
  M.updating = true
  state.log("i", "updater: pulling origin/main")
  git({ "pull", "--ff-only", "origin", "main" }, function(ok, out, err)
    M.updating = false
    if not ok then
      M.lastError = "pull failed: " .. trim(err or "")
      hs.alert.show("Update failed")
      state.log("e", "updater: " .. M.lastError)
      return cb(false)
    end
    set("behind", 0)
    set("subjects", {})
    hs.alert.show("Updated — reloading…")
    state.log("i", "updater: pull ok, reloading\n" .. out)
    hs.timer.doAfter(0.5, function() hs.reload() end)
    cb(true)
  end)
end

-- Cache short SHA + dirty bit once at start; refresh after apply (reload anyway).
local function refreshLocal()
  git({ "rev-parse", "--short", "HEAD" }, function(ok, out)
    if ok then M.cachedSha = trim(out) end
  end)
  git({ "status", "--porcelain" }, function(ok, out)
    M.cachedDirty = ok and trim(out) ~= ""
  end)
end

-- Dev live-reload: watch *.lua under repo, debounced 300 ms. Ignores .git/.
local function startDevWatch()
  if M.watcher then return end
  local path = repoPath()
  if not path then return end
  M.watcher = hs.pathwatcher.new(path, function(files)
    for _, f in ipairs(files) do
      if f:match("%.lua$") and not f:match("/%.git/") then
        if M.reloadDebounce then M.reloadDebounce:stop() end
        M.reloadDebounce = hs.timer.doAfter(0.3, function()
          state.log("i", "updater: dev-watch reload")
          hs.reload()
        end)
        return
      end
    end
  end)
  M.watcher:start()
  state.log("i", "updater: dev-watch started on " .. path)
end

local function stopDevWatch()
  if M.watcher then M.watcher:stop(); M.watcher = nil end
  if M.reloadDebounce then M.reloadDebounce:stop(); M.reloadDebounce = nil end
end

function M.setAutoCheck(v)
  set("autoCheck", v and true or false)
  M.restartAutoTimer()
end

function M.setAutoApply(v) set("autoApply", v and true or false) end

function M.setDevWatch(v)
  set("devWatch", v and true or false)
  if v then startDevWatch() else stopDevWatch() end
end

function M.restartAutoTimer()
  if M.autoTimer then M.autoTimer:stop(); M.autoTimer = nil end
  if get("autoCheck", true) and not isDev() then
    -- Daily. Kick one check 60 s after start so boot isn't blocked.
    M.autoTimer = hs.timer.doEvery(86400, function() M.checkNow() end)
    hs.timer.doAfter(60, function() M.checkNow() end)
  end
end

function M.start()
  refreshLocal()
  if get("devWatch", isDev()) and isDev() then startDevWatch() end
  M.restartAutoTimer()
  state.log("i", "updater: start (dev=" .. tostring(isDev()) .. ")")
end

function M.stop()
  if M.autoTimer then M.autoTimer:stop(); M.autoTimer = nil end
  stopDevWatch()
end

return M
