#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="RemoteCode"
APP_BUNDLE="dist/${APP_NAME}.app"

has_onscreen_window() {
  swift - "$APP_NAME" <<'SWIFT'
import CoreGraphics
import Foundation

let ownerName = CommandLine.arguments[1]
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    as? [[String: Any]] ?? []

let found = windows.contains { window in
    guard (window[kCGWindowOwnerName as String] as? String) == ownerName,
          (window[kCGWindowLayer as String] as? Int) == 0,
          (window[kCGWindowAlpha as String] as? Double ?? 0) > 0,
          let bounds = window[kCGWindowBounds as String] as? [String: Any],
          (bounds["Width"] as? Double ?? 0) > 0,
          (bounds["Height"] as? Double ?? 0) > 0 else {
        return false
    }
    return true
}

exit(found ? 0 : 1)
SWIFT
}

pkill -x "$APP_NAME" 2>/dev/null || true
RC2_REPLACE_RUNNING_APP=1 RC2_CONFIG=debug ./scripts/package-app.sh
/usr/bin/open -n "$APP_BUNDLE"

if [[ "${1:-}" == "--verify" ]]; then
  for _ in {1..20}; do
    if pgrep -x "$APP_NAME" >/dev/null && has_onscreen_window; then
      echo "[run] ${APP_NAME} is running with an onscreen window"
      exit 0
    fi
    sleep 0.25
  done
  echo "[run] ${APP_NAME} did not start with an onscreen window" >&2
  exit 1
fi
