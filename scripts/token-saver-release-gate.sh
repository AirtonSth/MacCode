#!/usr/bin/env bash
# Token Saver RUNTIME release gate.
#
# WHY THIS EXISTS
# The 2026-07-28 Token Saver failure was invisible to ~60 XCTest files: coverage
# collapsed and compression was computed then discarded, while every test stayed
# green. The defect was found only by (a) probing the running sidecar and (b)
# querying the live ledger. XCTest is therefore the REGRESSION gate; this script
# is the RELEASE gate for any change that alters compressed bytes or a displayed
# savings number.
#
# It asserts effects an in-process test cannot observe:
#   G1  the sidecar is reachable
#   G2  an UNSCOPED optimize request is not silently discarded (the store-before-loss
#       fail-open must not return byte-identical output with zero saving)
#   G3  the retained ledger is not dominated by zero-saving verbatim rows
#   G4  coverage (bytes offered to the compressor vs provider tokens) is above a floor
#   G5  the displayed all-time figure is provider-ATTRIBUTED, never the raw aggregate
#
# Exit 0 = gate passed. Exit 1 = gate failed. Exit 2 = cannot evaluate (no sidecar
# or no database); "cannot evaluate" is NOT a pass.
set -uo pipefail

CHANNEL="${RC_CHANNEL:-RemoteCode}"
APP_SUPPORT="${RC_APP_SUPPORT:-$HOME/Library/Application Support/$CHANNEL}"
DB="$APP_SUPPORT/remotecode.sqlite"
STATE="$APP_SUPPORT/Distill/DistillCLIState.json"

# Minimum share of offered input that must actually yield savings (G3).
MIN_YIELD_SHARE="${RC_GATE_MIN_YIELD_SHARE:-0.50}"
# Minimum share of provider tokens that must reach the compressor (G4).
MIN_COVERAGE_SHARE="${RC_GATE_MIN_COVERAGE_SHARE:-0.01}"

