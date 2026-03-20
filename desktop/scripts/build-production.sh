#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────
# RemoteCode Desktop — Production Build Script
# ──────────────────────────────────────────────
# Usage:
#   ./scripts/build-production.sh                 # build for current platform
#   ./scripts/build-production.sh macos            # macOS (arm64 + x64)
#   ./scripts/build-production.sh linux            # Linux (x64 + arm64)
#   ./scripts/build-production.sh windows          # Windows (x64)
#   ./scripts/build-production.sh all              # all platforms
#   ./scripts/build-production.sh macos-arm64      # specific target
#
# Environment variables:
#   APP_VERSION                — override version (default: from electrobun.config.ts)
#   BUILD_ENV                  — electrobun env: stable | canary (default: stable)
#   CODESIGN                   — set to "true" to enable macOS code signing
#   NOTARIZE                   — set to "true" to enable macOS notarization
#
# macOS code signing requires (add to ~/.zshrc):
#   ELECTROBUN_DEVELOPER_ID    — Apple Developer ID, ex: "My Corp Inc. (BGU899NB8T)"
#   ELECTROBUN_TEAMID          — Apple Team ID, ex: "BGU899NB8T"
#   ELECTROBUN_APPLEID         — Apple ID email, ex: "dev@example.com"
#   ELECTROBUN_APPLEIDPASS     — App-specific password (generate at appleid.apple.com)
#
# Also enable in electrobun.config.ts > build.mac:
#   codesign: true
#   notarize: true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_DIR"

# ── Defaults ──
BUILD_ENV="${BUILD_ENV:-stable}"
TARGET="${1:-current}"

# ── Resolve targets ──
case "$TARGET" in
  macos|mac)
    TARGETS="macos-arm64,macos-x64"
    ;;
  linux)
    TARGETS="linux-x64,linux-arm64"
    ;;
  windows|win)
    TARGETS="win-x64"
    ;;
  all)
    TARGETS="all"
    ;;
  current)
    TARGETS="current"
    ;;
  *)
    # Allow passing raw targets like "macos-arm64" or "linux-x64,win-x64"
    TARGETS="$TARGET"
    ;;
esac

# ── Version ──
# electrobun.config.ts reads APP_VERSION env var, falling back to package.json version.
if [ -n "${APP_VERSION:-}" ]; then
  echo "→ Version override: $APP_VERSION"
  export APP_VERSION
else
  APP_VERSION=$(bun -e "console.log(require('./package.json').version)")
  echo "→ Version from package.json: $APP_VERSION"
  export APP_VERSION
fi

# ── Code signing config ──
SIGN_FLAGS=""
if [ "${CODESIGN:-}" = "true" ]; then
  echo "→ Code signing enabled"
  # Verify required env vars
  for var in ELECTROBUN_DEVELOPER_ID ELECTROBUN_TEAMID ELECTROBUN_APPLEID ELECTROBUN_APPLEIDPASS; do
    if [ -z "${!var:-}" ]; then
      echo "ERROR: $var is required for code signing" >&2
      exit 1
    fi
  done
fi

if [ "${NOTARIZE:-}" = "true" ]; then
  echo "→ Notarization enabled"
fi

echo "──────────────────────────────────────"
echo "  RemoteCode Desktop — Production Build"
echo "──────────────────────────────────────"
echo "  Environment : $BUILD_ENV"
echo "  Targets     : $TARGETS"
echo "──────────────────────────────────────"
echo ""

# ── Step 1: Install dependencies ──
echo "→ Installing dependencies..."
bun install 2>/dev/null || bun install

# ── Step 2: Type check ──
echo "→ Running type check..."
bun run tsc --noEmit || {
  echo "WARNING: Type errors found (continuing build)" >&2
}

# ── Step 3: Build frontend (Vite) ──
echo "→ Building frontend with Vite..."
bun run build:vite

# ── Step 4: Build with Electrobun ──
echo "→ Building Electrobun app..."
if [ "$TARGETS" = "current" ]; then
  npx electrobun build --env="$BUILD_ENV"
else
  npx electrobun build --env="$BUILD_ENV" --targets="$TARGETS"
fi

echo ""
echo "──────────────────────────────────────"
echo "  Build complete!"
echo "──────────────────────────────────────"

# ── Show output ──
echo ""
echo "Build artifacts:"
if [ -d "artifacts" ]; then
  ls -lh artifacts/ | sed 's/^/  /'
elif [ -d "build" ]; then
  find build -maxdepth 2 -type d | grep -v "^build$" | sed 's/^/  /'
fi
