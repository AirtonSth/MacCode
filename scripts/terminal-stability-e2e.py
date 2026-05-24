#!/usr/bin/env python3
import base64
import hashlib
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
APP_NAME = "RemoteCode"
PORT = int(os.environ.get("RC2_E2E_PORT", "18217"))
BASE = f"http://127.0.0.1:{PORT}"
RUN_SECONDS = int(os.environ.get("RC2_E2E_DURATION_SECONDS", "120"))
LINES = int(os.environ.get("RC2_E2E_LINES", "4000"))
HIDDEN_LINES = int(os.environ.get("RC2_E2E_HIDDEN_LINES", "22000"))
LARGE_INPUT_BYTES = int(os.environ.get("RC2_E2E_LARGE_INPUT_BYTES", str(256 * 1024)))
TUI_SECONDS = int(os.environ.get("RC2_E2E_TUI_SECONDS", "10"))
MAX_RSS_KB = int(os.environ.get("RC2_E2E_MAX_RSS_KB", "900000"))
REQUIRE_SLOW_WS = os.environ.get("RC2_E2E_REQUIRE_SLOW_WS", "0") == "1"


class Failure(RuntimeError):
    pass


def run(cmd, **kwargs):
    return subprocess.run(cmd, check=True, text=True, **kwargs)


