#!/bin/bash
# One pointer, one keyboard, one front window: only one live run may drive the Mac at a time.
#
#   scripts/live_lock.sh acquire <who> [wait-seconds]   # exits 0 when you hold the lock
#   scripts/live_lock.sh release <who>
#   scripts/live_lock.sh status
#   scripts/live_lock.sh holds <who>     # exits 0 only if <who> holds the lock (read only)
#   scripts/live_lock.sh refresh <who>   # keeps <who>'s lock fresh during a long run
#
# Take the lock before ANY command that moves the pointer, presses keys, brings an app to the
# front, or plays sound through the speakers (HF_LIVE runs, hf-agent, hf-hands, launching the
# app). Release it as soon as that command finishes. Read-only checks need no lock.
# A lock not refreshed for 15 minutes is treated as abandoned and taken over. That outlasts the
# longest single wait in a script run (a task: 180 s, plus the wake and the reply), and
# scripts/run_app.sh refreshes the lock every minute while a script runs anyway.
set -u
LOCK="$(cd "$(dirname "$0")/.." && pwd)/.live-lock"
STALE_SECONDS=900
# The lock lives at the repo root, not under build/, because the app build script clears build/.

holder() { cat "$LOCK/owner" 2>/dev/null || echo "unknown"; }
age() { echo $(( $(date +%s) - $(stat -f %m "$LOCK" 2>/dev/null || date +%s) )); }

case "${1:-status}" in
  acquire)
    who="${2:?usage: live_lock.sh acquire <who> [wait-seconds]}"; wait="${3:-240}"; waited=0
    while true; do
      if mkdir "$LOCK" 2>/dev/null; then echo "$who" > "$LOCK/owner"; echo "lock acquired by $who"; exit 0; fi
      if [ "$(holder)" = "$who" ]; then touch "$LOCK"; echo "lock already held by $who"; exit 0; fi
      if [ "$(age)" -ge "$STALE_SECONDS" ]; then echo "taking over stale lock from $(holder)"; rm -rf "$LOCK"; continue; fi
      if [ "$waited" -ge "$wait" ]; then echo "lock is held by $(holder) for $(age)s; gave up after ${wait}s" >&2; exit 1; fi
      sleep 2; waited=$((waited + 2))
    done ;;
  release)
    who="${2:?usage: live_lock.sh release <who>}"
    if [ -d "$LOCK" ] && [ "$(holder)" = "$who" ]; then rm -rf "$LOCK"; echo "lock released by $who"; else echo "no lock held by $who (holder: $(holder))"; fi ;;
  status)
    if [ -d "$LOCK" ]; then echo "held by $(holder) for $(age)s"; else echo "free"; fi ;;
  holds)
    who="${2:?usage: live_lock.sh holds <who>}"
    if [ -d "$LOCK" ] && [ "$(holder)" = "$who" ]; then echo "held by $who"; exit 0; fi
    echo "not held by $who (holder: $( [ -d "$LOCK" ] && holder || echo none))"; exit 1 ;;
  refresh)
    who="${2:?usage: live_lock.sh refresh <who>}"
    if [ -d "$LOCK" ] && [ "$(holder)" = "$who" ]; then touch "$LOCK"; exit 0; fi
    echo "not held by $who; nothing refreshed" >&2; exit 1 ;;
  *) echo "usage: live_lock.sh acquire <who> [wait-seconds] | release <who> | status | holds <who> | refresh <who>" >&2; exit 2 ;;
esac
