#!/bin/bash
# Live smoke test for the Token Saver compression service.
# Runs the REAL RemoteCodeDistillService binary with the test runtime (no MLX
# model download needed), POSTs a large command-output blob to /v1/distill for
# every approved LLM model id, and verifies measured savings + stats reporting.
set -euo pipefail

BIN=".build/debug/RemoteCodeDistillService"
[ -x "$BIN" ] || { echo "FAIL: $BIN not built"; exit 1; }

TOKEN="smoke-$$-token"
TMPROOT="$(mktemp -d)"
SVC_PID=""
cleanup() {
  if [ -n "${SVC_PID:-}" ]; then
    kill "$SVC_PID" 2>/dev/null || true
  fi
  rm -rf "$TMPROOT" 2>/dev/null || true
}
trap cleanup EXIT

MODEL_IDS=(
  "samuelfaj/distill-1.7B-4bit-MLX"
  "samuelfaj/distill-E4B-it-4-bit-MLX"
)
MODEL_URLS=(
  "https://huggingface.co/samuelfaj/distill-1.7B-4bit-MLX"
  "https://huggingface.co/samuelfaj/distill-E4B-it-4-bit-MLX"
)

extract_base_url() {
  python3 -c 'import json,sys
try:
    print(json.loads(open(sys.argv[1]).readline()).get("base_url",""))
except Exception:
    print("")' "$1"
}

wait_for_base_url() {
  local out="$1"
  local base_url=""
  for _ in $(seq 1 50); do
    if [ -s "$out" ]; then
      base_url="$(extract_base_url "$out")"
      [ -n "$base_url" ] && break
    fi
    sleep 0.1
  done
  [ -n "$base_url" ] || { echo "FAIL: service never emitted ready event"; exit 1; }
  echo "$base_url"
}

write_command_output_body() {
  local body="$1"
  python3 -c '
import json
lines = "\n".join(f"line {i}: verbose build/test output that the distiller removes" for i in range(1,61))
print(json.dumps({"id":"11111111-1111-1111-1111-111111111111","mode":"commandOutput","priority":1,"input":lines,"provider":"codex","recordSavings":True,"maxOutputCharacters":4000}))
' > "$body"
}

assert_savings_response() {
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
}

assert_stats_response() {
  python3 -c '
import json,sys
r = json.loads(sys.argv[1])
assert r["total_saved_tokens"] > 0, "stats total_saved_tokens must be > 0 after distill"
assert r["total_runs"] > 0, "stats total_runs must be > 0 after distill"
print("statsSavedTokens={} statsRuns={}".format(r["total_saved_tokens"], r["total_runs"]))
' "$1"
}

smoke_model() {
  local model_id="$1"
  local model_url="$2"
  local run_dir="$TMPROOT/$(echo "$model_id" | tr '/:' '__')"
  local out="$run_dir/service.out"
  local body="$run_dir/body.json"
  mkdir -p "$run_dir"

  REMOTE_CODE_DISTILL_ALLOW_TEST_RUNTIME=1 "$BIN" \
    --auth-token "$TOKEN" \
    --app-support-dir "$run_dir" \
    --model-id "$model_id" \
    --model-url "$model_url" \
    --host 127.0.0.1 --port 0 > "$out" 2>/dev/null &
  SVC_PID=$!

  local base_url
  base_url="$(wait_for_base_url "$out")"
  echo "service ready for $model_id at $base_url"

  curl -fsS "$base_url/readyz" -H "Authorization: Bearer $TOKEN" >/dev/null

  write_command_output_body "$body"
  local resp
  resp="$(curl -fsS -X POST "$base_url/v1/distill" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    --data-binary "@$body")"

  echo "response for $model_id: $resp"
  RESP="$resp" assert_savings_response

  local stats
  stats="$(curl -fsS "$base_url/v1/stats" -H "Authorization: Bearer $TOKEN")"
  assert_stats_response "$stats"

  # Encoder-primitive wire surface (F16/F11): /v1/rank is deterministic (BM25) and
  # works WITHOUT an installed encoder model, so we exercise it on every run. The
  # query-relevant chunk must rank first.
  local rank_resp
  rank_resp="$(curl -fsS -X POST "$base_url/v1/rank" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    --data-binary '{"query":"why did authentication fail","topK":1,"chunks":[{"id":"flour","text":"the recipe needs two cups of flour","position":0},{"id":"auth","text":"the auth session token has expired and authentication failed","position":1}]}')"
  echo "rank response for $model_id: $rank_resp"
  case "$rank_resp" in
    *'"id":"auth"'*) echo "encoder primitive /v1/rank: auth chunk ranked first (ok)" ;;
    *) echo "FAIL: /v1/rank did not rank the query-relevant chunk first: $rank_resp"; exit 1 ;;
  esac

  if [ "${REMOTE_CODE_ENCODER_SMOKE:-0}" = "1" ]; then
    # Opt-in: requires an installed encoder model; exercises real /v1/embed.
    local embed_resp
    embed_resp="$(curl -fsS -X POST "$base_url/v1/embed" \
      -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
      --data-binary '{"texts":["authentication failed"]}')" || {
        echo "FAIL: REMOTE_CODE_ENCODER_SMOKE=1 but /v1/embed errored (encoder model installed?)"; exit 1; }
    echo "encoder /v1/embed response for $model_id: $embed_resp"
  else
    echo "encoder /v1/embed smoke: skipped (set REMOTE_CODE_ENCODER_SMOKE=1 with an installed encoder model)"
  fi

  kill "$SVC_PID" 2>/dev/null || true
  wait "$SVC_PID" 2>/dev/null || true
  SVC_PID=""
}

for i in "${!MODEL_IDS[@]}"; do
  smoke_model "${MODEL_IDS[$i]}" "${MODEL_URLS[$i]}"
done

echo "SMOKE PASS: approved LLM model ids accepted and savings stats produced"
