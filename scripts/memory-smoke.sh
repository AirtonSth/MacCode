#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

LINES="${RC2_MEMORY_SMOKE_LINES:-12000}"
MAX_RSS_KB="${RC2_MEMORY_SMOKE_MAX_RSS_KB:-900000}"
APP_NAME="RemoteCode"
export RC2_CHANNEL="${RC2_CHANNEL:-stable}"
case "$RC2_CHANNEL" in
  stable) SOCKET_PATH="/tmp/RemoteCode.sock" ;;
  canary) SOCKET_PATH="/tmp/RemoteCodeCanary.sock" ;;
  debug) SOCKET_PATH="/tmp/RemoteCodeDebug.sock" ;;
  *) echo "unsupported RC2_CHANNEL=$RC2_CHANNEL" >&2; exit 1 ;;
esac
export SOCKET_PATH
# Host-app smoke: relaunches the packaged desktop app. Agents must not run this.
./scripts/run-app.sh --verify >/dev/null
for _ in {1..40}; do
  if PING_JSON="$(.build/debug/rc2 --json ping 2>/dev/null)" && grep -q '"pong"' <<<"$PING_JSON"; then
    break
  fi
  sleep 0.25
done

WORKSPACE_JSON="$(.build/debug/rc2 --json new-workspace --cwd /tmp --name MemorySmoke)"
SID="$(printf '%s' "$WORKSPACE_JSON" | python3 -c '
import json, sys
data=json.load(sys.stdin)
surface=data["result"]["layout"]["pane"]["_0"]["surfaces"][0]["id"]["value"]
print(surface)
')"

.build/debug/rc2 --json send-text --id "$SID" --text "python3 - <<'PY'
for i in range($LINES):
    print(f'RC2_MEMORY_SMOKE_{i:05d}_abcdefghijklmnopqrstuvwxyz')
PY
" >/dev/null

sleep 3

python3 - "$SID" <<'PY'
import json, socket, sys
sid=sys.argv[1]
req={"jsonrpc":"2.0","id":1,"method":"surface.read_history","params":{"id":sid,"max_bytes":65536}}
s=socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
import os
s.connect(os.environ["SOCKET_PATH"])
s.sendall((json.dumps(req)+"\n").encode())
data=b""
while not data.endswith(b"\n"):
    chunk=s.recv(131072)
    if not chunk:
        break
    data += chunk
resp=json.loads(data)
result=resp.get("result") or {}
text=result.get("text","")
if resp.get("error"):
    raise SystemExit(f"surface.read_history error: {resp['error']}")
if "RC2_MEMORY_SMOKE_" not in text:
    raise SystemExit("surface.read_history returned no terminal smoke text")
if not result.get("next_before_chunk_id"):
    raise SystemExit("surface.read_history returned no paging cursor")
print("history=PASS")
PY

PID="$(pgrep -x "$APP_NAME" | head -n 1)"
if [[ -z "$PID" ]]; then
  echo "app=FAIL missing process" >&2
  exit 1
fi
RSS_KB="$(ps -o rss= -p "$PID" | tr -d ' ')"
if [[ "$RSS_KB" -gt "$MAX_RSS_KB" ]]; then
  echo "rss=FAIL rss_kb=$RSS_KB max=$MAX_RSS_KB" >&2
  exit 1
fi

LOG_HITS="$(log show --style compact --last 5m --predicate "process == \"RemoteCode\" AND processID == $PID AND (eventMessage CONTAINS[c] \"OutOfMemory\" OR eventMessage CONTAINS[c] \"fatal\" OR eventMessage CONTAINS[c] \"crash\" OR eventMessage CONTAINS[c] \"error initializing surface\")" 2>/dev/null | grep -E 'OutOfMemory|fatal|crash|error initializing surface' || true)"
if [[ -n "$LOG_HITS" ]]; then
  printf '%s\n' "$LOG_HITS" >&2
  echo "logs=FAIL fatal memory/crash line found" >&2
  exit 1
fi

echo "app=PASS pid=$PID rss_kb=$RSS_KB lines=$LINES"
