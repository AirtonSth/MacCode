#!/usr/bin/env bash
# Exercise the actual image without a home bind (which can hide bad ownership).
set -euo pipefail
image="${1:?usage: scripts/test-computer-guest-image.sh IMAGE}"
probe="maccode-image-probe-$(uuidgen | tr '[:upper:]' '[:lower:]')"
frame="$(mktemp)"
created=0
cleanup() {
  rm -f "$frame"
  if [ "$created" = 1 ]; then docker rm -f "$probe" >/dev/null; fi
}
trap cleanup EXIT
docker create --name "$probe" --init --shm-size 256m \
  -e REMOTECODE_VIEWER_TOKEN=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  "$image" >/dev/null
created=1
docker start "$probe" >/dev/null
for attempt in $(seq 1 60); do
  if [ "$(docker inspect -f '{{.State.Running}}' "$probe")" != true ]; then
    docker logs --tail 40 "$probe" >&2
    echo 'FAIL: guest image exited before the desktop was ready' >&2
    exit 1
  fi
  if docker exec "$probe" timeout 5 env DISPLAY=:1 import -window root png:- >"$frame" 2>/dev/null \
    && [ "$(od -An -tx1 -N8 "$frame" | tr -d ' \n')" = 89504e470d0a1a0a ] \
    && docker exec "$probe" curl --max-time 2 -fsS http://127.0.0.1:6080/vnc.html >/dev/null 2>&1; then
    echo "PASS: guest image produced a PNG and served noVNC (attempt $attempt)"
    exit 0
  fi
  sleep 0.5
done
docker logs --tail 40 "$probe" >&2
echo 'FAIL: desktop did not become ready' >&2
exit 1
