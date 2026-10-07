#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rc2-lifecycle-signal.XXXXXX")"
OUT="$TMP_DIR/stdout.log"
ERR="$TMP_DIR/stderr.log"
PID=""

cleanup() {
  if [[ -n "${PID:-}" ]] && kill -0 "$PID" 2>/dev/null; then
    kill -KILL "$PID" 2>/dev/null || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

cd "$ROOT"
swift build --product LifecycleSignalProbe >/dev/null
BIN="$(swift build --show-bin-path)/LifecycleSignalProbe"

"$BIN" "$TMP_DIR" >"$OUT" 2>"$ERR" &
PID="$!"

for _ in {1..80}; do
  if grep -q '^ready$' "$OUT"; then
    break
  fi
  if ! kill -0 "$PID" 2>/dev/null; then
    echo "FAIL: probe exited before ready" >&2
    cat "$OUT" >&2 || true
    cat "$ERR" >&2 || true
    exit 1
  fi
  sleep 0.05
done

grep -q '^ready$' "$OUT"
MARKER="$TMP_DIR/running.$PID.marker"
test -f "$MARKER"

kill -TERM "$PID"
set +e
wait "$PID"
STATUS="$?"
set -e
PID=""

if [[ "$STATUS" -ne 143 ]]; then
  echo "FAIL: expected SIGTERM exit status 143, got $STATUS" >&2
  cat "$OUT" >&2 || true
  cat "$ERR" >&2 || true
  exit 1
fi

grep -q 'signal=SIGTERM terminating' "$TMP_DIR/lifecycle.log"
if [[ -e "$MARKER" ]]; then
  echo "FAIL: run marker survived SIGTERM handler" >&2
  exit 1
fi

echo "PASS: SIGTERM recorded, marker unlinked, process re-raised exit_status=$STATUS"
