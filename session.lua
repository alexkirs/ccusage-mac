-- Cookie jar access + cookie-scoped HTTP.
--
-- There is no persistent webview anymore. An account is a stored "Cookie:"
-- header; every fetch is a plain hs.http request carrying it. hs.http uses
-- Apple's TLS stack, which passes Cloudflare's managed challenge where curl
-- does not (verified 2026-09: sessionKey alone → 200, no cf_clearance needed).
-- An explicit Cookie header fully overrides the shared jar, so accounts are
-- isolated from each other and from whatever the login window left behind.
local PREFIX = ((...) or "claude_usage"):gsub("%.[^.]+$", "")
local state = require(PREFIX .. ".state")
local log = state.logger("session")

local M = {}

-- WebKit's default datastore shares NSHTTPCookieStorage, which persists here.
-- Only cookies with an Expires land on disk; session cookies never do.
local COOKIE_FILE = os.getenv("HOME") .. "/Library/HTTPStorages/org.hammerspoon.Hammerspoon.binarycookies"

-- Safari 18 UA: Google OAuth treats stock WKWebView as a bot without this,
-- and Cloudflare wants a browser-looking UA on the API calls.
M.UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_6) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

---------------------------------------------------------------------
-- Jar
---------------------------------------------------------------------

-- Apple binarycookies → { [domain] = { [name] = { value, expires } } }.
-- Format: "cook" magic, BE page count + page sizes, then pages; each page
-- has LE cookie count + offsets; each cookie record is LE i32 fields
-- (size, _, flags, _, domainOff, nameOff, pathOff, valueOff) then two
-- doubles (expires, created) in Mac absolute time.
local function parseJar(b)
  if b:sub(1, 4) ~= "cook" then return {} end
  local n = string.unpack(">i4", b, 5)
  local sizes, pos = {}, 9
  for i = 1, n do sizes[i], pos = string.unpack(">i4", b, pos) end
  local jar = {}
  local function cstr(s, o) return s:sub(o + 1, (s:find("\0", o + 1, true) or #s + 1) - 1) end
  for i = 1, n do
    local page = b:sub(pos, pos + sizes[i] - 1); pos = pos + sizes[i]
    local cnt = string.unpack("<i4", page, 5)
    for j = 0, cnt - 1 do
      local off = string.unpack("<i4", page, 9 + 4 * j)
      local c = page:sub(off + 1)
      local _, _, _, _, dom, name, _, val = string.unpack("<i4i4i4i4i4i4i4i4", c)
      local expires = string.unpack("<d", c, 41) + 978307200
      local d = cstr(c, dom):gsub("^%.", "")
      jar[d] = jar[d] or {}
      jar[d][cstr(c, name)] = { value = cstr(c, val), expires = expires }
    end
  end
  return jar
end
M.parseJar = parseJar

function M.readJar()
  local fh = io.open(COOKIE_FILE, "rb"); if not fh then return {} end
  local b = fh:read("a"); fh:close()
  local ok, jar = pcall(parseJar, b)
  if not ok then log.e("jar parse failed: " .. tostring(jar)); return {} end
  return jar
end

-- Builds a Cookie header from every cookie on `domain` whose name starts
-- with `prefix` (plain match). Returns header, earliest expiry; nil if none.
-- Prefix rather than exact name because NextAuth chunks its token into
-- name.0, name.1, … and claude.ai ships sessionKey plus sessionKeyV3 etc.
function M.pick(jar, domain, prefix)
  local d = jar[domain]; if not d then return nil end
  local names = {}
  for n in pairs(d) do if n:sub(1, #prefix) == prefix then names[#names + 1] = n end end
  if #names == 0 then return nil end
  table.sort(names)
  local parts, exp = {}, nil
  for _, n in ipairs(names) do
    parts[#parts + 1] = n .. "=" .. d[n].value
    if not exp or d[n].expires < exp then exp = d[n].expires end
  end
  return table.concat(parts, "; "), exp
end

-- WebKit flushes the jar to disk lazily (~10 s observed). Poll until the
-- wanted cookies appear or timeoutS passes. cb(header|nil, expires, domainCookies)
function M.waitFor(domain, prefix, timeoutS, cb)
  local t0 = hs.timer.secondsSinceEpoch()
  local t
  t = hs.timer.doEvery(1, function()
    local jar = M.readJar()
    local ck, exp = M.pick(jar, domain, prefix)
    if ck then
      t:stop(); cb(ck, exp, jar[domain])
    elseif hs.timer.secondsSinceEpoch() - t0 > timeoutS then
      t:stop(); cb(nil)
    end
  end)
end

-- Removes every cookie for `domain` from the shared datastore so the next
-- login window starts signed out. Takes ~10 s to reach the on-disk file.
function M.wipe(domain, cb)
  hs.webview.datastore.default():removeRecordsFor(domain, "WKWebsiteDataTypeCookies", cb or function() end)
end

-- Replaces (or appends) name=value pairs in an existing Cookie header.
function M.mergeCookie(header, updates)
  local seen, parts = {}, {}
  for pair in (header or ""):gmatch("[^;]+") do
    local n, v = pair:match("^%s*([^=]+)=(.*)$")
    if n then
      if updates[n] then v = updates[n]; seen[n] = true end
      parts[#parts + 1] = n .. "=" .. v
    end
  end
  for n, v in pairs(updates) do
    if not seen[n] then parts[#parts + 1] = n .. "=" .. v end
  end
  return table.concat(parts, "; ")
end

-- Pulls rotated cookies (name starts with prefix) out of a response's
-- Set-Cookie header. NSHTTPURLResponse joins several Set-Cookie lines
-- with ", "; token values carry neither commas nor semicolons.
function M.setCookies(headers, prefix)
  local sc = headers["Set-Cookie"] or headers["set-cookie"]
  if not sc then return nil end
  local out, any = {}, false
  local esc = prefix:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
  for name, value in sc:gmatch("(" .. esc .. "[%w%.%-_]*)=([^;,]+)") do
    out[name] = value; any = true
  end
  return any and out or nil
end

---------------------------------------------------------------------
-- HTTP
---------------------------------------------------------------------

-- cb(status, body, headers). status 0 = transport failure.
function M.request(method, url, cookie, headers, body, cb)
  headers = headers or {}
  headers["User-Agent"] = M.UA
  if cookie then headers["Cookie"] = cookie end
  hs.http.doAsyncRequest(url, method, body, headers, function(st, b, h)
    cb(st or 0, b or "", h or {})
  end)
end

function M.get(url, cookie, headers, cb) return M.request("GET", url, cookie, headers, nil, cb) end

function M.json(body)
  local ok, v = pcall(hs.json.decode, body)
  return ok and type(v) == "table" and v or nil
end

-- Maps a non-200 to widget status. A JSON 401/403 is the service saying the
-- session is gone; an HTML 403 is Cloudflare (or an outage), not a logout.
function M.failure(what, status, body)
  if status == 0 then
    return { status = "error", errorMsg = what .. ": network error",
             warnings = { "Request to " .. what .. " failed (offline?)" } }
  end
  if (status == 401 or status == 403) and M.json(body) then
    return { status = "needs_login" }
  end
  return { status = "error", errorMsg = what .. ": HTTP " .. status,
           warnings = { what .. " returned HTTP " .. status .. (M.json(body) and "" or " (non-JSON body, Cloudflare challenge?)") } }
end

return M
