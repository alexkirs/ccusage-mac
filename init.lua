-- Claude / Codex usage menubar widget for Hammerspoon.
-- Entry: `require("claude_usage")` from ~/.hammerspoon/init.lua
-- One menubar strip, one block per account in the registry (state.accounts()).
local PREFIX = (...) or "claude_usage"
local state = require(PREFIX .. ".state")
local session = require(PREFIX .. ".session")
local menubar = require(PREFIX .. ".menubar")

local accounts = state.accounts()

-- First run (or migration from the webview era): adopt whatever sessions the
-- shared jar already holds, one account per provider. Nothing there → an
-- empty "+" strip; accounts come in via Add account.
if #accounts == 0 then
  local jar = session.readJar()
  for _, pid in ipairs(menubar.PROVIDER_ORDER) do
    local p = menubar.PROVIDERS[pid]
    local ck, exp = session.pick(jar, p.domain, p.cookiePrefix)
    if ck then
      local acct = { id = pid, provider = pid, cookie = ck, cookieExpires = exp }
      if p.afterLogin then p.afterLogin(acct, jar[p.domain]) end
      accounts[#accounts + 1] = acct
    end
  end
  state.saveAccounts(accounts)
end

menubar.accounts = accounts
menubar.ensureBar()
for _, acct in ipairs(accounts) do menubar.start(acct) end

return menubar
