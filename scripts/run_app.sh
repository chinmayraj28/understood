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
#   scripts/run_app.sh --sync-only --quit-after 12  update and check the voice agent, no listening (no microphone)
#   LIVE_LOCK_OWNER=<you> scripts/run_app.sh --wait --script scripts/e2e/textedit.txt
#                                              test only: typed flow on the TEST agent, no mic, no sound;
#                                              needs --wait and the live lock held by <you>
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
SCRIPT_RUN=0
previous=""
for argument in "$@"; do
  if [ "$argument" = "--wait" ]; then WAIT_FLAG=(-W); previous="$argument"; continue; fi
  # The app does not start in this folder, so a relative path after --script or --render-states
  # is made absolute here.
  if { [ "$previous" = "--script" ] || [ "$previous" = "--render-states" ]; } && [ "${argument#/}" = "$argument" ]; then
    argument="$PWD/$argument"
  fi
  [ "$argument" = "--script" ] && SCRIPT_RUN=1
  APP_ARGUMENTS+=("$argument")
  previous="$argument"
done

# Only one copy of Handsfree may run (the app enforces it too: a second copy asks the first to
# show its panel and quits). A copy already running is the user's: it is never stopped from here.
RENDERS_ONLY=0
TEST_MODE=0
for argument in ${APP_ARGUMENTS[@]+"${APP_ARGUMENTS[@]}"}; do
  case "$argument" in
    --render-states) RENDERS_ONLY=1 ;;
    --demo|--freeze|--loop|--backdrop|--capturable|--quit-after|--moment-log|--request-permissions|--sync-only|--script) TEST_MODE=1 ;;
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

# A script run moves the real pointer and presses real keys, so it needs the live lock (one pointer,
# one keyboard), held by whoever runs it, for the whole run: it must be waited for, and the lock is
# refreshed every minute while it runs. Its report is deleted first, so an old one is never shown as new.
REPORT="${HANDSFREE_DATA_DIR:-$HOME/Library/Application Support/Handsfree}/script-run.json"
LOCK_REFRESHER=""
if [ "$SCRIPT_RUN" -eq 1 ]; then
  if [ ${#WAIT_FLAG[@]} -eq 0 ]; then
    echo "A script run must be waited for, so the live lock covers all of it: add --wait." >&2
    exit 1
  fi
  if [ -z "${LIVE_LOCK_OWNER:-}" ] || ! "$REPO_ROOT/scripts/live_lock.sh" holds "$LIVE_LOCK_OWNER" >/dev/null; then
    echo "A script run moves the real pointer and presses keys, so it needs the live lock. Take it, then pass your name:" >&2
    echo "  scripts/live_lock.sh acquire <you> && LIVE_LOCK_OWNER=<you> scripts/run_app.sh --wait --script <file>" >&2
    exit 1
  fi
  rm -f "$REPORT"
  ( while sleep 60; do "$REPO_ROOT/scripts/live_lock.sh" refresh "$LIVE_LOCK_OWNER" >/dev/null 2>&1 || exit 0; done ) &
  LOCK_REFRESHER=$!
  trap '[ -n "$LOCK_REFRESHER" ] && kill "$LOCK_REFRESHER" 2>/dev/null; true' EXIT
fi

# `open -n` starts a new process, so the options reach the app; if a copy is running, that new
# process hands over to it at once (see Handsfree/App/SingleInstance.swift).
open -n ${WAIT_FLAG[@]+"${WAIT_FLAG[@]}"} "$APP_PATH" --args ${APP_ARGUMENTS[@]+"${APP_ARGUMENTS[@]}"}
if [ ${#WAIT_FLAG[@]} -eq 0 ] && [ "$TEST_MODE" -eq 1 ] && ! printf '%s\n' ${APP_ARGUMENTS[@]+"${APP_ARGUMENTS[@]}"} | grep -qx -- '--quit-after'; then
  echo "Started without --quit-after: it keeps running until you quit it from its panel (or: pkill -x Handsfree)."
fi
# A waited-for script run prints its report, so the result is visible without opening the file.
if [ ${#WAIT_FLAG[@]} -gt 0 ] && [ "$SCRIPT_RUN" -eq 1 ]; then
  if [ -f "$REPORT" ]; then
    echo "Report: $REPORT"
    cat "$REPORT"; echo
  else
    echo "No report was written: the run stopped before the end (or another copy of Handsfree took over)." >&2
    exit 1
  fi
fi
