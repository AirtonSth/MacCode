#!/usr/bin/env bash
# Unit tests for scripts/resolve-codesign-identity.sh
#
# WHY: Local packages must pick a stable Apple Development identity when one
# unique CN exists so Network Volumes / Files & Folders TCC "Allow" survives
# rebuilds. When several cert hashes share one CN, codesign requires the HASH
# (not the CN string) — the resolver must emit a hash. Ad-hoc remains explicit
# or a safe fallback; never silent auto-pick among ambiguous CNs.
set -euo pipefail
cd "$(dirname "$0")/.."
RESOLVER="./scripts/resolve-codesign-identity.sh"
chmod +x "$RESOLVER"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# Isolate from the caller's environment.
unset RC2_CODESIGN_IDENTITY || true
unset RC2_CODESIGN_IDENTITY_LIST || true

# 1) Explicit durable override (name or hash passthrough)
out="$(RC2_CODESIGN_IDENTITY='Apple Development: Example (TEAM)' "$RESOLVER" 2>/dev/null)"
[ "$out" = 'Apple Development: Example (TEAM)' ] || fail "explicit durable got: $out"
pass "explicit durable override"

# 2) Explicit ad-hoc
out="$(RC2_CODESIGN_IDENTITY='-' "$RESOLVER" 2>/dev/null)"
[ "$out" = '-' ] || fail "explicit adhoc got: $out"
pass "explicit ad-hoc override"

# 3) Empty explicit → ad-hoc
out="$(RC2_CODESIGN_IDENTITY='' "$RESOLVER" 2>/dev/null)"
[ "$out" = '-' ] || fail "empty explicit got: $out"
pass "empty explicit is ad-hoc"

# 4) Auto: unique CN with multiple hashes → emit first hash (codesign-unambiguous)
LIST=$'  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Apple Development: Sam (TEAM)"\n  2) BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB "Apple Development: Sam (TEAM)"\n  3) CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC "Apple Distribution: Sam (TEAM)"'
out="$(RC2_CODESIGN_IDENTITY_LIST="$LIST" "$RESOLVER" 2>/dev/null)"
[ "$out" = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' ] || fail "unique auto hash got: $out"
pass "auto unique CN emits certificate hash"

# 5) Auto: revoked lines ignored → unique remaining hash
LIST=$'  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Apple Development: Sam (TEAM)" (CSSMERR_TP_CERT_REVOKED)\n  2) BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB "Apple Development: Sam (TEAM)"'
out="$(RC2_CODESIGN_IDENTITY_LIST="$LIST" "$RESOLVER" 2>/dev/null)"
[ "$out" = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB' ] || fail "revoked filter got: $out"
pass "revoked identities ignored"

# 6) Auto: ambiguous distinct development names → ad-hoc
LIST=$'  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Apple Development: Sam (TEAM1)"\n  2) BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB "Apple Development: Other (TEAM2)"'
out="$(RC2_CODESIGN_IDENTITY_LIST="$LIST" "$RESOLVER" 2>/dev/null)"
[ "$out" = '-' ] || fail "ambiguous auto got: $out"
pass "ambiguous development CNs fall back to ad-hoc"

# 7) Auto: no development identities → ad-hoc
LIST=$'  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Apple Distribution: Sam (TEAM)"\n     0 valid identities found'
out="$(RC2_CODESIGN_IDENTITY_LIST="$LIST" "$RESOLVER" 2>/dev/null)"
[ "$out" = '-' ] || fail "none auto got: $out"
pass "no development identity falls back to ad-hoc"

# 8) Status channel is stderr (stdout is identity only)
err="$(RC2_CODESIGN_IDENTITY='-' "$RESOLVER" 2>&1 >/dev/null)"
echo "$err" | grep -q 'adhoc reason=explicit_override' || fail "status missing: $err"
pass "status on stderr"

# 9) Auto status includes both CN and hash
LIST=$'  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Apple Development: Sam (TEAM)"'
err="$(RC2_CODESIGN_IDENTITY_LIST="$LIST" "$RESOLVER" 2>&1 >/dev/null)"
echo "$err" | grep -q 'durable reason=auto_unique_apple_development' || fail "durable status missing: $err"
echo "$err" | grep -q 'hash=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' || fail "hash status missing: $err"
pass "auto status reports CN and hash"

echo "All resolve-codesign-identity tests passed."
