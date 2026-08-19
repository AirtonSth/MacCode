#!/bin/bash
set -eu
export DISPLAY="${DISPLAY:-:1}"
export HOME="${HOME:-/home/remotecode}"
mkdir -p "$HOME/.browser-profiles/chromium" /tmp/fluxbox
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

# Guest VNC stays loopback. Docker NAT publishes 6080 on 127.0.0.1 of the host.
x11vnc -display :1 -rfbport 5900 -localhost -forever -shared -nopw \
    >/tmp/x11vnc.log 2>&1 &

websockify --web /usr/share/novnc 0.0.0.0:6080 127.0.0.1:5900 \
    >/tmp/websockify.log 2>&1 &

wait -n
exit 1
