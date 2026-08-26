#!/usr/bin/env bash
# Safety invariants for script/build_and_run.sh. Does not package the app.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
LAUNCHER="$REPO_ROOT/script/build_and_run.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ -x "$LAUNCHER" ] || fail "missing $LAUNCHER"
bash -n "$LAUNCHER"

if grep -E -q '^[^#]*\bpkill\b' "$LAUNCHER"; then
  fail "build_and_run.sh must not call pkill"
fi
if grep -E -q '^[^#]*osascript' "$LAUNCHER"; then
  fail "build_and_run.sh must not call osascript"
fi
if grep -E -q '^[[:space:]]*(exec[[:space:]]+)?(\./)?scripts/run-app\.sh' "$LAUNCHER"; then
  fail "build_and_run.sh must not invoke run-app.sh"
fi
grep -F -q 'isolated-sandbox.sh' "$LAUNCHER" \
  || fail "build_and_run.sh must invoke isolated-sandbox.sh"
grep -F -q 'RemoteCodeDebug.app' "$LAUNCHER" \
  || fail "build_and_run.sh must verify the debug bundle path"

if "$LAUNCHER" --bogus >/dev/null 2>&1; then
  fail "must reject unexpected arguments"
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/rc-build-and-run.XXXXXX")"
cleanup() {
  if [ -n "${FAKE_PID:-}" ]; then
    kill "$FAKE_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

mkdir -p "$TMP/script" "$TMP/scripts"
cp "$LAUNCHER" "$TMP/script/build_and_run.sh"
cp "$REPO_ROOT/scripts/exact-executable-pids.awk" "$TMP/scripts/exact-executable-pids.awk"
chmod +x "$TMP/script/build_and_run.sh"

CAPTURE="$TMP/sandbox-capture"
PIDFILE="$TMP/fake.pid"
cat >"$TMP/scripts/isolated-sandbox.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'cmd=%s\n' "$1" >>"$RC2_CAPTURE"
printf 'RC2_SANDBOX_ALLOW_PRIMARY=%s\n' "${RC2_SANDBOX_ALLOW_PRIMARY:-}" >>"$RC2_CAPTURE"
case "$1" in
  identity)
    printf 'linked_worktree=%s\n' "${STUB_LINKED:-yes}"
    ;;
  run)
    mkdir -p dist/RemoteCodeDebug.app/Contents/MacOS
    abs_exec="$(cd dist/RemoteCodeDebug.app/Contents/MacOS && pwd -P)/RemoteCode"
    : >"$abs_exec"
    chmod +x "$abs_exec"
    ABS_EXEC="$abs_exec" python3 -c 'import os; os.execl("/bin/sleep", os.environ["ABS_EXEC"], "30")' &
    printf '%s\n' "$!" >"$RC2_PIDFILE"
    echo "[sandbox] running pid $!"
    ;;
  *)
    exit 2
    ;;
esac
EOF
chmod +x "$TMP/scripts/isolated-sandbox.sh"

(
  cd "$TMP"
  RC2_CAPTURE="$CAPTURE" RC2_PIDFILE="$PIDFILE" \
    ./script/build_and_run.sh --verify
) || fail "sandbox --verify should succeed against a stub debug executable"

FAKE_PID="$(cat "$PIDFILE")"
kill -0 "$FAKE_PID" 2>/dev/null || fail "stub debug executable should still be running"
grep -Fqx 'cmd=run' "$CAPTURE" || fail "must invoke isolated-sandbox.sh run"
run_allow="$(awk '$0=="cmd=run" { getline; print }' "$CAPTURE")"
[ "$run_allow" = "RC2_SANDBOX_ALLOW_PRIMARY=" ] \
  || fail "linked worktree must not force RC2_SANDBOX_ALLOW_PRIMARY, got: $run_allow"

rm -f "$CAPTURE" "$PIDFILE"
kill "$FAKE_PID" 2>/dev/null || true
FAKE_PID=""

(
  cd "$TMP"
  STUB_LINKED=no RC2_CAPTURE="$CAPTURE" RC2_PIDFILE="$PIDFILE" \
    ./script/build_and_run.sh
) || fail "primary checkout should succeed by setting RC2_SANDBOX_ALLOW_PRIMARY=1"

FAKE_PID="$(cat "$PIDFILE")"
grep -Fqx 'cmd=run' "$CAPTURE" || fail "primary path must invoke isolated-sandbox.sh run"
run_allow="$(awk '$0=="cmd=run" { getline; print }' "$CAPTURE")"
[ "$run_allow" = "RC2_SANDBOX_ALLOW_PRIMARY=1" ] \
  || fail "primary checkout must set RC2_SANDBOX_ALLOW_PRIMARY=1, got: $run_allow"

echo "OK build_and_run invariants"
