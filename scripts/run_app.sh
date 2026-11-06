#!/usr/bin/env bash
# Launches build/app.noindex/Handsfree.app (see scripts/build_app.sh). Any options are passed to the app:
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
#   scripts/run_app.sh --wait --render-states DIR   draw the companion's states to PNGs and quit
#
# Only one copy runs. If Handsfree is already running, it is never stopped from here: a plain
# start asks it to show its panel; a demo or test launch refuses with one line; --render-states
# (which shows nothing and uses no microphone) still runs.
#
# The app is started with `open`, not by running the binary from this shell.
# That matters: a program started directly from a terminal counts, for macOS
# privacy, as part of the terminal, so permission prompts and grants would go
# to the terminal app instead of Handsfree.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$REPO_ROOT/build/app.noindex/Handsfree.app"

if [ ! -d "$APP_PATH" ]; then
  echo "build/app.noindex/Handsfree.app does not exist yet. Run scripts/build_app.sh first." >&2
  exit 1
fi

WAIT_FLAG=()
APP_ARGUMENTS=()
for argument in "$@"; do
  if [ "$argument" = "--wait" ]; then WAIT_FLAG=(-W); else APP_ARGUMENTS+=("$argument"); fi
done

# Only one copy of Handsfree may run (the app enforces it too: a second copy asks the first to
# show its panel and quits). A copy already running is the user's: it is never stopped from here.
RENDERS_ONLY=0
TEST_MODE=0
for argument in ${APP_ARGUMENTS[@]+"${APP_ARGUMENTS[@]}"}; do
  case "$argument" in
    --render-states) RENDERS_ONLY=1 ;;
    --demo|--freeze|--loop|--backdrop|--capturable|--quit-after|--moment-log|--request-permissions) TEST_MODE=1 ;;
  esac
done
running_pid="$(pgrep -x Handsfree | head -n 1 || true)"
if [ -n "$running_pid" ] && [ "$RENDERS_ONLY" -eq 0 ]; then
  if [ "$TEST_MODE" -eq 1 ]; then
    echo "Handsfree is already running (process $running_pid), so this test or demo launch was not started. Quit it from its panel first." >&2
    exit 1
  fi
  echo "Handsfree is already running (process $running_pid); asking it to show its panel."
fi

# `open -n` starts a new process, so the options reach the app; if a copy is running, that new
# process hands over to it at once (see Handsfree/App/SingleInstance.swift).
open -n ${WAIT_FLAG[@]+"${WAIT_FLAG[@]}"} "$APP_PATH" --args ${APP_ARGUMENTS[@]+"${APP_ARGUMENTS[@]}"}
if [ ${#WAIT_FLAG[@]} -eq 0 ] && [ "$TEST_MODE" -eq 1 ] && ! printf '%s\n' ${APP_ARGUMENTS[@]+"${APP_ARGUMENTS[@]}"} | grep -qx -- '--quit-after'; then
  echo "Started without --quit-after: it keeps running until you quit it from its panel (or: pkill -x Handsfree)."
fi
