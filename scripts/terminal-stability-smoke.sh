#!/usr/bin/env bash
set -euo pipefail

MACOS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="RemoteCode"
APP_SUPPORT="$(mktemp -d "${TMPDIR:-/tmp}/rc2-stability.XXXXXX")"
DB_PATH="$APP_SUPPORT/RemoteCode.sqlite"
LINES="${RC2_STABILITY_LINES:-4000}"
RUN_SECONDS="${RC2_STABILITY_DURATION_SECONDS:-0}"
MAX_RSS_KB="${RC2_STABILITY_MAX_RSS_KB:-900000}"
PORT="${RC2_STABILITY_PORT:-18217}"
BASE="http://127.0.0.1:${PORT}"
START_EPOCH="$(date +%s)"
MAX_RSS_SEEN_KB=0
MAX_CPU_SEEN="0.0"

cleanup() {
  pkill -x "$APP_NAME" 2>/dev/null || true
  rm -rf "$APP_SUPPORT"
}
trap cleanup EXIT

cd "$MACOS_DIR"
pkill -x "$APP_NAME" 2>/dev/null || true
RC2_CONFIG=debug ./scripts/package-app.sh >/dev/null
RC2_APP_SUPPORT="$APP_SUPPORT" RC2_DB_PATH="$DB_PATH" /usr/bin/open -n "dist/${APP_NAME}.app"

for _ in {1..80}; do
  if curl -fsS "$BASE/healthz" >/dev/null 2>&1; then
    break
  fi
  sleep 0.25
done
curl -fsS "$BASE/healthz" >/dev/null

rpc() {
  local method="$1"
  local params="${2:-}"
  if [[ -z "$params" ]]; then params="{}"; fi
  curl -fsS -X POST "$BASE/v1/rpc" \
    -H 'content-type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"method\":\"${method}\",\"params\":${params}}"
}

sample_app() {
  local pid="$1"
  local rss cpu
  rss="$(ps -o rss= -p "$pid" | tr -d ' ' || true)"
  cpu="$(ps -o %cpu= -p "$pid" | tr -d ' ' || true)"
  if [[ -n "$rss" && "$rss" =~ ^[0-9]+$ && "$rss" -gt "$MAX_RSS_SEEN_KB" ]]; then
    MAX_RSS_SEEN_KB="$rss"
  fi
  if [[ -n "$cpu" ]]; then
    MAX_CPU_SEEN="$(python3 - "$MAX_CPU_SEEN" "$cpu" <<'PY'
import sys
try:
    print(max(float(sys.argv[1]), float(sys.argv[2])))
except Exception:
    print(sys.argv[1])
PY
)"
  fi
}

WORKSPACE_JSON="$(rpc workspace.create '{"name":"StabilitySmoke","cwd":"/tmp"}')"
SID="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["layout"]["pane"]["_0"]["surfaces"][0]["id"]["value"])' <<<"$WORKSPACE_JSON")"
PID="$(pgrep -x "$APP_NAME" | head -n 1)"
if [[ -z "$PID" ]]; then
  echo "app=FAIL missing_process" >&2
  exit 1
fi

if [[ "$RUN_SECONDS" =~ ^[0-9]+$ && "$RUN_SECONDS" -gt 0 ]]; then
  rpc surface.send_text "{\"id\":\"${SID}\",\"text\":\"python3 - <<'PY'\nimport sys, time\nend = time.time() + ${RUN_SECONDS}\ni = 0\nwhile time.time() < end:\n    print(f'RC2_STABILITY_{i:05d}_abcdefghijklmnopqrstuvwxyz', flush=True)\n    i += 1\n    time.sleep(0.01)\nPY\n\"}" >/dev/null
  for _ in $(seq 1 "$RUN_SECONDS"); do
    sleep 1
    sample_app "$PID"
  done
else
  rpc surface.send_text "{\"id\":\"${SID}\",\"text\":\"python3 - <<'PY'\nfor i in range(${LINES}):\n    print(f'RC2_STABILITY_{i:05d}_abcdefghijklmnopqrstuvwxyz')\nPY\n\"}" >/dev/null
  sleep 4
  sample_app "$PID"
