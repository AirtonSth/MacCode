#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# .build caches absolute paths; if the project moved, the cache is stale.
# Wipe .build only when the recorded path differs from the current one.
STAMP=".build/.project-path"
CURRENT="$(pwd -P)"
if [ -d .build ] && { [ ! -f "$STAMP" ] || [ "$(cat "$STAMP")" != "$CURRENT" ]; }; then
    echo "Project path changed -> cleaning stale .build"
    rm -rf .build
fi
mkdir -p .build
printf '%s' "$CURRENT" > "$STAMP"

swift run -c debug RemoteCode2
