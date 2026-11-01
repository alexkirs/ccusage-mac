---
name: update-readme
description: Refresh the live menu bar screenshot (docs/menubar-accounts.png) and synchronize provider/account documentation in README.md.
---

# Update README Screenshot & Info

Use this procedure whenever a provider is added/changed or the menu bar visual layout is updated.

## Steps

1. **Ensure Hammerspoon is running** with all target accounts visible (`status = "ok"`).
2. **Run the screenshot & README updater script**:
   ```bash
   ./docs/update-readme.sh
   ```
   This script:
   - Calls `menubar.applyAllTitles()` inside Hammerspoon and grabs `menubar.bar:icon()`.
   - Composites the live strip onto a dark `#222222` menu bar background (`6pt` horizontal padding, `4pt` vertical padding) and writes a 2x Retina PNG to `docs/menubar-accounts.png`.
   - Updates the `<img src="docs/menubar-accounts.png" alt="..." width="...">` tag in `README.md` with the current visible accounts, labels/tags, sensors, and scaled display width.
3. **Verify provider table in `README.md`**:
   - Check that every provider in `menubar.PROVIDER_ORDER` (`claude`, `codex`, `gemini`, `grok`, `grokbot`) is listed in the `Works with:` table in `README.md` with accurate login and quota window details.
