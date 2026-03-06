#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PATCH_FILE="$ROOT_DIR/patches/expo-ui-text-timer.patch"
TARGET_FILE="$ROOT_DIR/node_modules/@expo/ui/ios/TextView.swift"

if [ ! -f "$TARGET_FILE" ] || [ ! -f "$PATCH_FILE" ]; then
  exit 0
fi

if git -C "$ROOT_DIR" apply --reverse --check "$PATCH_FILE" >/dev/null 2>&1; then
  exit 0
fi

git -C "$ROOT_DIR" apply --whitespace=nowarn "$PATCH_FILE"
