# ccusage-mac

Your AI subscription limits in the macOS menu bar. One strip, one block per account.

<p align="center">
  <img src="docs/menubar-accounts.png" alt="menu bar: claude · grokb · two codex accounts (one tagged cod2) · 52° + load graph" width="300">
</p>

Each block: **% used** (5-hour · weekly, or just weekly) and **time until reset**
(`h:mm`, or `Nd` when it's more than a day away).
Plain until 50 %, then yellow → orange → red as you burn through the limit.

Works with:

| Service | What it shows |
|---|---|
| **Claude** (claude.ai) | 5h and weekly limits, extra usage on/off |
| **Codex** (chatgpt.com) | weekly limit, Spark per-model limit (via Codex CLI login) |
| **Grok** (grok.com) | SuperGrok weekly pool |
| **Grok Bot** (cursor.com) | Grok Bot weekly allowance |

Any number of accounts per service. Refreshes every 60 s.

Codex accounts sign in through the [Codex CLI](https://github.com/openai/codex)
(`codex login --device-auth`), so the `codex` command must be installed. Each
account gets its own isolated login, independent of whatever your terminal
`codex` is logged into, so several Codex accounts show side by side.
Limit-reset credits, when the plan has any, show as a gold count in the
block's bottom-right corner.

## Install

1. Install [Hammerspoon](https://www.hammerspoon.org/) (a free macOS automation app the widget runs inside):

   ```bash
   brew install --cask hammerspoon
   ```

2. Install the widget:

   ```bash
   git clone https://github.com/alexkirs/ccusage-mac.git ~/.hammerspoon/claude_usage
   echo 'require("claude_usage")' >> ~/.hammerspoon/init.lua
   ```

3. Open **Hammerspoon** from Applications. Allow Accessibility when it asks.

4. A `+` appears in the menu bar. Click it → **Add account** → pick a service → sign in → close the window.

5. So it survives a reboot: click the Hammerspoon hammer icon in the menu bar → **Preferences…** → tick **Launch Hammerspoon at login**.

That's it. Numbers show up within a minute.

## Add more accounts

Same thing again: **Add account** → pick a service → sign in.
Each account gets its own block in the strip and its own submenu: usage
detail, log out, rename the label (up to 7 letters), tag it (1–2 violet
chars glued to the label, to tell `codex1` from `codex2`), hide the block (keeps
the session, frees menu bar space), remove it. Hide every block and the
strip shrinks back to `+`.

Ctrl-click or Alt-click the strip for a flat summary of every account.

## CPU load & temperature (optional)

Menu → **CPU load graph** adds a 40-second bar graph (one bar per 2 s, each
colored by its load); **CPU temperature** adds the CPU reading, e.g. `62°`,
the same number Hot.app shows (hottest SMC `Tp*` key), colored by system
thermal pressure like Hot does. Both are off by default and cost nothing while
off. Temperature needs Apple Silicon and the Xcode command-line tools
(`xcode-select --install`): a 60-line helper (`sensors.c`) is compiled once on
first use.

## Good to know

- Sessions expire when the site says so (Claude ~30 days, others longer). The block turns into `⚠`; open its submenu and sign in again.
- Sign-in happens in a normal browser window inside Hammerspoon. Your Safari/Chrome logins are not touched.
- The widget updates itself from this repo daily (menu → **Updates** to turn that off).

## Uninstall

```bash
rm -rf ~/.hammerspoon/claude_usage
```

and delete the `require("claude_usage")` line from `~/.hammerspoon/init.lua`.

## License

MIT.
