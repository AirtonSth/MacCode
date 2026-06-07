#!/bin/bash
# Live smoke test for the Token Saver compression service.
# Runs the REAL RemoteCodeDistillService binary (LocalDistillRuntime, no MLX
# model download needed), POSTs a large command-output blob to /v1/distill, and
# verifies the response reports measured token savings.
set -euo pipefail

BIN=".build/debug/RemoteCodeDistillService"
[ -x "$BIN" ] || { echo "FAIL: $BIN not built"; exit 1; }

TOKEN="smoke-$$-token"
TMPDIR_APP="$(mktemp -d)"
OUT="$(mktemp)"
trap 'kill "${SVC_PID:-0}" 2>/dev/null || true; rm -rf "$TMPDIR_APP" "$OUT" "${BODY:-}" 2>/dev/null || true' EXIT

REMOTE_CODE_DISTILL_ALLOW_TEST_RUNTIME=1 "$BIN" \
  --auth-token "$TOKEN" \
  --app-support-dir "$TMPDIR_APP" \
  --host 127.0.0.1 --port 0 > "$OUT" 2>/dev/null &
SVC_PID=$!

# Wait for the ready event (first stdout line = JSON).
BASE_URL=""
for _ in $(seq 1 50); do
  if [ -s "$OUT" ]; then
    BASE_URL="$(python3 -c 'import json,sys
try:
    print(json.loads(open(sys.argv[1]).readline()).get("base_url",""))
except Exception:
    print("")' "$OUT")"
    [ -n "$BASE_URL" ] && break
  fi
  sleep 0.1
done
[ -n "$BASE_URL" ] || { echo "FAIL: service never emitted ready event"; exit 1; }
echo "service ready at $BASE_URL"

# Build a large command-output blob (60 verbose lines).
BODY="$(mktemp)"
python3 -c '
import json
lines = "\n".join(f"line {i}: verbose build/test output that the distiller removes" for i in range(1,61))
print(json.dumps({"id":"11111111-1111-1111-1111-111111111111","mode":"commandOutput","priority":1,"input":lines,"maxOutputCharacters":4000}))
' > "$BODY"

RESP="$(curl -fsS -X POST "$BASE_URL/v1/distill" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  --data-binary "@$BODY")"

echo "response: $RESP"
python3 -c '
import json,sys
r = json.loads(sys.argv[1])
# savedTokens is a computed Swift property (not serialized); recompute the delta
# the same way the Swift client does.
inp, out = r["inputTokens"], r["outputTokens"]
saved = max(inp - out, 0)
print(f"inputTokens={inp} outputTokens={out} savedTokens={saved}")
assert inp > 0 and out > 0, "tokens must be measured"
assert saved > 0, "savedTokens must be > 0"
assert out < inp, "compressed output must be smaller"
print("SMOKE PASS: measured token savings produced by the real service binary")
' "$RESP"
