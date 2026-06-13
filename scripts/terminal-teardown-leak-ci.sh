#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

export RC2_TERMINAL_TEARDOWN_STRESS=1
export RC2_TERMINAL_TEARDOWN_ITERATIONS="${RC2_TERMINAL_TEARDOWN_ITERATIONS:-100}"
export RC2_TERMINAL_TEARDOWN_MAX_FD_GROWTH="${RC2_TERMINAL_TEARDOWN_MAX_FD_GROWTH:-8}"
export RC2_TERMINAL_TEARDOWN_MAX_FOOTPRINT_MB="${RC2_TERMINAL_TEARDOWN_MAX_FOOTPRINT_MB:-96}"

swift test --filter TerminalSurfaceTeardownLeakTests/test_createStreamCloseTerminalSurfacesKeepsFDsAndFootprintBounded
