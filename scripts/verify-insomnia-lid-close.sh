#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

APP_PATH="${RC2_INSOMNIA_PROOF_APP:-/tmp/RemoteCodeInsomnia.app}"
BUNDLE_ID="${RC2_INSOMNIA_PROOF_BUNDLE_ID:-io.remotecode.desktop.lidproof}"
APP_SUPPORT="${RC2_INSOMNIA_PROOF_SUPPORT:-/tmp/RC2InsomniaLidProof}"
CONFIG="${RC2_CONFIG:-debug}"
LID_WAIT_SECONDS="${RC2_INSOMNIA_LID_WAIT_SECONDS:-30}"

sleep_disabled() {
  /usr/bin/pmset -g | /usr/bin/awk '/SleepDisabled/{print $2}'
}

insomnia_processes() {
  /bin/ps -axo pid=,ppid=,user=,stat=,command= \
    | /usr/bin/grep -E 'RemoteCodeInsomnia.app/Contents/MacOS/RemoteCode' \
    | /usr/bin/grep -v grep || true
}

wait_for_sleep_disabled() {
  local want="$1"
  local label="$2"
  for _ in {1..30}; do
    if [ "$(sleep_disabled)" = "$want" ]; then
      echo "[proof] $label SleepDisabled=$want"
      return 0
    fi
    /bin/sleep 1
  done
  echo "[proof] FAIL waiting for $label SleepDisabled=$want; got $(sleep_disabled)" >&2
  return 1
}

cleanup() {
  /usr/bin/osascript -e "tell application id \"${BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true
  /bin/sleep 3
}
trap cleanup EXIT

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

rm -rf "$APP_PATH" "$APP_SUPPORT"
mkdir -p "$APP_SUPPORT"

echo "[proof] baseline SleepDisabled=$(sleep_disabled)"
echo "[proof] packaging $APP_PATH"
RC2_CONFIG="$CONFIG" \
RC2_PACKAGE_APP_OUTPUT="$APP_PATH" \
RC2_BUNDLE_ID="$BUNDLE_ID" \
./scripts/package-app.sh >/tmp/remote-code-insomnia-lid-package.log

echo "[proof] seeding Insomnia enabled for proof run"
/usr/bin/sqlite3 "$APP_SUPPORT/remotecode.sqlite" <<SQL
CREATE TABLE IF NOT EXISTS settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
INSERT OR REPLACE INTO settings(key, value, updated_at) VALUES(
  'app_settings',
  '{"diffWordWrap":false,"diffIgnoreWhitespace":false,"sidebarSort":"updated","insomniaEnabled":true,"insomniaAllowDisplaySleep":true,"insomniaAllowSystemSleepWhenDisplayClosed":false,"insomniaAllowScreenSaverAfter45MinutesOfInactivity":true}',
  datetime('now')
);
SQL

start_epoch="$(/bin/date +%s)"
echo "[proof] launching Insomnia proof app"
RC2_CHANNEL=canary RC2_APP_SUPPORT="$APP_SUPPORT" "$APP_PATH/Contents/MacOS/RemoteCode" >/tmp/remote-code-insomnia-lid-app.log 2>&1 &
app_pid="$!"

wait_for_sleep_disabled 1 "active"
echo "[proof] Insomnia proof process:"
insomnia_processes

echo "[proof] close the Mac display now for at least ${LID_WAIT_SECONDS}s, then reopen and press Enter."
read -r _

echo "[proof] after lid cycle SleepDisabled=$(sleep_disabled)"
if ! /bin/kill -0 "$app_pid" 2>/dev/null; then
  echo "[proof] FAIL app process is not running after lid cycle" >&2
  exit 1
fi
wait_for_sleep_disabled 1 "post-lid"

echo "[proof] quitting app and verifying restore"
cleanup
wait_for_sleep_disabled 0 "restored"

end_epoch="$(/bin/date +%s)"
echo "[proof] pmset log excerpt since ${start_epoch}:"
/usr/bin/pmset -g log \
  | /usr/bin/awk -v start="$start_epoch" -v end="$end_epoch" '
      /Clamshell|Sleep|Wake|SleepDisabled|Entering Sleep|Wake from/ { print }
    ' \
  | /usr/bin/tail -80

echo "[proof] PASS lid cycle kept Insomnia active and restored SleepDisabled=0"
