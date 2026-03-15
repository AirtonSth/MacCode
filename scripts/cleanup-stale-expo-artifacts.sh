#!/usr/bin/env bash
# Removes artifacts that Expo CLI creates at the workspace root when accidentally
# run from there instead of from the mobile/ directory.
# Safe to run repeatedly; only removes files/dirs that should not exist at root.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

for artifact in ios android app.json index.js metro.config.js expo-env.d.ts .expo build; do
  if [ -e "$ROOT/$artifact" ]; then
    echo "[cleanup] Removing stale root artifact: $artifact"
    rm -rf "$ROOT/$artifact"
  fi
done
