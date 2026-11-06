#!/usr/bin/env bash
# Launches build/Handsfree.app. Any options are passed to the app:
#
#   scripts/run_app.sh                         normal start (voice, overlay, menu bar)
#   scripts/run_app.sh --demo                  play the scripted demo once, no network, no permissions
#   scripts/run_app.sh --demo --backdrop       the demo over a neutral practice backdrop (for recording)
#   scripts/run_app.sh --demo --loop           repeat the demo until quit
#   scripts/run_app.sh --demo --freeze holding stop at one state and hold it (for screenshots)
#   scripts/run_app.sh --quit-after 20         quit by itself after 20 seconds
#   scripts/run_app.sh --show-panel            open the menu bar panel at launch
#   scripts/run_app.sh --request-permissions   ask macOS for Microphone, Accessibility and Screen Recording
#   scripts/run_app.sh --capturable            let screenshots include the overlay (design review only)
#   scripts/run_app.sh --wait ...              block until the app quits
#
# The app is started with `open`, not by running the binary from this shell.
# That matters: a program started directly from a terminal counts, for macOS
# privacy, as part of the terminal, so permission prompts and grants would go
# to the terminal app instead of Handsfree.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$REPO_ROOT/build/Handsfree.app"

if [ ! -d "$APP_PATH" ]; then
  echo "build/Handsfree.app does not exist yet. Run scripts/build_app.sh first." >&2
  exit 1
fi

WAIT_FLAG=()
APP_ARGUMENTS=()
for argument in "$@"; do
  if [ "$argument" = "--wait" ]; then WAIT_FLAG=(-W); else APP_ARGUMENTS+=("$argument"); fi
done

# Only one copy at a time: two overlays would draw two companions.
if pgrep -x Handsfree >/dev/null 2>&1; then
  pkill -x Handsfree || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Handsfree >/dev/null 2>&1 || break; sleep 0.2; done
fi

open -n ${WAIT_FLAG[@]+"${WAIT_FLAG[@]}"} "$APP_PATH" --args ${APP_ARGUMENTS[@]+"${APP_ARGUMENTS[@]}"}
