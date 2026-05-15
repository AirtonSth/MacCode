#!/usr/bin/env bash
# Package the SwiftPM-built executable as a minimal .app bundle.
# Does NOT sign, notarize, or staple — those steps require an Apple
# Developer ID. Produces RemoteCode2.app under ./dist/.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${RC2_CONFIG:-release}"
DIST="dist"
BUNDLE="RemoteCode2.app"
BUNDLE_ID="${RC2_BUNDLE_ID:-io.remotecode.RemoteCode2.debug}"
VERSION="${RC2_VERSION:-0.1.0}"

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

echo "[package] building $CONFIG …"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/RemoteCode2"
CLI=".build/$CONFIG/rc2"
if [ ! -x "$BIN" ]; then echo "missing $BIN"; exit 1; fi

rm -rf "$DIST/$BUNDLE"
mkdir -p "$DIST/$BUNDLE/Contents/MacOS"
mkdir -p "$DIST/$BUNDLE/Contents/Resources"

cp "$BIN" "$DIST/$BUNDLE/Contents/MacOS/RemoteCode2"
if [ -x "$CLI" ]; then
  cp "$CLI" "$DIST/$BUNDLE/Contents/MacOS/rc2"
fi

cat > "$DIST/$BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key><string>RemoteCode 2</string>
  <key>CFBundleExecutable</key><string>RemoteCode2</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleName</key><string>RemoteCode2</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><false/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSSupportsSuddenTermination</key><false/>
</dict>
</plist>
EOF

cat > "$DIST/$BUNDLE/Contents/PkgInfo" <<EOF
APPL????
EOF

echo "[package] bundle ready at $DIST/$BUNDLE"
echo "[package] launch: open '$DIST/$BUNDLE'  or  $DIST/$BUNDLE/Contents/MacOS/RemoteCode2"
echo "[package] sign + notarize is NOT performed; requires Apple Developer ID"
