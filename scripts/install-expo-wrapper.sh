#!/usr/bin/env bash
# Installs a wrapper over node_modules/.bin/expo at the workspace root so that
# any invocation of `expo` (npx expo, bunx expo, ./node_modules/.bin/expo) from
# ANY directory is automatically routed to mobile/ as the Expo project root.
#
# Called automatically by the postinstall hook after every `bun install`.

set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$WORKSPACE_ROOT/node_modules/.bin/expo"

cat > "$BIN" << 'WRAPPER'
#!/usr/bin/env node
/**
 * Expo CLI wrapper – always executes with mobile/ as the working directory
 * so the Expo project root is always mobile/, regardless of where the
 * command was invoked from.
 *
 * Installed by scripts/install-expo-wrapper.sh via postinstall.
 */
const path = require('path');

// __dirname is node_modules/.bin/ → two levels up is the workspace root
const mobileRoot = path.join(__dirname, '..', '..', 'mobile');

process.chdir(mobileRoot);
require('@expo/cli');
WRAPPER

chmod +x "$BIN"
echo "[expo-wrapper] installed → $BIN"
