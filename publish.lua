-- Publishes the strip to an HTTP endpoint (web/worker.js on Cloudflare) so a
-- phone can read the same numbers the menubar shows.
--
--   POST <publish.url>  X-Token: <publish.token>
--   { ts, blocks: [ { label, tag, text?, w5h?, w1w?, resetsAt?, resets? } ] }
--
-- Blocks come from menubar's own instance.blocks(), so account order, hidden
-- accounts, tags and the Spark block follow the strip with no second source.
--
-- Enable:
--   hs -c 'require("claude_usage.state").set("publish.url", "https://limits.kirs.online/push")'
--   hs -c 'require("claude_usage.state").set("publish.token", "<secret>")'
local PREFIX = ((...) or "claude_usage"):gsub("%.[^.]+$", "")
local state = require(PREFIX .. ".state")
local log = state.logger("publish")

local M = {
  period = 60,      -- how often the payload is rebuilt
  heartbeat = 600,  -- force a push this often even when nothing changed
}

local timer, lastSig, lastSent = nil, nil, 0

local function blocks(menubar)
  local out = {}
  for _, a in ipairs(menubar.accounts) do
    local inst = menubar.instances[a.id]
    if inst then
      for _, b in ipairs(inst.blocks()) do
        local win = b.w5h or b.w1w
        out[#out + 1] = {
          label = b.label, tag = b.tag, text = b.text,
          w5h = b.w5h and b.w5h.percentUsed,
          w1w = b.w1w and b.w1w.percentUsed,
          resetsAt = win and win.resetsAt,
          resets = (b.resets or 0) > 0 and b.resets or nil,
        }
      end
    end
  end
  return out
end

-- Deterministic fingerprint. hs.json.encode does not promise key order, so the
-- payload itself is no good for "did anything change".
local function sig(list)
  local parts = {}
  for _, b in ipairs(list) do
    parts[#parts + 1] = table.concat({ b.label or "", b.tag or "", b.text or "",
      b.w5h or "", b.w1w or "", b.resetsAt or "", b.resets or "" }, "|")
  end
  return table.concat(parts, "\n")
end

local function push(menubar)
  local url, token = state.get("publish.url"), state.get("publish.token")
  if not (url and token) then return end
  local list = blocks(menubar)
  local s, now = sig(list), os.time()
  if s == lastSig and now - lastSent < M.heartbeat then return end
  hs.http.doAsyncRequest(url, "POST", hs.json.encode({ ts = now, blocks = list }),
    { ["Content-Type"] = "application/json", ["X-Token"] = token },
    function(st, b)
      if st == 200 then lastSig, lastSent = s, now
      else log.w("push failed st=" .. tostring(st) .. " " .. tostring(b)) end
    end)
end

function M.start(menubar)
  if timer then timer:stop() end
  timer = hs.timer.doEvery(M.period, function() push(menubar) end)
  M.pushNow = function() push(menubar) end
end

function M.stop() if timer then timer:stop(); timer = nil end end

return M
