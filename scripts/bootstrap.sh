#!/usr/bin/env bash
# Bootstrap: validate Xcode + Swift toolchain, resolve SwiftPM deps.
set -euo pipefail
cd "$(dirname "$0")/.."
echo "[bootstrap] swift version:" && swift --version | head -1
xcode-select -p >/dev/null
swift package resolve
echo "[bootstrap] ok"
