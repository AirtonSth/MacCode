#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
lease_root="$(mktemp -d "${TMPDIR:-/tmp}/remotecode-macos-ui-lease-test.XXXXXX")"
trap 'rm -rf "$lease_root"' EXIT

lease=(env RC_MACOS_UI_LEASE_DIR="$lease_root/lease" "$repo_root/scripts/macos-ui-lease.sh")

"${lease[@]}" -- sh -c 'sleep 2' &
holder_pid=$!
for _ in {1..20}; do
  [[ -d "$lease_root/lease/owner" ]] && break
  sleep 0.05
done
[[ -d "$lease_root/lease/owner" ]]

if "${lease[@]}" -- sh -c 'exit 99'; then
  echo "expected the second UI session to be rejected" >&2
  exit 1
fi
wait "$holder_pid"
[[ ! -e "$lease_root/lease/owner" ]]

if printf '%s\n' 'mac.key("cmd+k")' | "${lease[@]}" -- sh -c 'cat >/dev/null'; then
  echo "expected input action to require --allow-input" >&2
  exit 1
fi

printf '%s\n' 'print(mac.see("io.remotecode.desktop.debug"))' \
  | "${lease[@]}" -- sh -c 'cat >/dev/null'
printf '%s\n' 'mac.key("cmd+k")' \
  | "${lease[@]}" --allow-input -- sh -c 'cat >/dev/null'

echo "macOS UI lease tests passed"
