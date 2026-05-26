#!/usr/bin/env bash
# Build RemoteCode.app and wrap it in a Developer ID-signed DMG.
# This script must fail if a Developer ID Application identity is unavailable.
set -euo pipefail
cd "$(dirname "$0")/.."

ASSET_NAME="${RC2_DMG_NAME:-stable-macos-arm64-RemoteCode.dmg}"
DIST="dist"
APP_NAME="RemoteCode.app"
DMG_ROOT="$DIST/dmg-root"
DMG_BUILD_ROOT="$DIST/dmg-build"
DMG_BUILD_APP="$DMG_BUILD_ROOT/$APP_NAME"
OUTPUT="$DIST/$ASSET_NAME"
SIGN_IDENTITY="${RC2_CODESIGN_IDENTITY:-}"
BACKGROUND_DIR="$DMG_ROOT/background"
BACKGROUND_IMAGE="$BACKGROUND_DIR/background.png"
RW_DMG="$DIST/RemoteCode-rw.dmg"

if [[ "$SIGN_IDENTITY" != Developer\ ID\ Application:* ]]; then
  echo "[package] RC2_CODESIGN_IDENTITY must be a Developer ID Application identity" >&2
  exit 1
fi

rm -rf "$DMG_BUILD_ROOT"
RC2_PACKAGE_APP_OUTPUT="$DMG_BUILD_APP" "$(dirname "$0")/package-app.sh"

rm -rf "$DMG_ROOT" "$OUTPUT"
mkdir -p "$DMG_ROOT"
mkdir -p "$BACKGROUND_DIR"

cp -R "$DMG_BUILD_APP" "$DMG_ROOT/$APP_NAME"
ln -s /Applications "$DMG_ROOT/Applications"
"$(dirname "$0")/generate-dmg-background.swift" "$BACKGROUND_IMAGE"
chflags hidden "$BACKGROUND_DIR" 2>/dev/null || true

codesign --force --deep --sign "$SIGN_IDENTITY" --options runtime "$DMG_ROOT/$APP_NAME"
codesign --verify --deep --strict --verbose=4 "$DMG_ROOT/$APP_NAME"

hdiutil create \
  -volname "RemoteCode" \
  -srcfolder "$DMG_ROOT" \
  -ov \
  -format UDRW \
  -fs HFS+ \
  "$RW_DMG"

MOUNT_DIR=""
cleanup_mount() {
  if [[ -n "$MOUNT_DIR" ]]; then
    hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
  fi
}
trap cleanup_mount EXIT

ATTACH_OUTPUT="$(hdiutil attach -readwrite -noverify "$RW_DMG")"
MOUNT_DIR="$(printf '%s\n' "$ATTACH_OUTPUT" | awk '/Apple_HFS/ { print $NF; exit }')"
if [[ -z "$MOUNT_DIR" || ! -d "$MOUNT_DIR" ]]; then
  echo "[package] unable to find mounted DMG path" >&2
  printf '%s\n' "$ATTACH_OUTPUT" >&2
  exit 1
fi

osascript <<OSA
tell application "Finder"
  tell disk "RemoteCode"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set sidebar width of container window to 0
    set bounds of container window to {120, 120, 920, 600}
    set theViewOptions to icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 128
    set background picture of theViewOptions to file "background:background.png"
    set position of item "RemoteCode.app" of container window to {220, 240}
    set position of item "Applications" of container window to {580, 240}
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA

sync
hdiutil detach "$MOUNT_DIR"
trap - EXIT

hdiutil convert "$RW_DMG" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$OUTPUT"

codesign --force --sign "$SIGN_IDENTITY" "$OUTPUT"
codesign --verify --verbose=4 "$OUTPUT"

rm -rf "$DMG_ROOT" "$DMG_BUILD_ROOT" "$RW_DMG"

echo "[package] dmg ready at $OUTPUT"
