#!/usr/bin/env bash
# Safety invariants for scripts/isolated-sandbox.sh. Does not package the app.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
SANDBOX="$SCRIPT_DIR/isolated-sandbox.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

bash -n "$SANDBOX"
chmod +x "$SANDBOX"

if grep -E -q '^[^#]*\bpkill\b' "$SANDBOX"; then
  fail "isolated-sandbox.sh must not call pkill"
fi
if grep -F -q 'io.remotecode.desktop" to quit' "$SANDBOX"; then
  fail "isolated-sandbox.sh must not quit the stable bundle id"
fi
if grep -F -q 'script/build_and_run.sh' "$SANDBOX"; then
  fail "isolated-sandbox.sh must not invoke build_and_run.sh"
fi

cd "$REPO_ROOT"
IDENTITY="$("$SANDBOX" identity)"
printf '%s\n' "$IDENTITY" | grep -qx 'bundle_id=io.remotecode.desktop.debug' \
  || fail "default bundle_id must be debug, got: $IDENTITY"
printf '%s\n' "$IDENTITY" | grep -qx 'channel=debug' \
  || fail "default channel must be debug"
printf '%s\n' "$IDENTITY" | grep -qx 'http_port=18218' \
  || fail "default http_port must be 18218"
printf '%s\n' "$IDENTITY" | grep -qx 'stable_bundle_id=io.remotecode.desktop' \
  || fail "identity must name the forbidden stable bundle"
SANDBOX_HOME="$(printf '%s\n' "$IDENTITY" | sed -n 's/^sandbox_home=//p')"
[ "$SANDBOX_HOME" = "$REPO_ROOT/.sandbox-state/home" ] \
  || fail "default sandbox home must stay inside the worktree, got: $SANDBOX_HOME"
grep -F -q 'CFFIXED_USER_HOME="$home"' "$SANDBOX" \
  || fail "run must redirect Foundation home resolution into the sandbox"
grep -F -q 'CODEX_HOME="$home/.codex"' "$SANDBOX" \
  || fail "run must redirect Codex state into the sandbox"
grep -F -q 'RC2_DISABLE_MANAGED_DISTILL_RECONCILE=1' "$SANDBOX" \
  || fail "run must forbid provider-home reconciliation"

if RC2_SANDBOX_BUNDLE_ID=io.remotecode.desktop "$SANDBOX" identity >/dev/null 2>&1; then
  fail "must refuse stable bundle id"
fi
if RC2_SANDBOX_CHANNEL=stable "$SANDBOX" identity >/dev/null 2>&1; then
  fail "must refuse stable channel"
fi
PRIMARY_ROOT="$(printf '%s\n' "$IDENTITY" | sed -n 's/^primary_worktree=//p')"
[ -d "$PRIMARY_ROOT" ] || fail "identity did not resolve the primary worktree"
if (cd "$PRIMARY_ROOT" && "$SANDBOX" test >/dev/null 2>&1); then
  fail "test must refuse the primary checkout"
fi
if (cd "$PRIMARY_ROOT" && "$SANDBOX" build >/dev/null 2>&1); then
  fail "build must refuse the primary checkout"
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/rc-isolated-sandbox.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

git -C "$TMP" init -b production >/dev/null
git -C "$TMP" config user.email "sandbox@test.local"
git -C "$TMP" config user.name "sandbox"
printf 'ok\n' >"$TMP/README"
git -C "$TMP" add README
git -C "$TMP" commit -m init >/dev/null

WT="$(cd "$TMP" && "$SANDBOX" ensure)"
[ -d "$WT" ] || fail "ensure did not print an existing directory: $WT"
[ "$WT" != "$TMP" ] || fail "ensure must not reuse the primary path"
git -C "$WT" rev-parse --is-inside-work-tree >/dev/null
case "$(git -C "$WT" rev-parse --abbrev-ref HEAD)" in
  sandbox/isolated-*) ;;
  *) fail "ensure branch must be sandbox/isolated-*, got $(git -C "$WT" rev-parse --abbrev-ref HEAD)" ;;
esac
REUSE="$(cd "$WT" && "$SANDBOX" ensure)"
[ "$REUSE" = "$WT" ] || fail "ensure inside a worktree must print the same path"

echo "OK isolated-sandbox invariants"
