#!/bin/bash
set -eu
# --no-sandbox is required inside this unprivileged guest only.
# Do not copy this flag onto the host Chromium.
exec chromium \
    --user-data-dir="${HOME}/.browser-profiles/chromium" \
    --no-first-run \
    --no-default-browser-check \
    --disable-gpu \
    --no-sandbox \
    about:blank
