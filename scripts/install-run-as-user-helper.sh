#!/usr/bin/env bash
# Install RemoteCodeRunAsUserHelper as a setuid-root trampoline so Agent App can
# execute provider CLIs as another macOS user through the shared helper.
#
# Usage:
#   sudo scripts/install-run-as-user-helper.sh [/path/to/RemoteCode.app]
#
# Security notes:
# - Helper drops to the target uid/gid before exec.
# - Only allowlisted basenames (codex, claude, grok, node, npm) are accepted.
# - Re-run after every helper binary change.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "must run as root (sudo)" >&2
  exit 1
fi

APP_PATH="${1:-dist/RemoteCode.app}"
SRC="$APP_PATH/Contents/MacOS/RemoteCodeRunAsUserHelper"
if [ ! -x "$SRC" ]; then
  # Fall back to SwiftPM build product
  BIN_DIR="$(swift build -c release --show-bin-path 2>/dev/null || true)"
  if [ -n "$BIN_DIR" ] && [ -x "$BIN_DIR/RemoteCodeRunAsUserHelper" ]; then
    SRC="$BIN_DIR/RemoteCodeRunAsUserHelper"
  fi
fi
if [ ! -x "$SRC" ]; then
  echo "missing helper binary at $SRC — package the app first" >&2
  exit 1
fi

DEST_DIR="/Library/PrivilegedHelperTools"
DEST="$DEST_DIR/io.remotecode.RunAsUserHelper"
mkdir -p "$DEST_DIR"
cp "$SRC" "$DEST"
chown root:wheel "$DEST"
chmod 4755 "$DEST"
echo "installed setuid helper: $DEST"
echo "mode: $(stat -f '%Sp %Su:%Sg' "$DEST")"
"$DEST" version || true
