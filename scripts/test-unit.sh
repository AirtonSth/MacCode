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

# QA-MAC :69 -- RC2_COVERAGE=1 enables LLVM source-based coverage + a text report
# so the team can see coverage for low-coverage targets (DesignSystemKit, RC2CLI)
# that is otherwise invisible. Off by default so local iterative runs stay fast.
if [ "${RC2_COVERAGE:-0}" = "1" ]; then
  swift test --enable-code-coverage
  BIN="$(swift build --show-bin-path)"
  PROFDATA="$BIN/codecov/default.profdata"
  # The test bundle's executable holds the instrumented symbols llvm-cov needs.
  XCTEST="$(find "$BIN" -maxdepth 1 -name '*.xctest' | head -1)"
  if [ -z "$XCTEST" ] || [ ! -f "$PROFDATA" ]; then
    echo "coverage: could not locate test bundle ($XCTEST) or profdata ($PROFDATA)" >&2
    exit 1
  fi
  EXE="$XCTEST/Contents/MacOS/$(basename "$XCTEST" .xctest)"
  REPORT="$BIN/coverage-report.txt"
  # Exclude test sources + checkout deps so the report reflects product code.
  xcrun llvm-cov report "$EXE" \
    -instr-profile "$PROFDATA" \
    -ignore-filename-regex='(Tests/|\.build/|checkouts/)' \
    | tee "$REPORT"
  echo "coverage: report written to $REPORT"
else
  swift test
fi
