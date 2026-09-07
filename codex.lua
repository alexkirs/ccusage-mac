-- chatgpt.com (Codex) provider, authenticated as the Codex CLI does.
--
-- Not a cookie/webview provider. Each account owns an isolated CODEX_HOME
-- directory; `codex login --device-auth` (run there) writes auth.json with a
-- long-lived OAuth token set (client app_EMoam…, its own refresh_token). We
-- read tokens.access_token + tokens.account_id and call the same usage API the
-- Codex CLI's status uses:
--
--   GET https://chatgpt.com/backend-api/wham/usage
--     Authorization: Bearer <access_token>
--     ChatGPT-Account-Id: <account_id>
--     originator: codex_cli_rs
--   → { email, plan_type, rate_limit:{ primary_window, secondary_window }, additional_rate_limits }
--
-- Why not the old ChatGPT-web session token: chatgpt.com keeps one active web
-- OAuth token per account, so a second account (or the browser) invalidated
-- ours. Each account's own device-auth login is an independent token chain, so
-- N accounts coexist and none depends on what the browser/CLI is logged into.
local PREFIX = ((...) or "claude_usage"):gsub("%.[^.]+$", "")
local session = require(PREFIX .. ".session")
local state = require(PREFIX .. ".state")
local log = state.logger("codex")

local CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
local TOKEN_URL = "https://auth.openai.com/oauth/token"
local USAGE_URL = "https://chatgpt.com/backend-api/wham/usage"
local AUTH_BASE = os.getenv("HOME") .. "/.hammerspoon/claude_usage_auth/codex"

local M = {
  id = "codex",
  label = "codex",
  loginLabel = "chatgpt.com (Codex CLI)",
  openSettingsLabel = "chatgpt.com/codex/settings/usage",
  openSettingsUrl = "https://chatgpt.com/codex/settings/usage",
  hasExtraUsage = false,
  cliAuth = true,   -- menubar uses M.customLogin instead of the webview flow
}

-- Per-account CODEX_HOME. Kept out of the repo so tokens are never committed.
function M.homeFor(acct) return acct.codexHome or (AUTH_BASE .. "/" .. acct.id) end

---------------------------------------------------------------------
-- auth.json + token
---------------------------------------------------------------------

local function readAuth(home)
  local fh = io.open(home .. "/auth.json", "r"); if not fh then return nil end
  local b = fh:read("a"); fh:close()
  return session.json(b)
end

-- base64url-decode a JWT payload and return its `exp` (epoch) or nil.
local function jwtExp(tok)
  local payload = tok and tok:match("^[^.]+%.([^.]+)%.")
  if not payload then return nil end
  payload = payload:gsub("-", "+"):gsub("_", "/")
  local pad = #payload % 4; if pad > 0 then payload = payload .. string.rep("=", 4 - pad) end
  local claims = session.json(hs.base64.decode(payload) or "")
  return claims and claims.exp
end

