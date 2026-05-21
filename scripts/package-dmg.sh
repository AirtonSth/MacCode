#!/usr/bin/env bash
# Build RemoteCode.app and wrap it in a distributable DMG.
# Signing, notarization, and stapling are intentionally separate release steps.
set -euo pipefail
cd "$(dirname "$0")/.."

ASSET_NAME="${RC2_DMG_NAME:-stable-macos-arm64-RemoteCode.dmg}"
DIST="dist"
APP_NAME="RemoteCode.app"
DMG_ROOT="$DIST/dmg-root"
OUTPUT="$DIST/$ASSET_NAME"
SIGN_IDENTITY="${RC2_CODESIGN_IDENTITY:-}"

if [[ "$SIGN_IDENTITY" != Developer\ ID\ Application:* ]]; then
  echo "[package] RC2_CODESIGN_IDENTITY must be a Developer ID Application identity" >&2
  exit 1
fi

"$(dirname "$0")/package-app.sh"

rm -rf "$DMG_ROOT" "$OUTPUT"
mkdir -p "$DMG_ROOT"

cp -R "$DIST/$APP_NAME" "$DMG_ROOT/$APP_NAME"
ln -s /Applications "$DMG_ROOT/Applications"

codesign --force --deep --sign "$SIGN_IDENTITY" --options runtime "$DMG_ROOT/$APP_NAME"
codesign --verify --deep --strict --verbose=4 "$DMG_ROOT/$APP_NAME"

hdiutil create \
  -volname "RemoteCode" \
  -srcfolder "$DMG_ROOT" \
  -ov \
  -format UDZO \
  "$OUTPUT"

codesign --force --sign "$SIGN_IDENTITY" "$OUTPUT"
codesign --verify --verbose=4 "$OUTPUT"

rm -rf "$DMG_ROOT"

echo "[package] dmg ready at $OUTPUT"
