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
  scraper.lua  hs.webview lifecycle: navigation, reload, login, cookie wipe
  fetcher.lua  React Query reader: walks fiber, calls refetchQueries, reads JSON
  menubar.lua  hs.menubar wiring, title formatter, full + minimal menus, Debug submenu, timers
```

### Data path

The widget reads the SPA's in-memory **TanStack QueryClient** via React fiber
traversal. On every tick:

1. `fetcher.fetch` → `scraper.ensureLoaded` guarantees the persistent WV is
   at `/settings/usage`.
2. A JS snippet walks the fiber tree to find the QueryClient (cached on
   `window.__cu.qc` after the first walk), then calls
   `refetchQueries({queryKey:["unified_limits_utilization"]})` and
   `refetchQueries({queryKey:["overage_spend_limit"]})` in parallel.
3. Once the promises resolve, the snippet reads three queries out of the
   cache: `unified_limits_utilization`, `overage_spend_limit`, and
   `current_account`.
4. Lua decodes the JSON, maps ISO timestamps to epochs, and updates state.

Anthropic's actual API URL / auth / CSRF are all handled by the SPA's own
`queryFn` — the widget never has to replicate any of that.

**No fallback**: if the fiber walk breaks, the widget surfaces a specific
actionable warning (e.g. "SPA changed React internals, or a query key was
renamed") in the menu rather than quietly failing over to a worse path.

Enable `Debug → Dump fetcher response` to write the decoded JSON to
`~/.hammerspoon/claude_usage/debug/last-fetcher.json` for forensics.

### Fetch flow

One persistent `hs.webview` is created on first tick and kept alive. It's
shown borderless at `(−9000, −9000)` 900×900 — WKWebView pauses JS on views
that were never `:show()`n, so we have to render off-screen-but-visible.

| Path | When | Cost |
|---|---|---|
| **Cold** | First fetch (no WV yet) | Create WV, navigate to `/settings/usage`, wait for `didFinishNavigation`, fetcher JS waits for React mount (up to 6 s), then one refetch round-trip. ~1–2 s total. |
| **Warm** | Every tick thereafter | Fetcher JS re-enters — `window.__cu.qc` is cached, so no fiber walk. `Promise.all([refetchQueries, refetchQueries])` + read three queries. **~400 ms**, matches the SPA's own cadence. |
| **Safety reload** | `now − scraper.lastNavAt() > 3 h` | `wv:reload()` before the next warm tick, to keep the long-lived WV + React heap fresh. |

A single `navigationCallback` is attached to the persistent WV once;
per-navigation routing uses a `pendingNav` handler that fires then clears
itself, so back-to-back reloads never cross-talk.

`fetcher.fetch`'s 20 s timeout is a safety net — if the JS-side poll loop
waits 6 s for React mount and the subsequent refetch takes another few
seconds, we still finish well inside the budget.

### Parser (bulletproof-ish)

Anthropic can rename sections, reorder blocks, add new tiers — the parser stops trying to match exact labels:

1. **Tokenize** innerText into trimmed non-empty lines, tagging each with `hasPct`, `hasDollar`, `hasReset`.
2. **Extract triples**: for every line starting with `Reset…`, find the nearest `N% used` line within a 10-line window (forward, then backward). Attach the nearest short, non-data preceding line as `heading`.
3. **Classify by shape** of the reset string:
   - Contains `hr/min/sec/day` or equals `now` → `fiveHour`
   - `<Weekday> HH:MM [AM|PM]` → `weekly` (or `weeklySonnet` / `weeklyOpus` / `weeklyHaiku` if heading matches a model keyword)
   - `<Month> DD` or any triple with `$` within 5 lines → `spend` bucket (never mistaken for usage)
   - Otherwise → `unknown` (warning emitted with heading + values)
4. **Parse reset shape to `resetsAt` epoch**: duration addition, next-occurrence weekday+time, or next-occurrence month+day.
5. **Hard errors** if no duration-reset block OR no weekday-reset block found (= Anthropic redesign, alert user).
6. **Soft warnings** for: any unclassified triple, unparseable reset string, missing landmark (`"Plan usage limits"`, `"Weekly limits"`).

`parser.lua` is pure Lua with no Hammerspoon dependency, so it's trivially testable in isolation (e.g. via `hs -c` against a saved `last.txt`).

### Replay mode

`Debug → Set replay HTML…` points the parser at a saved file. Same `parser.parse` path — no webview, no network. Perfect for iterating on classification rules against real snapshots.

### Login flow

`scraper.interactiveLogin()` opens a visible 820×900 webview at `/settings/usage`. WebKit handles the login UI; cookies go into the shared data store. A 1 Hz poll detects window close and triggers a background refresh.

## Known limitations (OS / library level)

- **Per-site cookie clearing**: `hs.webview` doesn't expose `WKWebsiteDataStore` per-site removal. Cookie wipe nukes Hammerspoon's entire WebKit folder and requires a relaunch.
- **Right-click**: macOS convention is ctrl-click; we map ctrl/alt-click to the minimal menu since `hs.menubar` doesn't distinguish a true right-click cleanly.
- **English-only**: reset-string shape detection currently assumes English weekday/month names. Add locale tables to `parser.lua:WEEKDAYS`/`MONTHS` if needed.

## Uninstall

```bash
rm ~/.hammerspoon/claude_usage
# edit ~/.hammerspoon/init.lua and remove the require("claude_usage") line
# reload Hammerspoon
```

## License

MIT.