-- Refresh the access token in place using the account's own refresh_token
-- (rotates it — safe because this CODEX_HOME is the widget's alone). cb(ok).
function M.refreshToken(acct, cb)
  local home = M.homeFor(acct)
  local auth = readAuth(home)
  local rt = auth and auth.tokens and auth.tokens.refresh_token
  if not rt then return cb(false) end
  local body = hs.json.encode({ client_id = CLIENT_ID, grant_type = "refresh_token", refresh_token = rt })
  session.request("POST", TOKEN_URL, nil, { ["Content-Type"] = "application/json" }, body, function(st, b)
    local j = session.json(b or "")
    if st ~= 200 or not (j and j.access_token) then
      log.w("refresh failed st=" .. tostring(st)); return cb(false)
    end
    auth.tokens.access_token = j.access_token
    if j.refresh_token then auth.tokens.refresh_token = j.refresh_token end
    if j.id_token then auth.tokens.id_token = j.id_token end
    auth.last_refresh = os.date("!%Y-%m-%dT%H:%M:%S.000000Z")
    local fh = io.open(home .. "/auth.json", "w")
    if fh then fh:write(hs.json.encode(auth)); fh:close() end
    cb(true)
  end)
end

---------------------------------------------------------------------
-- Response shape transforms
---------------------------------------------------------------------

local function pct(n) return math.tointeger(n) or n end

local function makeWindow(w)
  if not w or type(w.used_percent) ~= "number" then return nil end
  local u = pct(w.used_percent)
  return { percentUsed = u, percentLeft = math.max(0, 100 - u), resetsAt = w.reset_at }
end

local function splitWindows(rl)
  local fiveHour, weekly
  for i, raw in ipairs({ rl.primary_window or false, rl.secondary_window or false }) do
    local win = raw and makeWindow(raw) or nil
    if win then
      local secs = raw.limit_window_seconds
      local isShort = secs and secs <= 6 * 3600 or (not secs and i == 1)
      if isShort and not fiveHour then fiveHour = win
      elseif not weekly then weekly = win
      elseif not fiveHour then fiveHour = win end
    end
  end
  return fiveHour, weekly
end

local function mapResponse(u)
  if type(u) ~= "table" then
    return { status = "error", errorMsg = "usage response missing or not an object",
             warnings = { "/backend-api/wham/usage did not return an object" } }
  end
  local rl = u.rate_limit
  if type(rl) ~= "table" then
    return { status = "error", errorMsg = "rate_limit field missing",
             warnings = { "API shape changed - rate_limit missing on /backend-api/wham/usage" } }
  end
  local fiveHour, weekly = splitWindows(rl)
  if not fiveHour and not weekly then
    return { status = "error", errorMsg = "no usable rate-limit window",
             warnings = { "API shape changed - expected used_percent in primary_window or secondary_window" } }
  end
  local additional = {}
  for _, arl in ipairs(type(u.additional_rate_limits) == "table" and u.additional_rate_limits or {}) do
    if type(arl.rate_limit) == "table" then
      local afh, awk = splitWindows(arl.rate_limit)
      additional[#additional + 1] = { label = arl.limit_name or "additional", fiveHour = afh, weekly = awk }
    end
  end
  local rc = u.rate_limit_reset_credits
  return {
    status = "ok", fiveHour = fiveHour, weekly = weekly, additional = additional,
    resets = type(rc) == "table" and tonumber(rc.available_count) or nil,  -- limit-reset credits on hand
    account = { email = u.email, orgName = u.plan_type and ("Plan: " .. u.plan_type) or nil },
    warnings = {}, raw = { usage = u },
  }
end

---------------------------------------------------------------------
-- Fetch
---------------------------------------------------------------------

local function callUsage(acct, cb)
  local auth = readAuth(M.homeFor(acct))
  local tok = auth and auth.tokens and auth.tokens.access_token
  local acctId = auth and auth.tokens and auth.tokens.account_id
  if not tok then return cb({ status = "needs_login" }) end
  session.get(USAGE_URL, nil, {
    Authorization = "Bearer " .. tok,
    ["ChatGPT-Account-Id"] = acctId or "",
    originator = "codex_cli_rs",
  }, function(st, b)
    if st == 200 then return cb(mapResponse(session.json(b))) end
    if st == 401 then return cb({ status = "needs_login", _retry = true }) end
    cb(session.failure("/backend-api/wham/usage", st, b))
  end)
end

function M.fetch(acct, cb)
  local auth = readAuth(M.homeFor(acct))
  if not (auth and auth.tokens and auth.tokens.access_token) then
    return cb({ status = "needs_login" })
  end
  -- Refresh proactively when the access token is within 5 min of expiry, or
  -- reactively on a 401.
  local exp = jwtExp(auth.tokens.access_token)
  local nearExp = exp and (exp - os.time() < 300)
  local function go()
    callUsage(acct, function(parsed)
      if parsed._retry then
        M.refreshToken(acct, function(ok)
          if ok then callUsage(acct, cb) else cb({ status = "needs_login" }) end
        end)
      else
        cb(parsed)
      end
    end)
  end
  if nearExp then M.refreshToken(acct, function() go() end) else go() end
end

---------------------------------------------------------------------
-- Login (device-auth via the codex CLI) + logout
---------------------------------------------------------------------

local ANSI = "\27%[[%d;]*m"

-- Runs `codex login --device-auth` in the account's own CODEX_HOME, shows the
-- one-time code, opens the verification page, and waits for auth.json.
-- onDone() on success (menubar then adds/starts the account); nothing on abort.
function M.customLogin(acct, onDone)
  local home = M.homeFor(acct)
  os.execute("mkdir -p '" .. home .. "'")
  local shown, poller, task, finished = false, nil, nil, false

  local function finish(ok)
    if finished then return end
    finished = true
    if poller then poller:stop(); poller = nil end
    if task and task:isRunning() then pcall(function() task:terminate() end) end
    if ok then
      hs.alert.show("Codex account added", 2)
      if onDone then onDone() end
    else
      hs.alert.show("Codex login timed out or cancelled", 3)
    end
  end

  local function onOut(chunk)
    if shown or not chunk then return true end
    local clean = chunk:gsub(ANSI, "")
    local code = clean:match("(%w%w%w%w%-%w%w%w%w%w)") or clean:match("code%s*[:%s]%s*(%S+)")
    if code then
      shown = true
      hs.pasteboard.setContents(code)
      hs.urlevent.openURL("https://auth.openai.com/codex/device")
      hs.dialog.blockAlert("Codex login for " .. (acct.label or M.label),
        "A browser opened at auth.openai.com/codex/device.\n\nSign in with the account you want, then enter this one-time code (already copied to your clipboard):\n\n        " .. code ..
        "\n\nThe window will update on its own once you finish. This can take a few seconds.", "OK")
    end
    return true
  end

  -- login shell so codex + node are on PATH; CODEX_HOME points at this account.
  task = hs.task.new("/bin/zsh", function() end, function(_, out) return onOut(out) end,
    { "-lc", "CODEX_HOME='" .. home .. "' codex login --device-auth 2>&1" })
  task:start()

  -- auth.json appearing is the real success signal (the CLI writes it and exits).
  local t0 = os.time()
  poller = hs.timer.doEvery(2, function()
    local auth = readAuth(home)
    if auth and auth.tokens and auth.tokens.access_token then finish(true)
    elseif os.time() - t0 > 300 then finish(false) end
  end)
end

-- Sign out = drop this account's isolated CODEX_HOME. Best-effort CLI logout
-- first so the server-side session is revoked too.
function M.logout(acct, cb)
  local home = M.homeFor(acct)
  local t = hs.task.new("/bin/zsh", function()
    os.execute("rm -rf '" .. home .. "'")
    cb()
  end, { "-lc", "CODEX_HOME='" .. home .. "' codex logout 2>/dev/null; true" })
  if not t:start() then os.execute("rm -rf '" .. home .. "'"); cb() end
end

return M