def rpc(method, params=None):
    body = json.dumps({
        "jsonrpc": "2.0",
        "id": "1",
        "method": method,
        "params": params or {},
    }).encode()
    req = urllib.request.Request(
        f"{BASE}/v1/rpc",
        data=body,
        headers={"content-type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=20) as response:
        raw = response.read()
    payload = json.loads(raw)
    if payload.get("error"):
        raise Failure(f"rpc {method} failed: {payload['error']}")
    return payload.get("result")


def wait_for_host():
    deadline = time.time() + 30
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(f"{BASE}/healthz", timeout=1):
                return
        except Exception:
            time.sleep(0.25)
    raise Failure("host did not become healthy")


def pkill_app():
    subprocess.run(["pkill", "-x", APP_NAME], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def app_pid():
    result = subprocess.run(["pgrep", "-x", APP_NAME], text=True, capture_output=True)
    if result.returncode != 0:
        return None
    first = result.stdout.strip().splitlines()
    return int(first[0]) if first else None


def sample(pid, stats):
    result = subprocess.run(["ps", "-o", "rss=,%cpu=", "-p", str(pid)], text=True, capture_output=True)
    if result.returncode != 0 or not result.stdout.strip():
        raise Failure("app process disappeared")
    parts = result.stdout.strip().split()
    rss = int(float(parts[0]))
    cpu = float(parts[1]) if len(parts) > 1 else 0.0
    stats["max_rss_kb"] = max(stats["max_rss_kb"], rss)
    stats["max_cpu_percent"] = max(stats["max_cpu_percent"], cpu)
    if rss > MAX_RSS_KB:
        raise Failure(f"rss exceeded cap: {rss} > {MAX_RSS_KB}")


def workspace_surface(created):
    pane = created["layout"]["pane"]["_0"]
    surface = pane["surfaces"][0]
    return created["id"]["value"], surface["id"]["value"]


def snapshot(surface_id):
    return rpc("surface.read_text", {"id": surface_id, "include_metadata": True})


def text_of(value):
    if isinstance(value, str):
        return value
    return value.get("text", "")


def wait_snapshot_contains(surface_id, needle, timeout=20):
    deadline = time.time() + timeout
    last = ""
    while time.time() < deadline:
        snap = snapshot(surface_id)
        last = text_of(snap)
        if needle in last:
            return snap
        time.sleep(0.5)
    raise Failure(f"snapshot missing {needle!r}; last tail={last[-400:]!r}")


def send_text(surface_id, text):
    result = rpc("surface.send_text", {"id": surface_id, "text": text})
    if isinstance(result, dict) and result.get("accepted") is False:
        return result
    return result or {"accepted": True, "status": "accepted"}


def assert_alive(surface_id):
    health = rpc("surface.health", {"id": surface_id})
    if not health.get("alive"):
        raise Failure(f"expected alive terminal, got {health}")
    if health.get("input_accepting") is False:
        raise Failure(f"expected input accepting terminal, got {health}")
    return health


def open_slow_ws():
    key = base64.b64encode(os.urandom(16)).decode()
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024)
    sock.settimeout(10)
    sock.connect(("127.0.0.1", PORT))
    request = (
        "GET /v1/ws HTTP/1.1\r\n"
        "Host: 127.0.0.1\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        "\r\n"
    ).encode()
    sock.sendall(request)
    response = sock.recv(4096)
    accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest())
    if b"101 Switching Protocols" not in response or accept not in response:
        raise Failure(f"websocket handshake failed: {response[:200]!r}")
    return sock


def recent(max_bytes=512):
    return rpc("events.recent", {"since_seq": 0, "max_bytes": max_bytes})


def main():
    start = time.time()
    app_support = Path(tempfile.mkdtemp(prefix="rc2-e2e."))
    stats = {
        "status": "PASS",
        "duration_seconds": 0,
        "configured_run_seconds": RUN_SECONDS,
        "max_rss_kb": 0,
        "max_cpu_percent": 0.0,
        "disconnect_count": 0,
        "dropped_event_count": 0,
        "slow_ws_disconnect_seen": False,
        "baseline_required_seen": False,
        "hidden_partial_seen": False,
        "large_input_bytes": LARGE_INPUT_BYTES,
        "tui_seconds": TUI_SECONDS,
        "child_exit_dead_seen": False,
        "app_alive_after_child_exit": False,
    }
    slow_sock = None
    try:
        pkill_app()
        run(["./scripts/package-app.sh"], cwd=ROOT, stdout=subprocess.DEVNULL)
        env = os.environ.copy()
        env["RC2_APP_SUPPORT"] = str(app_support)
        env["RC2_DB_PATH"] = str(app_support / "RemoteCode.sqlite")
        subprocess.run(["/usr/bin/open", "-n", str(ROOT / "dist" / f"{APP_NAME}.app")], check=True, env=env)
        wait_for_host()
        pid = app_pid()
        if pid is None:
            raise Failure("app process missing after launch")
        sample(pid, stats)

        primary = rpc("workspace.create", {"name": "E2EPrimary", "cwd": "/tmp"})
        primary_wid, primary_sid = workspace_surface(primary)
        hidden = rpc("workspace.create", {"name": "E2EHidden", "cwd": "/tmp"})
        hidden_wid, hidden_sid = workspace_surface(hidden)
        rpc("workspace.select", {"id": primary_wid})

        slow_sock = open_slow_ws()

        send_text(primary_sid, (
            "python3 - <<'PY'\n"
            "import time\n"
            f"end=time.time()+{RUN_SECONDS}\n"
            "i=0\n"
            "while time.time()<end:\n"
            "    print(f'RC2_E2E_STREAM_{i:06d}', flush=True)\n"
            "    i+=1\n"
            "    time.sleep(0.01)\n"
            "print('RC2_E2E_STREAM_DONE', flush=True)\n"
            "PY\n"
        ))
        for _ in range(max(1, RUN_SECONDS)):
            time.sleep(1)
            sample(pid, stats)
        wait_snapshot_contains(primary_sid, "RC2_E2E_STREAM_DONE")
        assert_alive(primary_sid)

        send_text(hidden_sid, (
            "python3 - <<'PY'\n"
            f"for i in range({HIDDEN_LINES}):\n"
            "    print(f'RC2_E2E_HIDDEN_{i:06d}_abcdefghijklmnopqrstuvwxyz0123456789')\n"
            "print('RC2_E2E_HIDDEN_DONE')\n"
            "PY\n"
        ))
        time.sleep(5)
        hidden_health = rpc("surface.health", {"id": hidden_sid})
        hidden_snap = snapshot(hidden_sid)
        if hidden_health.get("output_partial") or hidden_snap.get("complete") is False or hidden_snap.get("partial"):
            stats["hidden_partial_seen"] = True
        else:
            raise Failure(f"hidden output did not report honest partial state: health={hidden_health} snapshot={hidden_snap}")
        rpc("workspace.select", {"id": hidden_wid})
        wait_snapshot_contains(hidden_sid, "RC2_E2E_HIDDEN_", timeout=15)
        rpc("workspace.select", {"id": primary_wid})

        chunk = "A" * 79 + "\n"
        payload = (chunk * ((LARGE_INPUT_BYTES // len(chunk)) + 1))[:LARGE_INPUT_BYTES]
        large_command = (
            "stty -echo\n"
            "cat >/tmp/rc2_large_input.txt <<'RC2EOF'\n"
            f"{payload}\n"
            "RC2EOF\n"
            "python3 - <<'PY'\n"
            "from pathlib import Path\n"
            "p=Path('/tmp/rc2_large_input.txt')\n"
            "print(f'RC2_LARGE_INPUT_BYTES:{p.stat().st_size}')\n"
            "PY\n"
            "stty echo\n"
        )
        large_result = send_text(primary_sid, large_command)
        if large_result.get("accepted") is False:
            if large_result.get("status") not in ("queue_full", "write_failed"):
                raise Failure(f"large input failed without explicit status: {large_result}")
        else:
            wait_snapshot_contains(primary_sid, f"RC2_LARGE_INPUT_BYTES:{LARGE_INPUT_BYTES + 1}", timeout=60)

        send_text(primary_sid, (
            "python3 - <<'PY'\n"
            "import sys, time\n"
            "sys.stdout.write('\\x1b[?1049h')\n"
            f"end=time.time()+{TUI_SECONDS}\n"
            "i=0\n"
            "while time.time()<end:\n"
            "    sys.stdout.write('\\x1b[HRC2_TUI_FRAME_%06d\\nmenu: [a] [b] [q]\\n' % i)\n"
            "    sys.stdout.flush()\n"
            "    i+=1\n"
            "    time.sleep(0.05)\n"
            "sys.stdout.write('\\x1b[?1049lRC2_TUI_DONE\\n')\n"
            "sys.stdout.flush()\n"
            "PY\n"
        ))
        wait_snapshot_contains(primary_sid, "RC2_TUI_DONE", timeout=max(20, TUI_SECONDS + 10))

        baseline = recent(max_bytes=64)
        if baseline.get("requires_baseline"):
            stats["baseline_required_seen"] = True
        else:
            raise Failure(f"events.recent did not require baseline under tiny replay cap: {baseline}")

        time.sleep(6)
        diagnostics = recent(max_bytes=256 * 1024).get("events", [])
        slow_count = sum(1 for event in diagnostics if event.get("kind") == "diagnostic.ws_slow_client")
        stats["dropped_event_count"] = slow_count
        stats["slow_ws_disconnect_seen"] = slow_count > 0
        if REQUIRE_SLOW_WS and slow_count == 0:
            raise Failure("slow websocket diagnostic was not observed")

        send_text(primary_sid, "exit\n")
        time.sleep(1)
        dead = rpc("surface.health", {"id": primary_sid})
        if dead.get("alive") is not False or dead.get("terminal_dead_reason") != "process_exited":
            raise Failure(f"child exit did not mark dead: {dead}")
        stats["child_exit_dead_seen"] = True
        after_exit = send_text(primary_sid, "pwd\n")
        if after_exit.get("accepted") is not False or after_exit.get("status") != "process_exited":
            raise Failure(f"send after exit was not explicit process_exited: {after_exit}")
        stats["app_alive_after_child_exit"] = app_pid() is not None
        sample(pid, stats)
        stats["duration_seconds"] = int(time.time() - start)
        print(json.dumps(stats, sort_keys=True))
    except Exception as exc:
        stats["status"] = "FAIL"
        stats["error"] = str(exc)
        stats["duration_seconds"] = int(time.time() - start)
        print(json.dumps(stats, sort_keys=True), file=sys.stderr)
        raise
    finally:
        if slow_sock is not None:
            try:
                slow_sock.close()
            except Exception:
                pass
        pkill_app()
        shutil.rmtree(app_support, ignore_errors=True)


if __name__ == "__main__":
    main()
