#!/usr/bin/env bash
# Regenerates docs/menubar-accounts.png from the live Hammerspoon menubar strip
# and updates the <img> alt text and width in README.md to match visible accounts.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HS_BIN="${HS_BIN:-/Applications/Hammerspoon.app/Contents/Frameworks/hs/hs}"

if [ ! -x "$HS_BIN" ]; then
  if command -v hs >/dev/null 2>&1; then
    HS_BIN="$(command -v hs)"
  else
    echo "error: Hammerspoon CLI (hs) not found" >&2
    exit 1
  fi
fi

"$HS_BIN" -c "
local repo = [[$REPO_DIR]]
local m = require('claude_usage.menubar')
local s = require('claude_usage.sensors')
m.applyAllTitles()
local icon = m.bar and m.bar:icon()
assert(icon, 'menubar has no icon (no visible accounts?)')

local sz = icon:size()
local padX, padY = 6, 4
local w, h = sz.w + padX * 2, sz.h + padY * 2
local c = hs.canvas.new({ x = 0, y = 0, w = w, h = h })
c:appendElements(
  { type = 'rectangle', action = 'fill', frame = { x = 0, y = 0, w = w, h = h }, fillColor = { hex = '#222222', alpha = 1 } },
  { type = 'image', image = icon, frame = { x = padX, y = padY, w = sz.w, h = sz.h } }
)
local img = c:imageFromCanvas()
c:delete()
local pngPath = repo .. '/docs/menubar-accounts.png'
assert(img:saveToFile(pngPath), 'failed to write ' .. pngPath)

-- Build human-readable alt description from active visible accounts + sensors.
local parts = {}
for _, a in ipairs(m.accounts) do
  if not a.hidden then
    local p = m.PROVIDERS[a.provider]
    local lbl = (a.label or (p and p.label) or a.provider) .. (a.tag or '')
    if lbl ~= a.provider then
      parts[#parts + 1] = a.provider .. ' (' .. lbl .. ')'
    else
      parts[#parts + 1] = lbl
    end
  end
end
local tail = {}
if s.tempOn() then tail[#tail + 1] = 'CPU temp' end
if s.graphOn() then tail[#tail + 1] = 'load graph' end
if #tail > 0 then parts[#parts + 1] = table.concat(tail, ' + ') end

local alt = 'menu bar: ' .. table.concat(parts, ' · ')
local displayW = math.floor(w * 2.4 + 0.5)

local readmePath = repo .. '/README.md'
local fh = assert(io.open(readmePath, 'r'))
local readme = fh:read('a')
fh:close()

local updated, n = readme:gsub(
  '<img src=\"docs/menubar%-accounts%.png\"[^>]*>',
  string.format('<img src=\"docs/menubar-accounts.png\" alt=\"%s\" width=\"%d\">', alt, displayW),
  1
)
if n > 0 and updated ~= readme then
  local out = assert(io.open(readmePath, 'w'))
  out:write(updated)
  out:close()
end

print(string.format('Updated docs/menubar-accounts.png (%dx%d pt, width=%d) and README.md alt=%q', w, h, displayW, alt))
"
