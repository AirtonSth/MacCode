#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
CANARY_NAME="RemoteCodeAgentCanary"
BUNDLE_ID="io.remotecode.desktop.agent-canary"
CANARY_ROOT="${RC2_CANARY_ROOT:-${TMPDIR:-/tmp}/$CANARY_NAME}"
PACKAGE_SCRIPT="${RC2_CANARY_PACKAGE_SCRIPT:-$SCRIPT_DIR/package-app.sh}"

validate_canary_root() {
  case "$(basename "$CANARY_ROOT")" in
    "$CANARY_NAME"|"$CANARY_NAME"-*) ;;
    *)
      echo "[canary] refusing unsafe root without $CANARY_NAME identity: $CANARY_ROOT" >&2
      exit 2
      ;;
  esac
  mkdir -p "$CANARY_ROOT"
  CANARY_ROOT="$(cd "$CANARY_ROOT" && pwd -P)"
  case "$(basename "$CANARY_ROOT")" in
    "$CANARY_NAME"|"$CANARY_NAME"-*) ;;
    *)
      echo "[canary] refusing resolved unsafe root: $CANARY_ROOT" >&2
      exit 2
      ;;
  esac
}

validate_canary_root

APP_PATH="$CANARY_ROOT/app/$CANARY_NAME.app"
EXECUTABLE="$APP_PATH/Contents/MacOS/$CANARY_NAME"
APP_SUPPORT="$CANARY_ROOT/state/Application Support/$CANARY_NAME"
DB_PATH="$APP_SUPPORT/RemoteCode.sqlite"
RUN_DIR="$CANARY_ROOT/run"
PID_FILE="$RUN_DIR/$CANARY_NAME.pid"
LOG_FILE="$RUN_DIR/$CANARY_NAME.log"

