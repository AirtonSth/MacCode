#!/usr/bin/env bash
# Package the SwiftPM-built executable as a minimal local .app bundle.
# This is not a release artifact. Release DMGs must be Developer ID signed
# and notarized by scripts/package-dmg.sh plus the GitHub release workflow.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${RC2_CONFIG:-release}"
DIST="dist"
BUNDLE="RemoteCode.app"
BUNDLE_ID="${RC2_BUNDLE_ID:-io.remotecode.desktop}"
VERSION="${RC2_VERSION:-0.1.0}"
SPARKLE_FEED_URL="${RC2_SPARKLE_FEED_URL:-https://github.com/samuelfaj/remotecode.io/releases/latest/download/appcast.xml}"
SPARKLE_PUBLIC_ED_KEY="${RC2_SPARKLE_PUBLIC_ED_KEY:-}"

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi
if [ "${RC2_REQUIRE_SPARKLE_KEY:-0}" = "1" ] && [ -z "$SPARKLE_PUBLIC_ED_KEY" ]; then
  echo "[package] RC2_SPARKLE_PUBLIC_ED_KEY is required for release packaging" >&2
  exit 1
fi

echo "[package] building $CONFIG …"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

BIN="$BIN_DIR/RemoteCode"
CLI="$BIN_DIR/rc2"
SURFACES_RESOURCES="$BIN_DIR/RemoteCode_Surfaces.bundle"
if [ ! -x "$BIN" ]; then echo "missing $BIN"; exit 1; fi

rm -rf "$DIST/$BUNDLE"
mkdir -p "$DIST/$BUNDLE/Contents/MacOS"
mkdir -p "$DIST/$BUNDLE/Contents/Resources"
mkdir -p "$DIST/$BUNDLE/Contents/Frameworks"

cp "$BIN" "$DIST/$BUNDLE/Contents/MacOS/RemoteCode"
if [ -x "$CLI" ]; then
  cp "$CLI" "$DIST/$BUNDLE/Contents/MacOS/rc2"
fi
if [ -d "$SURFACES_RESOURCES" ]; then
  cp -R "$SURFACES_RESOURCES" "$DIST/$BUNDLE/Contents/Resources/RemoteCode_Surfaces.bundle"
fi
if [ -f "Resources/AppIcon.icns" ]; then
  cp "Resources/AppIcon.icns" "$DIST/$BUNDLE/Contents/Resources/AppIcon.icns"
fi
SPARKLE_FRAMEWORK="$(find "$BIN_DIR" -maxdepth 2 -name Sparkle.framework -type d | head -n 1 || true)"
if [ -n "$SPARKLE_FRAMEWORK" ]; then
  cp -R "$SPARKLE_FRAMEWORK" "$DIST/$BUNDLE/Contents/Frameworks/Sparkle.framework"
  if ! otool -l "$DIST/$BUNDLE/Contents/MacOS/RemoteCode" | grep -F "@executable_path/../Frameworks" >/dev/null; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$DIST/$BUNDLE/Contents/MacOS/RemoteCode"
  fi
fi

cat > "$DIST/$BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key><string>RemoteCode</string>
  <key>CFBundleExecutable</key><string>RemoteCode</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleName</key><string>RemoteCode</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>SUFeedURL</key><string>${SPARKLE_FEED_URL}</string>
  <key>SUPublicEDKey</key><string>${SPARKLE_PUBLIC_ED_KEY}</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUAutomaticallyUpdate</key><true/>
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

codesign --force --deep --sign - "$DIST/$BUNDLE"

echo "[package] bundle ready at $DIST/$BUNDLE"
echo "[package] launch: open '$DIST/$BUNDLE'  or  $DIST/$BUNDLE/Contents/MacOS/RemoteCode"
echo "[package] release DMGs require Developer ID signing and notarization"
