#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PATCH_FILE="$ROOT_DIR/patches/expo-widgets-live-activity.patch"
TARGET_FILE="$ROOT_DIR/node_modules/expo-widgets/build/Widgets.js"

if [ ! -f "$TARGET_FILE" ] || [ ! -f "$PATCH_FILE" ]; then
  exit 0
fi

if rg -Fq 'Returns the native ActivityKit identifier for this Live Activity instance.' "$TARGET_FILE"; then
  exit 0
fi

git -C "$ROOT_DIR" apply --whitespace=nowarn "$PATCH_FILE"
