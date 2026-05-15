#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c debug
echo "[build-debug] artifacts in .build/debug"
