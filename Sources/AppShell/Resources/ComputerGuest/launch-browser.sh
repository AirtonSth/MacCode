#!/bin/bash
set -eu
# --no-sandbox is required inside this unprivileged guest only.
# Do not copy this flag onto the host Chromium.
# CDP stays on the guest loopback (port 9222 is never published) so the
# in-guest Playwright MCP drives this same visible browser and its logins.
exec chromium \
    --user-data-dir="${HOME}/.browser-profiles/chromium" \
    --no-first-run \
    --no-default-browser-check \
    --disable-gpu \
    --no-sandbox \
    --remote-debugging-port=9222 \
    --remote-debugging-address=127.0.0.1 \
    about:blank
