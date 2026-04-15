# claude-usage

Menu bar widget for macOS that shows Claude's **5-hour** and **weekly** usage limits — percent remaining and reset time — scraped from [`claude.ai/settings/usage`](https://claude.ai/settings/usage). Updates every 60 seconds. Click the menu bar to see reset times and trigger actions.

Built as a [Hammerspoon](https://www.hammerspoon.org/) Lua module. No Xcode, no signing, no bundled browser. Uses system WebKit via `hs.webview`; cookies persist after a one-time login.

## Why

Anthropic doesn't expose usage limits via public API. The only source is the settings page, which is behind login + Cloudflare. A real browser engine is required. Hammerspoon gives us `hs.menubar` + `hs.webview` + persistent timers in ~300 lines of Lua — no native Mac UI boilerplate, no launchd plist (Hammerspoon autostarts itself).

## Install

```bash
brew install --cask hammerspoon
./install.sh
```

`install.sh` symlinks this repo to `~/.hammerspoon/claude_usage` and appends `require("claude_usage")` to `~/.hammerspoon/init.lua`.

Then:

1. Launch **Hammerspoon** (first run will prompt for Accessibility permission).
2. Menu bar → Hammerspoon icon → **Reload Config** (or `⌘⌥⌃R`).
3. A new menu bar item appears as `⚠ login`.
4. Click it → **Log in…** → a Safari-like window opens at claude.ai → log in normally → close it.
5. Values appear within ~60s, or click **Refresh now**.

Autostart is free: Hammerspoon launches at login (macOS Login Items), our module loads with it.

## Menu bar title

A single leading glyph reflects the worse of the two windows:

| Worst % left | Glyph |
|---:|:-:|
| > 50% | `●` |
| 20 – 50% | `◐` |
| 5 – 20% | `◔` |
| < 5% | `○` |
| error / needs login | `⚠` |

Three display formats, toggle via **Display format**:

- `compact` (default): `● 45/72`
- `labeled`: `● 5h·45 1w·72`
- `verbose`: `● 5h 45% · 1w 72%`

## Click behavior

- **Left click** → full submenu: per-window details, refresh, display format, debug, quit.
- **Ctrl-click** or **Alt-click** → compact two-line summary with reset times.

## Debug menu

Built in from day one so iteration is cheap after launch:

| Item | Effect |
|---|---|
| Open Hammerspoon console | See live logs |
| Save artifacts | Writes `last.html`, `last.txt`, `last-parsed.json` to `~/.hammerspoon/claude_usage/debug/` every fetch. Failed fetches also keep timestamped copies (last 10). |
| Show fetch webview | Next fetch shows the webview on-screen (normally 1×1 off-screen). See Cloudflare challenges, redirects, lazy-loaded content. |
| Keep fetch webview open | Webview stays open after extraction for manual DevTools inspection. |
| Force re-fetch | Bypass 60s timer, fetch now. |
| Copy state JSON | Current snapshot → clipboard. |
| Copy fetch log | In-memory 200-line ring buffer → clipboard. |
| Open debug dir | Open `~/.hammerspoon/claude_usage/debug/` in Finder. |
| Set replay HTML… | Point the parser at a saved HTML file; no network, no webview. Iterate on parsing against a known snapshot. |
| Clear cookies | Wipe Hammerspoon's WebKit data. Requires relaunch. |
| Reload module (hot) | Unload + re-require without restarting Hammerspoon. |
| Log level | Cycle info → debug → verbose → warning → error → info. |

## Architecture

```
~/.hammerspoon/claude_usage/     (symlink → this repo)
  init.lua     entry: requires + starts menubar module
  state.lua    in-memory snapshot, log ring, fetch-timing average
  scraper.lua  hs.webview fetch, JS DOM extraction, replay mode, artifact capture, login flow, cookie wipe
  menubar.lua  hs.menubar wiring, title formatter, full + minimal menus, Debug submenu, timers
```

### Fetch flow

1. `hs.webview.new` (off-screen 1×1, or on-screen if `Debug → Show fetch webview`).
2. Navigate to `/settings/usage`. Cookies auto-persist via default `WKWebsiteDataStore`.
3. On `didFinishNavigation`, run `EXTRACT_JS`: detect login redirect, read `document.body.innerText`, pull all `\d{1,3}%` matches, grab `document.documentElement.outerHTML` for debugging.
4. Lua parses JSON result. If 2+ percents → assume `[fiveHour, weekly]`. If on `/login` → `status = "needs_login"`.
5. Timeout at 25s. On failure, last known values stay shown, title glyph becomes `⚠`.

### Replay mode

`Debug → Set replay HTML…` stores a path in `hs.settings`. Next fetch reads that file instead of hitting the network. Good for refining parser against saved snapshots while offline.

### Login flow

`scraper.interactiveLogin()` opens a visible 820×900 webview at `/settings/usage`. WebKit handles the login UI; cookies go into the shared data store. A 1 Hz poll detects window close and triggers a background refresh.

## Known gaps / future work

- **DOM selectors are heuristic.** Parser currently takes the first two `\d+%` matches as `[5h, 1w]`. This is fragile. First real run: enable **Save artifacts**, inspect `last.html`, pin stable selectors in `scraper.lua:EXTRACT_JS` and refine `parseUsage()`.
- **Reset times** are extracted only as raw strings (e.g. "2h 14m"); `resetsAt` unix epoch stays `nil`. Parse once DOM shape is known so the menu can show both "resets in 2h 14m" *and* the absolute clock time.
- **SPA lazy-load**: if the page paints empty numbers that fill in asynchronously, add a `MutationObserver` or a short retry loop inside `EXTRACT_JS`.
- **Per-site cookie clearing**: `hs.webview` doesn't expose it; we nuke Hammerspoon's entire WebKit folder and ask the user to relaunch. Acceptable trade-off.
- **Right-click**: macOS convention is ctrl-click; we map ctrl/alt to the minimal menu since `hs.menubar` doesn't distinguish true right-click cleanly.

## Uninstall

```bash
rm ~/.hammerspoon/claude_usage
# edit ~/.hammerspoon/init.lua and remove the require("claude_usage") line
# reload Hammerspoon
```

## License

MIT.
