-- Self-check for the pure parts of session.lua. Run inside Hammerspoon:
--   hs -c 'dofile("<repo>/test_session.lua")'
-- Never prints cookie values.
local dir = debug.getinfo(1, "S").source:match("^@(.*)/[^/]+$")
package.path = dir .. "/../?.lua;" .. dir .. "/../?/init.lua;" .. package.path
local name = dir:match("([^/]+)$")
local session = require(name .. ".session")

-- mergeCookie: replaces in place, appends new, keeps order.
assert(session.mergeCookie("a=1; b=2", { b = "9" }) == "a=1; b=9")
assert(session.mergeCookie("a=1", { c = "3" }) == "a=1; c=3")
assert(session.mergeCookie(nil, { c = "3" }) == "c=3")

-- setCookies: chunked NextAuth names, comma-joined Set-Cookie lines, Expires with commas.
local h = { ["Set-Cookie"] = "__Secure-next-auth.session-token.0=AAA; Path=/; Expires=Wed, 06 Sep 2026 00:00:00 GMT; HttpOnly, __Secure-next-auth.session-token.1=BBB; Path=/, other=zzz" }
local sc = session.setCookies(h, "__Secure-next-auth.session-token")
assert(sc["__Secure-next-auth.session-token.0"] == "AAA" and sc["__Secure-next-auth.session-token.1"] == "BBB" and sc.other == nil)
assert(session.setCookies({}, "x") == nil)

-- pick: prefix match, sorted, earliest expiry.
local jar = { ["claude.ai"] = { sessionKey = { value = "k", expires = 200 }, sessionKeyV3 = { value = "v3", expires = 100 }, other = { value = "o", expires = 1 } } }
local ck, exp = session.pick(jar, "claude.ai", "sessionKey")
assert(ck == "sessionKey=k; sessionKeyV3=v3" and exp == 100, ck)
assert(session.pick(jar, "nope", "x") == nil)

-- parseJar: synthetic one-page, one-cookie file in Apple binarycookies layout.
local function cookieRecord(dom, nm, path, val, expires)
  local hdr = 32 + 8 + 16  -- 8 i32, 8-byte end marker, 2 doubles
  local domOff, nmOff, pathOff, valOff = hdr, hdr + #dom + 1, hdr + #dom + 1 + #nm + 1, hdr + #dom + 1 + #nm + 1 + #path + 1
  local size = valOff + #val + 1
  return string.pack("<i4i4i4i4i4i4i4i4", size, 0, 5, 0, domOff, nmOff, pathOff, valOff)
      .. string.pack("<i8dd", 0, expires - 978307200, 0)
      .. dom .. "\0" .. nm .. "\0" .. path .. "\0" .. val .. "\0"
end
local rec = cookieRecord(".example.com", "tok", "/", "secret", 2000000000)
local page = string.pack("<i4i4i4", 0x00000100, 1, 12) .. rec .. string.pack("<i4", 0)
local file = "cook" .. string.pack(">i4i4", 1, #page) .. page
local parsed = session.parseJar(file)
assert(parsed["example.com"] and parsed["example.com"].tok.value == "secret", "parseJar synthetic")
assert(parsed["example.com"].tok.expires == 2000000000)
assert(next(session.parseJar("nope")) == nil)

-- grok: grpc-web-text response captured 2026-09-07 (weekly pool, 0% used, period ends 2026-09-13 17:42:45Z).
local grok = require(name .. ".grok")
local g = grok.decodeCredits("AAAAAEgKRhIAGgAiDAiVzPbUBhCY2uzWAioMCJXBm9UGEJja7NYCQh4IAhIMCJXM9tQGEJja7NYCGgwIlcGb1QYQmNrs1gJYAWIAaAE=gAAAAA9ncnBjLXN0YXR1czowDQo=")
assert(g.status == "ok", g.errorMsg)
assert(g.weekly.percentUsed == 0 and g.weekly.resetsAt == 1789321365 and g.weekly.periodType == "weekly", hs.inspect(g.weekly))
assert(g.fiveHour == nil and #g.additional == 0)
-- trailers-only unauthenticated → needs_login
assert(grok.decodeCredits("gAAAABBncnBjLXN0YXR1czoxNg0K").status == "needs_login")

-- grokbot: Connect-JSON shape from cursor.com's dashboard proxy.
local grokbot = require(name .. ".grokbot")
local gb = grokbot.mapResponse({ usagePercent = 12.4, nextResetTimestampUtc = "2026-09-12T18:49:00Z", currentPeriodStart = "2026-09-05T18:49:00Z", hasNonZeroIncludedLimit = true })
assert(gb.status == "ok" and gb.weekly.percentUsed == 12 and gb.weekly.resetsAt and gb.weekly.resetsAt > 1789000000, hs.inspect(gb))
assert(grokbot.mapResponse({}).status == "error")

-- claude: per-model weekly caps come out of limits[] (shape captured 2026-09-09),
-- with the legacy seven_day_<model> keys as fallback.
local claude = require(name .. ".claude")
local usage = {
  five_hour = { utilization = 8.0, resets_at = "2026-09-09T07:39:59Z" },
  seven_day = { utilization = 50.0, resets_at = "2026-09-14T04:59:59Z" },
  seven_day_sonnet = nil,
  limits = {
    { kind = "session", group = "session", percent = 8 },
    { kind = "weekly_all", group = "weekly", percent = 50 },
    { kind = "weekly_scoped", group = "weekly", percent = 28,
      resets_at = "2026-09-14T04:59:59Z", scope = { model = { display_name = "Fable" } } },
  },
}
local c = claude.mapResponse(usage, nil, {})
assert(c.status == "ok" and #c.additional == 1, hs.inspect(c.additional))
assert(c.additional[1].label == "Fable" and c.additional[1].weekly.percentUsed == 28
       and c.additional[1].weekly.percentLeft == 72 and c.additional[1].fiveHour == nil)
usage.limits = nil
usage.seven_day_opus = { utilization = 12.0, resets_at = "2026-09-14T04:59:59Z" }
local legacy = claude.mapResponse(usage, nil, {})
assert(#legacy.additional == 1 and legacy.additional[1].label == "Opus"
       and legacy.additional[1].weekly.percentUsed == 12, hs.inspect(legacy.additional))

-- Real jar parses without throwing (contents not asserted, machine-specific).
local real = session.readJar()
assert(type(real) == "table")

print("test_session: OK")
return "test_session: OK"
