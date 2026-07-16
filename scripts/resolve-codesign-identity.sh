#!/usr/bin/env bash
# Resolve a codesign identity for local RemoteCode.app packaging.
#
# WHY: Ad-hoc signatures (`codesign --sign -`) bind macOS TCC (Files & Folders /
# Network Volumes) to a CDHash that changes whenever the app payload changes.
# Apple Development / Developer ID identities keep a stable designated
# requirement (bundle id + team / cert CN), so "Allow" survives rebuilds.
#
# Contract (pure; unit-tested via scripts/test-resolve-codesign-identity.sh):
#   Input env:
#     RC2_CODESIGN_IDENTITY  if set (including "-"), use exactly that value
#     RC2_CODESIGN_IDENTITY_LIST  optional newline list of identities to consider
#       when auto-picking (test seam). Lines look like:
#         1) DEADBEEF… "Apple Development: Name (TEAM)"
#       Lines containing CSSMERR / revoked are ignored.
#   If RC2_CODESIGN_IDENTITY is unset:
#     Prefer a single unique "Apple Development: …" common name from the list
#     (or from `security find-identity -v -p codesigning` when list unset).
#     Output the first non-revoked certificate HASH for that CN (codesign rejects
#     ambiguous CNs that match multiple keychain certs).
#     If zero or multiple distinct development CNs → fall back to "-".
#   Output (stdout): identity string to pass to `codesign --sign`
#   Status line (stderr): durable|adhoc reason
#
# Compatible with macOS /bin/bash 3.2 (no mapfile / associative arrays).
set -euo pipefail

emit_status() {
  # stderr so callers can capture identity on stdout alone
  echo "[codesign-identity] $*" >&2
}

if [ -n "${RC2_CODESIGN_IDENTITY+x}" ]; then
  # Explicit override, including forced ad-hoc ("-") and empty → treat empty as ad-hoc.
  if [ -z "${RC2_CODESIGN_IDENTITY}" ] || [ "${RC2_CODESIGN_IDENTITY}" = "-" ]; then
    emit_status "adhoc reason=explicit_override"
    echo "-"
    exit 0
  fi
  emit_status "durable reason=explicit_override identity=${RC2_CODESIGN_IDENTITY}"
  echo "${RC2_CODESIGN_IDENTITY}"
  exit 0
fi

identity_source() {
  if [ -n "${RC2_CODESIGN_IDENTITY_LIST+x}" ]; then
    printf '%s\n' "${RC2_CODESIGN_IDENTITY_LIST}"
  else
    security find-identity -v -p codesigning 2>/dev/null || true
  fi
}

# Non-revoked Apple Development lines only: "HASH\tCN"
DEV_ROWS="$(
  identity_source \
    | grep -F 'Apple Development:' \
    | grep -viE 'CSSMERR|revoked' \
    | sed -n 's/.*[0-9])[[:space:]]*\([A-F0-9]\{40\}\)[[:space:]]*"\(Apple Development: [^"]*\)".*/\1	\2/p' \
    || true
)"

if [ -z "$DEV_ROWS" ]; then
  emit_status "adhoc reason=no_apple_development_identity"
  echo "-"
  exit 0
fi

DEV_NAMES="$(printf '%s\n' "$DEV_ROWS" | cut -f2 | sort -u)"
count="$(printf '%s\n' "$DEV_NAMES" | grep -c . || true)"

if [ "$count" -ne 1 ]; then
  emit_status "adhoc reason=ambiguous_apple_development_identities count=${count}"
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    emit_status "candidate identity=${n}"
  done <<EOF
$DEV_NAMES
EOF
  echo "-"
  exit 0
fi

name="$(printf '%s\n' "$DEV_NAMES" | head -n 1)"
# First hash for that CN — codesign requires a unique selector when several
# certs share the same common name in the keychain.
hash="$(printf '%s\n' "$DEV_ROWS" | grep -F "	${name}" | head -n 1 | cut -f1)"
if [ -z "$hash" ]; then
  emit_status "adhoc reason=missing_hash_for_unique_cn"
  echo "-"
  exit 0
fi

emit_status "durable reason=auto_unique_apple_development identity=${name} hash=${hash}"
echo "$hash"
exit 0
