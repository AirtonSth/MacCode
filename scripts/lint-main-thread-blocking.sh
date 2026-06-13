#!/usr/bin/env bash
# QA-mac:82 -- main-thread-blocking ratchet for AppShell + Surfaces.
#
# WHY: NSAlert.runModal(), Thread.sleep(forTimeInterval:), and DispatchSemaphore
# blocking waits stall the main run loop -- the three offender classes catalogued
# in Perf #5/#8 (e.g. confirmInsomniaOnBatteryIfNeeded's runModal queueing sidebar
# refreshes behind it). We cannot rip out every existing call in one pass, so this
# is a RATCHET: it freezes the current per-kind counts in a baseline and FAILS the
# build only when a count goes UP -- i.e. a new blocking call was added. Counts can
# only ratchet down; lowering a count means the baseline should be updated too.
#
# Exit 0 = no new blocking calls. Exit 1 = a count increased (new offender) or the
# baseline is missing.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Sources"
BASELINE="$ROOT/scripts/main-thread-blocking-baseline.txt"

# Call-site patterns (deliberately the real call syntax, not prose mentions):
#   runModal       -> any NSAlert/NSPanel .runModal() blocking call
#   threadSleep    -> Thread.sleep(forTimeInterval: ...) main-thread spins
#   semaphoreWait  -> DispatchSemaphore(value: ...) blocking handoffs
pattern_for() {
  case "$1" in
    runModal)      printf '%s' '\.runModal()' ;;
    threadSleep)   printf '%s' 'Thread\.sleep(forTimeInterval' ;;
    semaphoreWait) printf '%s' 'DispatchSemaphore(value' ;;
  esac
}

count_kind() {
  grep -rIn --include='*.swift' "$(pattern_for "$1")" "$SRC" | wc -l | tr -d ' '
}

KINDS="runModal threadSleep semaphoreWait"

# --regen writes a fresh baseline from the current tree (use after an intentional
# removal, or to bootstrap). Never run this to silence a real new offender.
if [ "${1:-}" = "--regen" ]; then
  : > "$BASELINE"
  for k in $KINDS; do echo "$k $(count_kind "$k")" >> "$BASELINE"; done
  echo "wrote baseline:"; cat "$BASELINE"
  exit 0
fi

if [ ! -f "$BASELINE" ]; then
  echo "FAIL: missing baseline $BASELINE (run: $0 --regen)" >&2
  exit 1
fi

status=0
for k in $KINDS; do
  cur="$(count_kind "$k")"
  base="$(awk -v kk="$k" '$1==kk{print $2}' "$BASELINE")"
  base="${base:-0}"
  if [ "$cur" -gt "$base" ]; then
    echo "FAIL: $k increased $base -> $cur (new main-thread-blocking call added)" >&2
    grep -rIn --include='*.swift' "$(pattern_for "$k")" "$SRC" >&2 || true
    status=1
  elif [ "$cur" -lt "$base" ]; then
    echo "NOTE: $k decreased $base -> $cur -- good; update baseline ($0 --regen)" >&2
  fi
done

[ "$status" -eq 0 ] && echo "OK: no new main-thread-blocking calls"
exit "$status"
