#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# XCTest framework lives inside the full Xcode bundle, not the CommandLineTools.
# We resolve a full Xcode developer dir so swift test can locate XCTest.
if [ -z "${DEVELOPER_DIR:-}" ]; then
  if [ -d "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks/XCTest.framework" ]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  fi
fi
# The suite uses process-global fake provider state; parallel XCTest runs race.
swift test
