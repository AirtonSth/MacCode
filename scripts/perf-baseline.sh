#!/usr/bin/env bash
# plan-final W0: scripted performance baseline collector.
# Collects process/DB/zombie counters for a running RemoteCode pid.
# Does not claim F1–F3 freeze success — forensic inventory only.
set -euo pipefail

OUT_DIR="${1:-docs/evidence}"
PID="${2:-}"
DURATION_SEC="${3:-5}"
mkdir -p "$OUT_DIR"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
SHA=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
OUT_JSON="$OUT_DIR/perf-baseline-${SHA}-${STAMP}.json"
OUT_MD="$OUT_DIR/perf-baseline-${SHA}-${STAMP}.md"

if [[ -z "$PID" ]]; then
  PID=$(pgrep -x RemoteCode | head -1 || true)
fi

if [[ -z "$PID" ]]; then
  cat >"$OUT_JSON" <<EOF
{"ok":false,"error":"no_remotecode_pid","sha":"$SHA","stamp":"$STAMP"}
EOF
  echo "No RemoteCode pid; wrote $OUT_JSON" >&2
  exit 2
fi

ZOMBIES=$(ps -axo pid,ppid,stat,rss,comm | awk -v p="$PID" '$2==p && $3 ~ /Z/ {c++} END {print c+0}')
CHILDREN=$(ps -axo pid,ppid,stat,rss,comm | awk -v p="$PID" '$2==p {c++} END {print c+0}')
RSS_KB=$(ps -o rss= -p "$PID" 2>/dev/null | tr -d ' ' || echo 0)
DB_PATH="${HOME}/Library/Application Support/RemoteCode/remotecode.sqlite"
DB_BYTES=0
if [[ -f "$DB_PATH" ]]; then
  DB_BYTES=$(stat -f%z "$DB_PATH" 2>/dev/null || stat -c%s "$DB_PATH" 2>/dev/null || echo 0)
fi

# Optional sample if available and duration > 0
SAMPLE_NOTE="skipped"
if command -v sample >/dev/null 2>&1 && [[ "$DURATION_SEC" -gt 0 ]]; then
  SAMPLE_FILE="$OUT_DIR/sample-${PID}-${STAMP}.txt"
  sample "$PID" "$DURATION_SEC" 10 -file "$SAMPLE_FILE" 2>/dev/null || true
  SAMPLE_NOTE="$SAMPLE_FILE"
fi

cat >"$OUT_JSON" <<EOF
{
  "ok": true,
  "sha": "$SHA",
  "stamp": "$STAMP",
  "pid": $PID,
  "rssKB": $RSS_KB,
  "childCount": $CHILDREN,
  "zombieChildren": $ZOMBIES,
  "dbBytes": $DB_BYTES,
  "sample": "$SAMPLE_NOTE",
  "claims": {
    "F1_F3_freeze_success": false,
    "note": "Baseline only; freeze success requires awake uncapped soak"
  }
}
EOF

cat >"$OUT_MD" <<EOF
# Perf baseline $STAMP

- SHA: \`$SHA\`
- PID: $PID
- RSS KB: $RSS_KB
- Children: $CHILDREN (zombies: $ZOMBIES)
- DB bytes: $DB_BYTES
- Sample: $SAMPLE_NOTE

**No F1–F3 claim** — inventory only (plan-final W0).
EOF

echo "Wrote $OUT_JSON"
