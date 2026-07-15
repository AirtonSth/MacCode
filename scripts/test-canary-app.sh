#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
CANARY="$SCRIPT_DIR/canary-app.sh"
ROOT="${TMPDIR:-/tmp}/RemoteCodeAgentCanary-test-$$"
UNSAFE_ROOT="${TMPDIR:-/tmp}/remote-code-unsafe-test-$$"
PACKAGER="$ROOT/fake-package-app.sh"
DECOY_PID=""

cleanup() {
  set +e
  RC2_CANARY_ROOT="$ROOT" RC2_CANARY_PACKAGE_SCRIPT="$PACKAGER" "$CANARY" stop >/dev/null 2>&1
  if [ -n "$DECOY_PID" ]; then kill "$DECOY_PID" >/dev/null 2>&1; fi
  rm -rf "$ROOT" "$UNSAFE_ROOT"
}
trap cleanup EXIT

mkdir -p "$ROOT"
ROOT="$(cd "$ROOT" && pwd -P)"
PACKAGER="$ROOT/fake-package-app.sh"
cat > "$PACKAGER" <<'PACKAGE'
#!/usr/bin/env bash
set -euo pipefail
app="${RC2_PACKAGE_APP_OUTPUT:?}"
mkdir -p "$app/Contents/MacOS"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>CFBundleDisplayName</key><string>RemoteCode</string>
  <key>CFBundleExecutable</key><string>RemoteCode</string>
  <key>CFBundleIdentifier</key><string>${RC2_BUNDLE_ID:?}</string>
  <key>CFBundleName</key><string>RemoteCode</string>
  <key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
/usr/bin/xcrun clang -x c -o "$app/Contents/MacOS/RemoteCode" - <<'C'
#include <signal.h>
#include <unistd.h>
static volatile sig_atomic_t running = 1;
static void stop(int signal) { (void)signal; running = 0; }
int main(void) {
  signal(SIGTERM, stop);
  signal(SIGINT, stop);
  while (running) pause();
  return 0;
}
C
PACKAGE
chmod +x "$PACKAGER"

run_canary() {
  RC2_CANARY_ROOT="$ROOT" RC2_CANARY_PACKAGE_SCRIPT="$PACKAGER" "$CANARY" "$@"
}

bash -n "$CANARY"
if grep -q 'pkill' "$CANARY"; then
  echo "FAIL: broad process kill found in canary harness" >&2
  exit 1
fi

run_canary build
APP="$ROOT/app/RemoteCodeAgentCanary.app"
EXECUTABLE="$APP/Contents/MacOS/RemoteCodeAgentCanary"
PLIST="$APP/Contents/Info.plist"
[ -x "$EXECUTABLE" ]
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")" = "io.remotecode.desktop.agent-canary" ]
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$PLIST")" = "RemoteCodeAgentCanary" ]
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST")" = "RemoteCodeAgentCanary" ]

run_canary run
run_canary status
PID="$(tr -d '[:space:]' < "$ROOT/run/RemoteCodeAgentCanary.pid")"
LOADED_EXECUTABLE="$(/usr/sbin/lsof -a -p "$PID" -d txt -Fn | awk '/^n/ { sub(/^n/, ""); print; exit }')"
[ "$LOADED_EXECUTABLE" = "$EXECUTABLE" ]

mkdir -p "$ROOT/decoy"
cp "$EXECUTABLE" "$ROOT/decoy/RemoteCode"
"$ROOT/decoy/RemoteCode" &
DECOY_PID=$!
run_canary stop
kill -0 "$DECOY_PID"
if run_canary status >/dev/null 2>&1; then
  echo "FAIL: canary still reports running after stop" >&2
  exit 1
fi

mkdir -p "$ROOT/state/Application Support/RemoteCodeAgentCanary"
printf 'state' > "$ROOT/state/Application Support/RemoteCodeAgentCanary/RemoteCode.sqlite"
printf 'outside' > "$ROOT/outside.txt"
run_canary reset-state
[ ! -e "$ROOT/state/Application Support/RemoteCodeAgentCanary" ]
[ -e "$ROOT/outside.txt" ]
[ -e "$APP" ]

mkdir -p "$UNSAFE_ROOT"
printf 'survive' > "$UNSAFE_ROOT/sentinel"
if RC2_CANARY_ROOT="$UNSAFE_ROOT" "$CANARY" reset-state >/dev/null 2>&1; then
  echo "FAIL: reset-state accepted an unvalidated root" >&2
  exit 1
fi
[ -e "$UNSAFE_ROOT/sentinel" ]

echo "PASS: canary build/run/stop/status/reset-state isolation"
