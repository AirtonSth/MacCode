#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="RemoteCode"
APP_BUNDLE="dist/${APP_NAME}.app"

pkill -x "$APP_NAME" 2>/dev/null || true
RC2_CONFIG=debug ./scripts/package-app.sh
/usr/bin/open -n "$APP_BUNDLE"

if [[ "${1:-}" == "--verify" ]]; then
  for _ in {1..20}; do
    if pgrep -x "$APP_NAME" >/dev/null; then
      echo "[run] ${APP_NAME} is running"
      exit 0
    fi
    sleep 0.25
  done
  echo "[run] ${APP_NAME} did not start" >&2
  exit 1
fi
