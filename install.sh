#!/bin/bash
# Install claude_usage into ~/.hammerspoon as a symlink to this repo.
# Hammerspoon must be installed: `brew install --cask hammerspoon`.
set -euo pipefail

HS_DIR="$HOME/.hammerspoon"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$HS_DIR/claude_usage"
INIT="$HS_DIR/init.lua"

mkdir -p "$HS_DIR"

if [ -L "$TARGET" ]; then
  rm "$TARGET"
elif [ -e "$TARGET" ]; then
  echo "Refusing to overwrite non-symlink at $TARGET" >&2
  echo "Move or remove it manually, then rerun." >&2
  exit 1
fi

ln -s "$REPO_DIR" "$TARGET"
echo "linked $TARGET -> $REPO_DIR"

touch "$INIT"
if ! grep -q 'require("claude_usage")' "$INIT"; then
  printf '\nrequire("claude_usage")\n' >> "$INIT"
  echo "added require to $INIT"
else
  echo "require already in $INIT"
fi

mkdir -p "$TARGET/debug"

cat <<EOF

Done. Next:
  1. Launch or reload Hammerspoon (menu bar → Reload Config, or cmd+opt+ctrl+R).
  2. Menu bar item appears as '⚠ login'. Click it → 'Log in…'.
  3. Log in to claude.ai in the window that opens, then close it.
  4. Values appear within ~60s (or click 'Refresh now').

Debug menu exposes: save artifacts, replay mode, visible fetch webview,
state/log clipboard copy, force refetch, cookie wipe, hot reload.
EOF
