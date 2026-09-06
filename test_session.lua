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

-- Real jar parses without throwing (contents not asserted, machine-specific).
local real = session.readJar()
assert(type(real) == "table")

print("test_session: OK")
return "test_session: OK"
