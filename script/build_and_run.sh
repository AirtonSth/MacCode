#!/usr/bin/env bash
# Agent-safe build/launch. Packages io.remotecode.desktop.debug only.
# Never packages or quits the user's io.remotecode.desktop host.
# To replace the host app, run scripts/run-app.sh from an external terminal.
set -euo pipefail

cd "$(dirname "$0")/.."

VERIFY=0
for arg in "$@"; do
  case "$arg" in
    --verify)
      VERIFY=1
      ;;
    -h|--help)
      echo "usage: script/build_and_run.sh [--verify]" >&2
      echo "Builds and launches dist/RemoteCodeDebug.app via scripts/isolated-sandbox.sh." >&2
      echo "Does not package or quit io.remotecode.desktop." >&2
      echo "To replace the host app, use scripts/run-app.sh from an external terminal." >&2
      exit 0
      ;;
    *)
      echo "[build_and_run] unexpected argument: $arg" >&2
      echo "usage: script/build_and_run.sh [--verify]" >&2
      exit 2
      ;;
  esac
done

SANDBOX="./scripts/isolated-sandbox.sh"
[ -x "$SANDBOX" ] || {
  echo "[build_and_run] missing $SANDBOX" >&2
  exit 2
}

if [ -z "${RC2_SANDBOX_ALLOW_PRIMARY:-}" ]; then
  if IDENTITY="$("$SANDBOX" identity 2>/dev/null)"; then
    if grep -Fqx 'linked_worktree=no' <<<"$IDENTITY"; then
      export RC2_SANDBOX_ALLOW_PRIMARY=1
    fi
  fi
fi

"$SANDBOX" run

if [ "$VERIFY" -ne 1 ]; then
  exit 0
fi

awk_file="scripts/exact-executable-pids.awk"
executable="dist/RemoteCodeDebug.app/Contents/MacOS/RemoteCode"
[ -f "$awk_file" ] || {
  echo "[build_and_run] missing $awk_file" >&2
  exit 2
}
[ -e "$executable" ] || {
  echo "[build_and_run] missing $executable" >&2
  exit 1
}
abs_exec="$(cd "$(dirname "$executable")" && pwd -P)/$(basename "$executable")"
for _ in {1..20}; do
  pids="$(ps -axo pid=,command= | awk -v executable="$abs_exec" -f "$awk_file")"
  if [ -n "$pids" ]; then
    echo "[run] RemoteCode debug app is running"
    exit 0
  fi
  sleep 0.25
done
echo "[build_and_run] debug app did not stay running" >&2
exit 1
