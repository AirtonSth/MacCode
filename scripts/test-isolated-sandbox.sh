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
printf '// sandbox fixture\n' >"$TMP/Package.swift"
mkdir -p "$TMP/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP/scripts/package-app.sh"
printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP/scripts/test-unit.sh"
chmod +x "$TMP/scripts/package-app.sh" "$TMP/scripts/test-unit.sh"
git -C "$TMP" add README Package.swift scripts/package-app.sh scripts/test-unit.sh
git -C "$TMP" commit -m init >/dev/null

if (cd "$TMP" && "$SANDBOX" test >/dev/null 2>&1); then
  fail "test must refuse the primary checkout"
fi
if (cd "$TMP" && "$SANDBOX" build >/dev/null 2>&1); then
  fail "build must refuse the primary checkout"
fi

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

FAKE_BIN="$TMP/fake-bin"
CAPTURE="$TMP/test-environment"
SUPPORT="$WT/private app support"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/swift" <<'EOF'
#!/usr/bin/env bash
printf 'CFFIXED_USER_HOME=%s\n' "${CFFIXED_USER_HOME:-}" >"$RC2_CAPTURE"
printf 'RC2_APP_SUPPORT=%s\n' "${RC2_APP_SUPPORT:-}" >>"$RC2_CAPTURE"
printf 'RC2_CHANNEL=%s\n' "${RC2_CHANNEL:-}" >>"$RC2_CAPTURE"
printf 'RC2_HTTP_PORT=%s\n' "${RC2_HTTP_PORT:-}" >>"$RC2_CAPTURE"
printf 'RC2_BUNDLE_ID=%s\n' "${RC2_BUNDLE_ID:-}" >>"$RC2_CAPTURE"
printf 'RC2_DB_PATH=%s\n' "${RC2_DB_PATH:-}" >>"$RC2_CAPTURE"
printf '__CFPREFERENCES_AVOID_DAEMON=%s\n' "${__CFPREFERENCES_AVOID_DAEMON:-}" >>"$RC2_CAPTURE"
if [ -d "${CFFIXED_USER_HOME:-}/Library/Preferences" ]; then
  printf 'PREFERENCES_DIRECTORY=present\n' >>"$RC2_CAPTURE"
fi
case "${RC2_PREFS_ACTION:-}" in
  write)
    "$RC2_REAL_SWIFT" -e '
      import Foundation
      let environment = ProcessInfo.processInfo.environment
      let key = environment["RC2_PREFS_KEY"]!
      UserDefaults.standard.set("writer-a", forKey: key)
      guard UserDefaults.standard.synchronize() else { exit(2) }
    '
    ;;
  read)
    "$RC2_REAL_SWIFT" -e '
      import Foundation
      let environment = ProcessInfo.processInfo.environment
      let key = environment["RC2_PREFS_KEY"]!
      let result = UserDefaults.standard.string(forKey: key) ?? "nil"
      try! result.write(
        toFile: environment["RC2_PREFS_RESULT"]!,
        atomically: true,
        encoding: .utf8
      )
    '
    ;;
esac
EOF
chmod +x "$FAKE_BIN/swift"
REAL_SWIFT="$(xcrun --find swift)"
(
  cd "$WT"
  PATH="$FAKE_BIN:$PATH" \
    RC2_CAPTURE="$CAPTURE" \
    RC2_REAL_SWIFT="$REAL_SWIFT" \
    RC2_SANDBOX_APP_SUPPORT="$SUPPORT" \
    RC2_SANDBOX_BUNDLE_ID=io.remotecode.desktop.debug.test-isolated \
    RC2_SANDBOX_CHANNEL=test-isolated \
    RC2_SANDBOX_HTTP_PORT=19401 \
    "$SANDBOX" test --filter NoTests
)
grep -Fqx "CFFIXED_USER_HOME=$SUPPORT/TestUserHome" "$CAPTURE" \
  || fail "test must scope CFFIXED_USER_HOME beneath sandbox App Support"
grep -Fqx "RC2_APP_SUPPORT=$SUPPORT" "$CAPTURE" \
  || fail "test must export sandbox App Support"
grep -Fqx 'RC2_CHANNEL=test-isolated' "$CAPTURE" \
  || fail "test must export sandbox channel"
grep -Fqx 'RC2_HTTP_PORT=19401' "$CAPTURE" \
  || fail "test must export sandbox HTTP port"
grep -Fqx 'RC2_BUNDLE_ID=io.remotecode.desktop.debug.test-isolated' "$CAPTURE" \
  || fail "test must export sandbox bundle id"
grep -Fqx "RC2_DB_PATH=$SUPPORT/remotecode.sqlite" "$CAPTURE" \
  || fail "test must export sandbox database path"
grep -Fqx '__CFPREFERENCES_AVOID_DAEMON=1' "$CAPTURE" \
  || fail "test must bypass cfprefsd for sandboxed SwiftPM tests"
grep -Fqx 'PREFERENCES_DIRECTORY=present' "$CAPTURE" \
  || fail "test must create the sandbox preferences directory before Swift starts"

PREFS_KEY="rc2.sandbox.$$.${RANDOM}"
PREFS_RESULT="$TMP/preferences-read-result"
for action in write read; do
  case "$action" in
    write) ACTION_SUPPORT="$WT/preferences writer" ;;
    read) ACTION_SUPPORT="$WT/preferences reader" ;;
  esac
  (
    cd "$WT"
    PATH="$FAKE_BIN:$PATH" \
      RC2_CAPTURE="$CAPTURE" \
      RC2_REAL_SWIFT="$REAL_SWIFT" \
      RC2_PREFS_ACTION="$action" \
      RC2_PREFS_KEY="$PREFS_KEY" \
      RC2_PREFS_RESULT="$PREFS_RESULT" \
      RC2_SANDBOX_APP_SUPPORT="$ACTION_SUPPORT" \
      RC2_SANDBOX_BUNDLE_ID=io.remotecode.desktop.debug.preferences-isolation \
      RC2_SANDBOX_CHANNEL=preferences-isolation \
      RC2_SANDBOX_HTTP_PORT=19402 \
      "$SANDBOX" test --filter NoTests
  )
done
[ "$(cat "$PREFS_RESULT")" = "nil" ] \
  || fail "UserDefaults.standard leaked across sandbox preference homes"

echo "OK isolated-sandbox invariants"
