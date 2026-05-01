-- Claude Usage menubar widget for Hammerspoon.
-- Entry: `require("claude_usage")` from ~/.hammerspoon/init.lua
-- Two menubar icons: Claude (claude.ai) on the left, Codex (chatgpt.com) on the right.
local menubar = require("claude_usage.menubar")
local data = require("claude_usage.data")
local codexData = require("claude_usage.codex_data")

menubar.start({ provider = data.makeProvider() })
menubar.start({ provider = codexData.makeProvider() })

return menubar
