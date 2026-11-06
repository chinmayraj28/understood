#!/bin/bash
# Installs Handsfree as an ordinary Mac app, so it can be opened from the Applications
# folder, Launchpad or Spotlight like any other app, with no terminal.
#
#   scripts/install_app.sh            build it, then install it
#   scripts/install_app.sh --no-build install the app that is already in build/
#
# What it does:
#   1. Builds build/Handsfree.app (signed), unless --no-build is given.
#   2. Copies it to /Applications/Handsfree.app, replacing an older copy.
#   3. Makes your keys findable by the installed app. An app opened from Finder does not
#      know where this repo is, so it looks for its settings in
#      ~/Library/Application Support/Handsfree/.env. This script points that at the repo's
#      .env with a link, so there is still only one file holding your keys.
#
# macOS remembers the Microphone, Accessibility and Screen Recording permissions by the
# app's identity (its bundle ID and signing certificate), not by where it lives, so
# installing a newer build over an older one keeps them.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BUILT_APP="$REPO/build/Handsfree.app"
INSTALLED_APP="/Applications/Handsfree.app"
SUPPORT_DIR="$HOME/Library/Application Support/Handsfree"

if [ "${1:-}" != "--no-build" ]; then
  "$REPO/scripts/build_app.sh"
fi

if [ ! -d "$BUILT_APP" ]; then
  echo "There is no built app at $BUILT_APP. Run scripts/build_app.sh first." >&2
  exit 1
fi

if pgrep -f "Handsfree.app/Contents/MacOS/Handsfree" >/dev/null; then
  echo "Handsfree is running. Quit it first (the Quit button at the bottom of its panel), then run this again." >&2
  exit 1
fi

echo "==> Installing to $INSTALLED_APP"
rm -rf "$INSTALLED_APP"
# ditto keeps the code signature intact, which a plain copy can damage.
ditto "$BUILT_APP" "$INSTALLED_APP"
codesign --verify --deep --strict "$INSTALLED_APP"
echo "    Signature valid."

echo "==> Making your keys findable"
mkdir -p "$SUPPORT_DIR"
chmod 700 "$SUPPORT_DIR"
if [ -f "$REPO/.env" ]; then
  ln -sfn "$REPO/.env" "$SUPPORT_DIR/.env"
  echo "    $SUPPORT_DIR/.env now points at $REPO/.env"
else
  echo "    No .env in the repo yet. Copy .env.example to .env, fill in the keys, and run this again." >&2
fi

cat <<'EOF'

Installed. To start it: open the Applications folder and double-click Handsfree,
or press Command+Space, type Handsfree and press Return.

It has no Dock icon and no window. A dark panel opens near the top of the screen the
first time, listing the permissions it still needs, each with a button. If you cannot
see its menu bar icon (it can hide behind the MacBook's notch), open Handsfree again
and the panel comes back.
EOF
