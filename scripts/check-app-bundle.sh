#!/usr/bin/env bash
# QA-mac:71 -- structural validation of a packaged RemoteCode.app bundle (T026).
#
# WHY: package-app.sh runs `codesign --verify` only when a human packages locally,
# so a malformed bundle (9-byte PkgInfo, missing executable, invalid Info.plist,
# CFBundleExecutable not matching the binary) can ship from CI unnoticed. This
# asserts the structural invariants that must hold for the bundle to launch and be
# discoverable, independent of codesigning.
#
# Usage: check-app-bundle.sh /path/to/RemoteCode.app
# Exit 0 = all structural checks pass; exit 1 = at least one failed.
set -euo pipefail

APP="${1:-}"
if [ -z "$APP" ] || [ ! -d "$APP" ]; then
  echo "FAIL: app bundle path missing or not a directory: '$APP'" >&2
  exit 1
fi

PLIST="$APP/Contents/Info.plist"
PKGINFO="$APP/Contents/PkgInfo"
fails=0
note() { echo "  - $1"; }
fail() { echo "FAIL: $1" >&2; fails=$((fails + 1)); }

# 1. Info.plist exists and is valid.
if [ ! -f "$PLIST" ]; then
  fail "missing Info.plist at $PLIST"
elif ! plutil -lint "$PLIST" >/dev/null; then
  fail "Info.plist failed plutil -lint"
else
  note "Info.plist present and lint-clean"
fi

# Helper: read a top-level Info.plist string key (empty if absent).
plist_get() { plutil -extract "$1" raw -o - "$PLIST" 2>/dev/null || true; }

# 2. Package type must be APPL.
PKGTYPE="$(plist_get CFBundlePackageType)"
[ "$PKGTYPE" = "APPL" ] && note "CFBundlePackageType=APPL" || fail "CFBundlePackageType must be APPL (got '$PKGTYPE')"

# 3. CFBundleExecutable must name a real Mach-O executable under Contents/MacOS.
EXEC_NAME="$(plist_get CFBundleExecutable)"
if [ -z "$EXEC_NAME" ]; then
  fail "CFBundleExecutable is empty"
else
  EXEC_PATH="$APP/Contents/MacOS/$EXEC_NAME"
  if [ ! -f "$EXEC_PATH" ]; then
    fail "CFBundleExecutable '$EXEC_NAME' has no file at $EXEC_PATH"
  elif ! file "$EXEC_PATH" | grep -q "Mach-O"; then
    fail "executable '$EXEC_NAME' is not a Mach-O binary"
  elif [ ! -x "$EXEC_PATH" ]; then
    fail "executable '$EXEC_NAME' is not marked executable"
  else
    note "CFBundleExecutable '$EXEC_NAME' is an executable Mach-O binary"
  fi
fi

# 4. Identifier and version must be non-empty (version drives the Bonjour TXT field).
[ -n "$(plist_get CFBundleIdentifier)" ] && note "CFBundleIdentifier present" || fail "CFBundleIdentifier is empty"
[ -n "$(plist_get CFBundleShortVersionString)" ] && note "CFBundleShortVersionString present" || fail "CFBundleShortVersionString is empty"

# 5. PkgInfo must be EXACTLY the 8 bytes "APPL????" (the QA-mac:70 bug class: a
#    heredoc trailing newline made it 9 bytes, which some validators reject).
if [ ! -f "$PKGINFO" ]; then
  fail "missing PkgInfo"
else
  SIZE="$(wc -c < "$PKGINFO" | tr -d ' ')"
  CONTENT="$(cat "$PKGINFO")"
  if [ "$SIZE" != "8" ]; then
    fail "PkgInfo must be exactly 8 bytes (got $SIZE -- a trailing newline is the classic regression)"
  elif [ "$CONTENT" != "APPL????" ]; then
    fail "PkgInfo content must be 'APPL????' (got '$CONTENT')"
  else
    note "PkgInfo is exactly 8 bytes 'APPL????'"
  fi
fi

if [ "$fails" -ne 0 ]; then
  echo "FAIL: $fails structural check(s) failed for $APP" >&2
  exit 1
fi
echo "OK: $APP passed all structural checks"
