#!/usr/bin/env bash
# plan-final W0: scripted performance baseline collector (inventory only).
# Does NOT claim F1–F3 freeze success — requires awake uncapped soak separately.
set -euo pipefail

OUT_DIR="${1:-docs/evidence}"
PID="${2:-}"
# DoD asks for 60s sample when available; override with $3.
DURATION_SEC="${3:-60}"
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
{"ok":false,"error":"no_remotecode_pid","sha":"$SHA","stamp":"$STAMP","claims":{"F1_F3_freeze_success":false}}
EOF
  echo "No RemoteCode pid; wrote $OUT_JSON" >&2
  exit 2
fi

ZOMBIES=$(ps -axo pid,ppid,stat,rss,comm | awk -v p="$PID" '$2==p && $3 ~ /Z/ {c++} END {print c+0}')
CHILDREN=$(ps -axo pid,ppid,stat,rss,comm | awk -v p="$PID" '$2==p {c++} END {print c+0}')
RSS_KB=$(ps -o rss= -p "$PID" 2>/dev/null | tr -d ' ' || echo 0)
PORTS=$(top -l 1 -pid "$PID" -stats pid,ports 2>/dev/null | awk -v p="$PID" '$1==p {print $2; exit}' || echo null)

# Channel-aware DB path (release default; beta/debug variants if present).
DB_PATH=""
for candidate in \
  "${HOME}/Library/Application Support/RemoteCode/remotecode.sqlite" \
  "${HOME}/Library/Application Support/RemoteCode-beta/remotecode.sqlite" \
  "${HOME}/Library/Application Support/RemoteCode-debug/remotecode.sqlite"
do
  if [[ -f "$candidate" ]]; then DB_PATH="$candidate"; break; fi
done
DB_BYTES=null
if [[ -n "$DB_PATH" ]]; then
  DB_BYTES=$(stat -f%z "$DB_PATH" 2>/dev/null || stat -c%s "$DB_PATH" 2>/dev/null || echo null)
fi

DISTILL_SERVICE_COUNT=$(pgrep -f RemoteCodeDistillService 2>/dev/null | wc -l | tr -d ' ')
DISTILL_SERVICE_RSS=0
while read -r spid; do
  [[ -z "$spid" ]] && continue
  sr=$(ps -o rss= -p "$spid" 2>/dev/null | tr -d ' ' || echo 0)
  DISTILL_SERVICE_RSS=$((DISTILL_SERVICE_RSS + sr))
done < <(pgrep -f RemoteCodeDistillService 2>/dev/null || true)

SAMPLE_NOTE="skipped"
SAMPLE_INTERVAL_MS=10
if command -v sample >/dev/null 2>&1 && [[ "$DURATION_SEC" -gt 0 ]]; then
  SAMPLE_FILE="$OUT_DIR/sample-${PID}-${STAMP}.txt"
  sample "$PID" "$DURATION_SEC" 10 -file "$SAMPLE_FILE" 2>/dev/null || true
  SAMPLE_NOTE="$SAMPLE_FILE"
fi

# Continuous-stall / p95 event→UI require in-process signposts not available from
# this shell harness. Record honest nulls so the baseline is not over-claimed.
cat >"$OUT_JSON" <<EOF
{
  "ok": true,
  "sha": "$SHA",
  "stamp": "$STAMP",
  "pid": $PID,
  "durationSec": $DURATION_SEC,
  "sampleIntervalMs": $SAMPLE_INTERVAL_MS,
  "rssKB": $RSS_KB,
  "childCount": $CHILDREN,
  "zombieChildren": $ZOMBIES,
  "machPorts": ${PORTS:-null},
  "dbPath": $( [[ -n "$DB_PATH" ]] && printf '"%s"' "$DB_PATH" || echo null ),
  "dbBytes": $DB_BYTES,
  "distillServiceProcessCount": $DISTILL_SERVICE_COUNT,
  "distillServiceRssKB": $DISTILL_SERVICE_RSS,
  "sample": "$SAMPLE_NOTE",
  "metrics": {
    "continuousStallMsMax": null,
    "stallsOver250ms": null,
    "p95_eventToUI_ms": null,
    "p95_streamInsert_ms": null,
    "normalizedPer100ThreadEvents": null,
    "note": "continuous-stall and p95 require in-app signposts (not this shell script)"
  },
  "claims": {
    "F1_F3_freeze_success": false,
    "note": "Baseline inventory only; freeze success requires awake uncapped soak"
  }
}
EOF

cat >"$OUT_MD" <<EOF
# Perf baseline $STAMP

- SHA: \`$SHA\`
- PID: $PID
- Duration: ${DURATION_SEC}s (sample interval 10ms when sample runs)
- RSS KB: $RSS_KB
- Children: $CHILDREN (zombies: $ZOMBIES)
- Mach ports: ${PORTS:-n/a}
- DB bytes: $DB_BYTES
- RemoteCodeDistillService helper processes: $DISTILL_SERVICE_COUNT (RSS KB sum: $DISTILL_SERVICE_RSS)
- Sample: $SAMPLE_NOTE
- continuousStall / p95 event→UI / p95 stream-insert: **null** (need in-app signposts)

**No F1–F3 claim** — inventory only (plan-final W0).
EOF

echo "Wrote $OUT_JSON"