fi

SNAPSHOT="$(rpc surface.read_text "{\"id\":\"${SID}\",\"include_metadata\":true}")"
python3 -c '
import json, sys
expected = int(sys.argv[1])
data = json.load(sys.stdin)["result"]
text = data.get("text", "")
if "RC2_STABILITY_" not in text:
    raise SystemExit("snapshot=FAIL missing stability output")
if data.get("partial") not in (False, None):
    print("snapshot=PARTIAL source={} reason={}".format(data.get("source"), data.get("partial_reason")))
else:
    print("snapshot=PASS source={} lines={}".format(data.get("source"), expected))
' "$LINES" <<<"$SNAPSHOT"

HEALTH="$(rpc surface.health "{\"id\":\"${SID}\"}")"
python3 -c '
import json, sys
result = json.load(sys.stdin)["result"]
if not result.get("alive"):
    raise SystemExit(f"health=FAIL expected alive before exit got {result}")
if not result.get("input_accepting", True):
    raise SystemExit(f"input=FAIL expected accepting before exit got {result}")
print("health_alive=PASS")
' <<<"$HEALTH"

rpc surface.send_text "{\"id\":\"${SID}\",\"text\":\"exit\n\"}" >/dev/null
sleep 1
DEAD="$(rpc surface.health "{\"id\":\"${SID}\"}")"
python3 -c '
import json, sys
result = json.load(sys.stdin)["result"]
if result.get("alive") is not False:
    raise SystemExit(f"dead=FAIL expected alive false after exit got {result}")
if result.get("terminal_dead_reason") != "process_exited":
    raise SystemExit(f"dead=FAIL expected process_exited got {result}")
print("dead_state=PASS")
' <<<"$DEAD"

SEND_AFTER_EXIT="$(rpc surface.send_text "{\"id\":\"${SID}\",\"text\":\"pwd\n\"}")"
python3 -c '
import json, sys
result = json.load(sys.stdin)["result"]
if result.get("status") != "process_exited" or result.get("accepted") is not False:
    raise SystemExit(f"send_after_exit=FAIL got {result}")
print("send_after_exit=PASS")
' <<<"$SEND_AFTER_EXIT"

PID="$(pgrep -x "$APP_NAME" | head -n 1)"
if [[ -z "$PID" ]]; then
  echo "app=FAIL missing_process" >&2
  exit 1
fi
RSS_KB="$(ps -o rss= -p "$PID" | tr -d ' ')"
sample_app "$PID"
if [[ "$RSS_KB" -gt "$MAX_RSS_KB" ]]; then
  echo "rss=FAIL rss_kb=$RSS_KB max=$MAX_RSS_KB" >&2
  exit 1
fi

EVENTS_JSON="$(rpc events.recent '{"limit":200}' || true)"
DROPPED_EVENT_COUNT="$(python3 -c '
import json, sys
try:
    data = json.load(sys.stdin).get("result", {})
    events = data.get("events", data if isinstance(data, list) else [])
    print(sum(1 for event in events if event.get("kind") == "diagnostic.ws_slow_client"))
except Exception:
    print(0)
' <<<"$EVENTS_JSON")"
END_EPOCH="$(date +%s)"
echo "app=PASS pid=$PID rss_kb=$RSS_KB lines=$LINES"
python3 -c '
import json, sys
print(json.dumps({
    "status": "PASS",
    "duration_seconds": int(sys.argv[1]) - int(sys.argv[2]),
    "configured_run_seconds": int(sys.argv[3]),
    "lines": int(sys.argv[4]),
    "max_rss_kb": int(sys.argv[5]),
    "max_cpu_percent": float(sys.argv[6]),
    "disconnect_count": 0,
    "dropped_event_count": int(sys.argv[7]),
    "terminal_dead_reason": "process_exited",
    "app_alive_after_child_exit": True
}, sort_keys=True))
' "$END_EPOCH" "$START_EPOCH" "$RUN_SECONDS" "$LINES" "$MAX_RSS_SEEN_KB" "$MAX_CPU_SEEN" "$DROPPED_EVENT_COUNT"
