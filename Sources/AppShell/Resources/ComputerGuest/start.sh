#!/bin/bash
set -eu
export DISPLAY="${DISPLAY:-:1}"
export HOME="${HOME:-/home/remotecode}"
: "${REMOTECODE_VIEWER_TOKEN:?RemoteCode viewer token is required}"
mkdir -p "$HOME/.browser-profiles/chromium" /tmp/fluxbox
# The profile lives on the persisted home bind. A recreated container has a new
# hostname, so Chromium reads the previous container's lock as "in use on another
# computer" and never opens. Removing the lock is safe only because no other
# container runs on this home: rebuild and workspace remounts stop the old
# container before the new one starts.
rm -f "$HOME/.browser-profiles/chromium/SingletonLock" \
    "$HOME/.browser-profiles/chromium/SingletonSocket" \
    "$HOME/.browser-profiles/chromium/SingletonCookie"
rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 || true

Xvfb :1 -screen 0 1280x800x24 -ac +extension RANDR >/tmp/xvfb.log 2>&1 &
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if xdpyinfo -display :1 >/dev/null 2>&1; then
        break
    fi
    sleep 0.2
done
xdpyinfo -display :1 >/dev/null

fluxbox -display :1 -log /tmp/fluxbox.log >/tmp/fluxbox.out 2>&1 &
/opt/remotecode-computer/launch-browser.sh || xterm -display :1 &

# Guest VNC stays loopback. The WebSocket proxy admits only the per-Bot token;
# Docker NAT additionally publishes 6080 on 127.0.0.1 of the host.
x11vnc -display :1 -rfbport 5900 -localhost -forever -shared -nopw \
    >/tmp/x11vnc.log 2>&1 &

printf '%s: 127.0.0.1:5900\n' "$REMOTECODE_VIEWER_TOKEN" > /tmp/remotecode-viewer-tokens
chmod 0600 /tmp/remotecode-viewer-tokens
websockify --web /usr/share/novnc \
    --token-plugin TokenFile \
    --token-source /tmp/remotecode-viewer-tokens \
    0.0.0.0:6080 \
    >/tmp/websockify.log 2>&1 &

wait -n
exit 1