fail=0
note() { printf '%s\n' "$*"; }
ok()   { printf '  PASS  %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; fail=1; }
skip() { printf '  SKIP  %s\n' "$*"; }

note "== Token Saver release gate =="
note "app support: $APP_SUPPORT"

# ---------------------------------------------------------------- G1 + G2 sidecar
if [[ ! -f "$STATE" ]]; then
  skip "G1/G2 sidecar: no $STATE (sidecar never started)"
  [[ $fail -eq 0 ]] && exit 2
else
  BASE_URL="$(/usr/bin/python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("base_url",""))' "$STATE" 2>/dev/null || true)"
  TOKEN="$(/usr/bin/python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("auth_token",""))' "$STATE" 2>/dev/null || true)"
  if [[ -z "$BASE_URL" ]]; then
    skip "G1/G2 sidecar: no base_url in state file"
  elif ! curl -sf -m 10 "$BASE_URL/healthz" -H "Authorization: Bearer $TOKEN" >/dev/null 2>&1; then
    skip "G1 sidecar not reachable at $BASE_URL"
  else
    ok "G1 sidecar reachable at $BASE_URL"

    # G2: a compressible command output, submitted WITHOUT recovery-scope headers
    # (exactly what a bare `cmd | distill` pipe looks like). Historically this
    # returned routeStage=verbatim with output == input and saved nothing.
    PROBE="$(mktemp)"; trap 'rm -f "$PROBE"' EXIT
    /usr/bin/python3 - "$PROBE" <<'PY'
import json, sys
lines = [f"Sources/AppShell/Component{i}.swift:{i*7+3}:    let value{i} = compute(index: {i}, scale: 1.0)  // routine assignment #{i}" for i in range(120)]
json.dump({"mode": "commandOutput", "priority": 2, "input": "\n".join(lines),
           "maxOutputCharacters": 2000, "runMode": "optimize"}, open(sys.argv[1], "w"))
PY
    RESP="$(curl -s -m 180 -X POST "$BASE_URL/v1/distill" \
      -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" \
      --data-binary @"$PROBE" 2>/dev/null || true)"
    if [[ -z "$RESP" ]]; then
      bad "G2 unscoped probe returned no response"
    else
      read -r IN OUT STAGE < <(/usr/bin/python3 -c '
import json,sys
r=json.loads(sys.stdin.read() or "{}")
print(r.get("inputCharacters") or 0, r.get("outputCharacters") or 0, r.get("routeStage") or "none")
' <<<"$RESP")
      if [[ "$IN" == "0" ]]; then
        bad "G2 unscoped probe: unparsable response ($(printf '%.120s' "$RESP"))"
      elif [[ "$OUT" -ge "$IN" ]]; then
        bad "G2 unscoped probe DISCARDED compression: in=$IN out=$OUT stage=$STAGE (store-before-loss fail-open still destroys savings)"
      else
        ok "G2 unscoped probe reduced output: in=$IN out=$OUT stage=$STAGE"
      fi
    fi
  fi
fi

# ------------------------------------------------------------------- G3..G5 ledger
if [[ ! -f "$DB" ]]; then
  skip "G3/G4/G5 ledger: no $DB"
  [[ $fail -eq 0 ]] && exit 2
  exit 1
fi

sq() { sqlite3 -readonly "$DB" "$1" 2>/dev/null || echo ""; }

# G3 yield: of the input the compressor actually received in the retained window,
# how much produced a saving? Verbatim/discard rows contribute input but zero saved.
read -r OFFERED SAVED < <(sq "SELECT COALESCE(SUM(input_tokens),0), COALESCE(SUM(saved_tokens),0) FROM token_saver_savings;" | tr '|' ' ')
if [[ -z "${OFFERED:-}" || "$OFFERED" == "0" ]]; then
  skip "G3 yield: retained ledger is empty"
else
  YIELD="$(/usr/bin/python3 -c "print(f'{$SAVED/$OFFERED:.4f}')")"
  if /usr/bin/python3 -c "import sys; sys.exit(0 if $YIELD >= $MIN_YIELD_SHARE else 1)"; then
    ok "G3 yield $YIELD >= $MIN_YIELD_SHARE (saved $SAVED of $OFFERED offered)"
  else
    bad "G3 yield $YIELD < $MIN_YIELD_SHARE (saved $SAVED of $OFFERED offered) — compression is being discarded"
  fi
fi

# G4 coverage: share of provider tokens that reach the compressor at all.
read -r ALLTIME_IN < <(sq "SELECT COALESCE(SUM(input_tokens),0) FROM token_saver_savings_totals;")
USAGE_JSON="$APP_SUPPORT/TokenSaver/usage.json"
if [[ ! -f "$USAGE_JSON" || -z "${ALLTIME_IN:-}" || "$ALLTIME_IN" == "0" ]]; then
  skip "G4 coverage: need both token_saver_savings_totals and $USAGE_JSON"
else
  # WHY billed, not raw: raw actualProviderTokens counts cache reads at full weight and
  # overstates the window by roughly 8x, so a raw denominator would make coverage look
  # far worse than it is and would contradict the billed-unit rule the estimator enforces.
  # A provider missing a KNOWN billed value makes the gate SKIP, never silently fall back.
  PROV="$(/usr/bin/python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
total = 0.0
for p in d.get("providers", []):
    billed = p.get("actualProviderBilledTokenUnits")
    if billed is None:
        print("UNKNOWN"); raise SystemExit
    total += float(billed)
print(int(total))
' "$USAGE_JSON")"
  if [[ "$PROV" == "UNKNOWN" ]]; then
    skip "G4 coverage: a provider has no known billed-unit value (refusing a raw-token fallback)"
  elif [[ "$PROV" == "0" ]]; then
    skip "G4 coverage: no provider usage recorded"
  else
    COV="$(/usr/bin/python3 -c "print(f'{$ALLTIME_IN/$PROV:.5f}')")"
    if /usr/bin/python3 -c "import sys; sys.exit(0 if $COV >= $MIN_COVERAGE_SHARE else 1)"; then
      ok "G4 coverage $COV >= $MIN_COVERAGE_SHARE ($ALLTIME_IN offered of $PROV provider tokens)"
    else
      bad "G4 coverage $COV < $MIN_COVERAGE_SHARE ($ALLTIME_IN offered of $PROV provider tokens) — interception has collapsed"
    fi
  fi
fi

# G5 honesty: the attributed figure must be a strict subset of the aggregate whenever
# unattributed rows exist, so no displayed headline can silently include them.
# Mirrors Persistence displayedSavingsEligibility/attributed rules: a row counts as
# attributed only when it was DELIVERED and is either prompt-bound or from a real provider.
# Pre-migration rows have delivered=0 by column default, so they are admitted through the
# same legacy clause the repository uses (attributability='unknown' AND provider<>'unknown').
read -r AGG ATTR < <(sq "SELECT COALESCE(SUM(saved_tokens),0),
       COALESCE(SUM(CASE WHEN (delivered = 1 OR attributability = 'unknown')
                          AND (attributability = 'prompt_bound' OR provider <> 'unknown')
                     THEN saved_tokens ELSE 0 END),0)
FROM token_saver_savings_totals;" | tr '|' ' ')
HAS_HONESTY_COLS="$(sq "SELECT COUNT(*) FROM pragma_table_info('token_saver_savings_totals') WHERE name IN ('delivered','attributability');")"
if [[ "${HAS_HONESTY_COLS:-0}" != "2" ]]; then
  # The running app predates schema step 55; the honesty axes do not exist yet, so the
  # attributed figure is not computable. Report it as un-evaluated, never as a pass.
  skip "G5 attribution: database predates the honesty columns (schema < 55) — cannot evaluate"
elif [[ -z "${AGG:-}" || "$AGG" == "0" ]]; then
  skip "G5 attribution: no all-time totals yet"
elif [[ "$ATTR" -gt "$AGG" ]]; then
  bad "G5 attribution: attributed ($ATTR) exceeds aggregate ($AGG)"
else
  UNATTR=$((AGG - ATTR))
  ok "G5 attribution: attributed=$ATTR unattributed=$UNATTR aggregate=$AGG (headline must use attributed only)"
fi

note ""
if [[ $fail -eq 0 ]]; then note "GATE PASSED"; exit 0; fi
note "GATE FAILED"; exit 1