is_path_inside_canary() {
  local path="$1"
  case "$path" in
    "$CANARY_ROOT"/*) return 0 ;;
    *) return 1 ;;
  esac
}

read_pid() {
  [ -f "$PID_FILE" ] || return 1
  local pid
  pid="$(tr -d '[:space:]' < "$PID_FILE")"
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$pid"
}

pid_uses_canary_executable() {
  local pid="$1"
  kill -0 "$pid" 2>/dev/null || return 1
  local loaded_executable
  loaded_executable="$(/usr/sbin/lsof -a -p "$pid" -d txt -Fn 2>/dev/null | awk '/^n/ { sub(/^n/, ""); print; exit }')"
  [ "$loaded_executable" = "$EXECUTABLE" ]
}

stop_canary() {
  local pid
  if ! pid="$(read_pid)"; then
    rm -f "$PID_FILE"
    echo "[canary] stopped"
    return 0
  fi
  if ! pid_uses_canary_executable "$pid"; then
    rm -f "$PID_FILE"
    echo "[canary] stale pid $pid ignored; exact canary executable is not running"
    return 0
  fi

  kill -TERM "$pid"
  for _ in {1..40}; do
    if ! pid_uses_canary_executable "$pid"; then
      rm -f "$PID_FILE"
      echo "[canary] stopped pid $pid"
      return 0
    fi
    sleep 0.1
  done
  if pid_uses_canary_executable "$pid"; then
    kill -KILL "$pid"
  fi
  rm -f "$PID_FILE"
  echo "[canary] force-stopped pid $pid"
}

build_canary() {
  local pid
  if pid="$(read_pid)" && pid_uses_canary_executable "$pid"; then
    echo "[canary] stop pid $pid before replacing $APP_PATH" >&2
    exit 1
  fi
  [ -x "$PACKAGE_SCRIPT" ] || {
    echo "[canary] package script is not executable: $PACKAGE_SCRIPT" >&2
    exit 1
  }

  local build_dir packaged_app packaged_executable
  build_dir="$CANARY_ROOT/build"
  packaged_app="$build_dir/$CANARY_NAME-package.app"
  packaged_executable="$packaged_app/Contents/MacOS/RemoteCode"
  rm -rf "$packaged_app"
  mkdir -p "$build_dir"

  (
    cd "$REPOSITORY_ROOT"
    RC2_BUNDLE_ID="$BUNDLE_ID" \
      RC2_CHANNEL=canary \
      RC2_CONFIG="${RC2_CANARY_CONFIG:-debug}" \
      RC2_PACKAGE_APP_OUTPUT="$packaged_app" \
      RC2_REPLACE_RUNNING_APP=0 \
      "$PACKAGE_SCRIPT"
  )

  [ -x "$packaged_executable" ] || {
    echo "[canary] packaged executable missing: $packaged_executable" >&2
    exit 1
  }
  mv "$packaged_executable" "$packaged_app/Contents/MacOS/$CANARY_NAME"
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName MacCode Agent Canary" "$packaged_app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName $CANARY_NAME" "$packaged_app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $CANARY_NAME" "$packaged_app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$packaged_app/Contents/Info.plist"
  /usr/bin/codesign --force --deep --sign - --timestamp=none "$packaged_app"
  /usr/bin/codesign --verify --deep --strict "$packaged_app"

  mkdir -p "$(dirname "$APP_PATH")"
  rm -rf "$APP_PATH"
  mv "$packaged_app" "$APP_PATH"
  echo "[canary] built $APP_PATH"
  echo "[canary] bundle-id $BUNDLE_ID; executable $EXECUTABLE"
}

run_canary() {
  [ -x "$EXECUTABLE" ] || {
    echo "[canary] app is not built; run '$0 build' first" >&2
    exit 1
  }
  local pid
  if pid="$(read_pid)" && pid_uses_canary_executable "$pid"; then
    echo "[canary] already running pid $pid: $EXECUTABLE"
    return 0
  fi

  mkdir -p "$APP_SUPPORT" "$RUN_DIR"
  rm -f "$PID_FILE"
  RC2_CHANNEL=canary \
    RC2_APP_SUPPORT="$APP_SUPPORT" \
    RC2_DB_PATH="$DB_PATH" \
    nohup "$EXECUTABLE" >> "$LOG_FILE" 2>&1 < /dev/null &
  pid=$!
  printf '%s\n' "$pid" > "$PID_FILE.tmp"
  mv "$PID_FILE.tmp" "$PID_FILE"
  for _ in {1..20}; do
    if pid_uses_canary_executable "$pid"; then
      echo "[canary] running pid $pid: $EXECUTABLE"
      echo "[canary] app-support $APP_SUPPORT; database $DB_PATH"
      return 0
    fi
    sleep 0.1
  done
  rm -f "$PID_FILE"
  echo "[canary] failed to start exact executable: $EXECUTABLE" >&2
  exit 1
}

status_canary() {
  local pid
  if pid="$(read_pid)" && pid_uses_canary_executable "$pid"; then
    echo "[canary] running pid $pid: $EXECUTABLE"
    echo "[canary] app-support $APP_SUPPORT; database $DB_PATH"
    return 0
  fi
  echo "[canary] not running: $EXECUTABLE"
  return 1
}

reset_canary_state() {
  stop_canary
  is_path_inside_canary "$APP_SUPPORT" || {
    echo "[canary] refusing state reset outside validated root: $APP_SUPPORT" >&2
    exit 2
  }
  [ "$APP_SUPPORT" != "$CANARY_ROOT" ] || {
    echo "[canary] refusing to delete canary root" >&2
    exit 2
  }
  rm -rf "$APP_SUPPORT"
  echo "[canary] reset state $APP_SUPPORT"
}

case "${1:-}" in
  build) build_canary ;;
  run) run_canary ;;
  stop) stop_canary ;;
  status) status_canary ;;
  reset-state) reset_canary_state ;;
  *)
    echo "usage: $0 build|run|stop|status|reset-state" >&2
    exit 2
    ;;
esac
