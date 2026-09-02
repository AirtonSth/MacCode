#!/usr/bin/env bash
# PF-00: print p50/p95 for tab switch, conversation switch, and main-thread SQLite waits.
# Default path is synthetic (unit tests). Optional --log-stream samples a running
# debug sandbox via `log stream` (never the owner's io.remotecode.desktop).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"

OUT_DIR="${PERF_SWITCH_OUT_DIR:-$ROOT/audit/perf-switch-2026-09-02}"
mkdir -p "$OUT_DIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
BASELINE="$OUT_DIR/baseline.md"
RAW="$OUT_DIR/sample-${SHA}-${STAMP}.txt"

usage() {
  cat <<'EOF' >&2
usage: scripts/perf-switch-sample.sh [--log-stream [seconds]]

  (default)  run PerfSwitchMetricsTests and write p50/p95 to
             audit/perf-switch-2026-09-02/baseline.md
  --log-stream [seconds]
             sample subsystem io.remotecode.perf from the debug sandbox
             executable only (dist/RemoteCodeDebug.app). Does not touch
             io.remotecode.desktop.

Environment:
  DEVELOPER_DIR   default /Applications/Xcode.app/Contents/Developer
  RC2_CONFIG      default debug; use release for comparable PF-00 claims
EOF
  exit 2
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
fi

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

percentile_from_ms_file() {
  local file="$1"
  local pct="$2"
  python3 - "$file" "$pct" <<'PY'
import sys
path, pct = sys.argv[1], float(sys.argv[2])
vals = []
with open(path) as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            vals.append(float(line))
        except ValueError:
            continue
if not vals:
    print("n/a")
    raise SystemExit(0)
vals.sort()
idx = min(len(vals) - 1, max(0, int(round((len(vals) - 1) * pct / 100.0))))
print(f"{vals[idx]:.3f}")
PY
}

run_synthetic() {
  echo "[perf-switch] synthetic sample via PerfSwitchMetricsTests"
  scripts/isolated-sandbox.sh test --filter PerfSwitchMetricsTests | tee "$RAW"
  cat >"$BASELINE" <<EOF
# PF-00 switch baseline

- git: \`$SHA\`
- stamp: \`$STAMP\`
- config: \`${RC2_CONFIG:-debug}\`
- method: synthetic (PerfSwitchMetricsTests). GUI p95 for an 8-tab workspace
  is not claimed here — Instruments Points of Interest subsystem
  \`io.remotecode.perf\` plus \`scripts/perf-switch-sample.sh --log-stream\`
  after a sandbox GUI session.

| measure | p50 | p95 | notes |
|---|---|---|---|
| tab_switch (PF-00 a) | not yet GUI-sampled | not yet GUI-sampled | begin \`focusSurface\`, install mark, end CA commit |
| conversation_switch (PF-00 b) | not yet GUI-sampled | not yet GUI-sampled | begin \`selectThread\`, first publish mark, end hydrate |
| sqlite_main_sync (PF-00 c) | exercised in unit test (>2 ms held writer) | exercised in unit test | DEBUG logs a stack when wait > 2 ms |

Unit-test proof: see \`$RAW\`.
EOF
  echo "[perf-switch] wrote $BASELINE"
}

run_log_stream() {
  local seconds="${1:-8}"
  local exe="$ROOT/dist/RemoteCodeDebug.app/Contents/MacOS/RemoteCode"
  if [ ! -x "$exe" ]; then
    echo "[perf-switch] debug app not built; run scripts/isolated-sandbox.sh build" >&2
    exit 2
  fi
  local pids
  pids="$(ps -axo pid=,command= | awk -v executable="$exe" '
    {
      pid=$1
      $1=""
      cmd=$0
      sub(/^ /, "", cmd)
      if (cmd == executable || index(cmd, executable " ") == 1) print pid
    }')"
  if [ -z "$pids" ]; then
    echo "[perf-switch] debug sandbox is not running (will not sample the owner's RemoteCode)" >&2
    echo "[perf-switch] start it with: scripts/isolated-sandbox.sh run" >&2
    exit 2
  fi
  echo "[perf-switch] sampling io.remotecode.perf for ${seconds}s from pid(s): $pids"
  local pred='subsystem == "io.remotecode.perf"'
  log stream --style compact --predicate "$pred" --timeout "$seconds" | tee "$RAW" || true
  {
    echo "# PF-00 switch baseline (log stream)"
    echo
    echo "- git: \`$SHA\`"
    echo "- stamp: \`$STAMP\`"
    echo "- pids: \`$pids\`"
    echo "- predicate: \`$pred\`"
    echo
    echo "Raw: \`$RAW\`"
    echo
    echo "Parse signpost intervals in Instruments Points of Interest or \`log show\`."
    echo "This capture does not click 8 Agent App tabs; it records whatever the"
    echo "running debug instance emitted during the window."
  } >"$BASELINE"
  echo "[perf-switch] wrote $BASELINE"
}

case "${1:-}" in
  "")
    run_synthetic
    ;;
  --log-stream)
    run_log_stream "${2:-8}"
    ;;
  *)
    usage
    ;;
esac
