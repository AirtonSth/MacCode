#!/usr/bin/env python3
import argparse
import base64
import ctypes
import hashlib
import json
import math
import os
import re
import socket
import subprocess
import threading
import time
import urllib.request
import uuid
from pathlib import Path


GEOMETRY_MODE = "rpc_pane_resize_to_appkit_to_ws_to_ios_ax"
HOST_MIRROR_MODE = "rpc_surface_send_text_to_ws_to_ios_presented_and_ax"
CLEANUP_MODE = "terminal_real_host_cleanup_v1"
DRIVER_READY_MODE = "terminal_real_host_driver_ready_v1"
MUTATION_CONTROL_MODE = "remote_ws_snapshot_v3"
CONTROL_CONNECT_ATTEMPTS = 2
CONTROL_RECONNECT_DELAY_SECONDS = 0.05
MIN_MUTATION_BUDGET_MS = 50
MAX_CONTROL_FRAME_BYTES = 1024 * 1024
REMOTE_MUTATION_METHODS = frozenset({"pane.resize", "surface.send_text"})
REMOTE_IDENTITY_KEYS = frozenset({
    "client_request_id", "connection_id", "expected_host_id", "expected_boot_epoch",
})
RENDERER_MODES = frozenset({"fixed_grid", "flow"})
RENDERER_AX_ROLES = {
    "fixed_grid": "StaticText",
    "flow": "Other",
}
FLOW_READY_MARKER = "RC2_FLOW_READY"
FLOW_PROMPT = "RC2_FLOW> "
FLOW_SETUP_COMMAND = (
    "printf '\\033]0;terminal\\007\\033[2J\\033[HRC2_FLOW_READY\\n'; "
    "env PS1='RC2_FLOW> ' HISTFILE=/dev/null "
    "/bin/bash --noprofile --norc --noediting -i\n"
)
FLOW_CLEANUP_COMMAND = (
    "exit\n"
    "printf '\\033]0;terminal\\007\\033[2J\\033[H'\n"
)
FLOW_STATE_TIMEOUT_SECONDS = 10


class Failure(RuntimeError):
    pass


class CleanupRequested(Failure):
    pass


class CanaryIdentityChanged(Failure):
    pass


def active_display_count():
    try:
        core_graphics = ctypes.CDLL(
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"
        )
        query = core_graphics.CGGetActiveDisplayList
        query.argtypes = [
            ctypes.c_uint32,
            ctypes.POINTER(ctypes.c_uint32),
            ctypes.POINTER(ctypes.c_uint32),
        ]
        query.restype = ctypes.c_int32
        count = ctypes.c_uint32(0)
        status = query(0, None, ctypes.byref(count))
    except (AttributeError, OSError) as exc:
        raise Failure(f"could not query active macOS displays: {exc}") from exc
    if status != 0:
        raise Failure(f"could not query active macOS displays: CGError {status}")
    return int(count.value)


def require_active_display(display_count_provider=None):
    provider = display_count_provider or active_display_count
    if provider() <= 0:
        raise Failure("active macOS display is required before terminal geometry proof")


def screen_is_locked():
    result = subprocess.run(
        ["/usr/sbin/ioreg", "-r", "-n", "Root", "-d", "1"],
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        raise Failure("could not query macOS screen-lock state")
    match = re.search(r'"CGSSessionScreenIsLocked"=(Yes|No)', result.stdout)
    if match is not None:
        return match.group(1) == "Yes"
    if (
        '"IOConsoleUsers"' in result.stdout
        and '"kCGSSessionOnConsoleKey"=Yes' in result.stdout
        and '"kCGSessionLoginDoneKey"=Yes' in result.stdout
    ):
        # macOS omits CGSSessionScreenIsLocked from the active console user
        # dictionary when the session is unlocked.
        return False
    raise Failure("could not query macOS screen-lock state")


def require_terminal_geometry_environment(
    display_count_provider=None,
    screen_lock_provider=None,
):
    lock_provider = screen_lock_provider or screen_is_locked
    if lock_provider():
        raise Failure("unlocked macOS screen is required before terminal geometry proof")
    require_active_display(display_count_provider)


class RefuseRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, new_url):
        raise Failure(f"refusing RPC redirect to {new_url}")


def epoch_milliseconds():
    return int(time.time() * 1_000)


def remaining_rpc_timeout(deadline_epoch_ms):
    if deadline_epoch_ms is None:
        return None
    remaining_ms = int(deadline_epoch_ms) - epoch_milliseconds()
    if remaining_ms < MIN_MUTATION_BUDGET_MS:
        raise Failure("insufficient request budget before remote mutation")
    return remaining_ms / 1_000


def parse_args():
    parser = argparse.ArgumentParser(
        description=(
            "Drive pane.resize on an isolated macOS host and synchronize each "
            "geometry, output, and title transition with the real iOS FlowUITest."
        )
    )
    parser.add_argument("--sync-dir", type=Path, required=True)
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--profile", required=True)
    parser.add_argument("--canary-root", type=Path, required=True)
    parser.add_argument("--canary-pid", type=int, required=True)
    parser.add_argument("--workspace-id", required=True)
    parser.add_argument("--surface-id", required=True)
    parser.add_argument("--split-id", required=True)
    parser.add_argument(
        "--renderer-mode",
        choices=sorted(RENDERER_MODES),
        required=True,
    )
    parser.add_argument("--sample-count", type=int, default=100)
    parser.add_argument("--latency-limit-ms", type=float, default=250)
    parser.add_argument("--ratio-delta", type=float, default=0.04)
    parser.add_argument("--startup-timeout-seconds", type=float, default=60)
    parser.add_argument("--validate-only", action="store_true")
    return parser.parse_args()


def validate(args):
    if args.host not in ("127.0.0.1", "localhost", "::1"):
        raise Failure("host must be loopback")
    if not 1 <= args.port <= 65535:
        raise Failure("port must be 1...65535")
    try:
        configured_primary_port = int(os.environ.get("RC2_PRIMARY_PORT", "18217"))
    except ValueError as exc:
        raise Failure("RC2_PRIMARY_PORT must be an integer") from exc
    if args.port in {configured_primary_port, 18217}:
        raise Failure("refusing primary/default RemoteCode port")
    if args.sample_count != 100:
        raise Failure("sample-count must equal 100")
    if not 0 < args.latency_limit_ms <= 250:
        raise Failure("latency-limit-ms must be greater than 0 and at most 250")
    if not 0 < args.ratio_delta <= 0.2:
        raise Failure("ratio-delta must be greater than 0 and at most 0.2")
    if args.renderer_mode not in RENDERER_MODES:
        raise Failure("renderer-mode must be fixed_grid or flow")
    for name in ("run_id", "profile", "workspace_id", "surface_id", "split_id"):
        if not str(getattr(args, name)).strip():
            raise Failure(f"{name.replace('_', '-')} must be non-empty")
    for name in ("workspace_id", "surface_id", "split_id"):
        try:
            uuid.UUID(str(getattr(args, name)))
        except ValueError as exc:
            raise Failure(f"{name.replace('_', '-')} must be a UUID") from exc
    if args.sync_dir.is_symlink():
        raise Failure("sync-dir must not be a symlink")
    if not args.sync_dir.is_dir():
        raise Failure("sync-dir must already exist")
    args.canary_root = validated_canary_root(args.canary_root)
    verify_canary_identity(args)


def validated_canary_root(path):
    if path.is_symlink():
        raise Failure("canary-root must not be a symlink")
    try:
        resolved = path.resolve(strict=True)
    except FileNotFoundError as exc:
        raise Failure("canary-root must already exist") from exc
    if (
        not resolved.is_dir()
        or re.fullmatch(r"RemoteCodeAgentCanary-[A-Za-z0-9._-]+", resolved.name) is None
    ):
        raise Failure("canary-root must resolve to a RemoteCodeAgentCanary-* directory")
    return resolved


def canary_executable(args):
    return (
        args.canary_root
        / "app"
        / "RemoteCodeAgentCanary.app"
        / "Contents"
        / "MacOS"
        / "RemoteCodeAgentCanary"
    )


def pidfile_pid(args):
    pidfile = args.canary_root / "run" / "RemoteCodeAgentCanary.pid"
    if pidfile.is_symlink():
        raise Failure("canary pidfile must not be a symlink")
    try:
        if pidfile.resolve(strict=True) != pidfile:
            raise Failure("canary pidfile path must not traverse symlinks")
    except FileNotFoundError as exc:
        raise Failure("canary pidfile is missing or unreadable") from exc
    try:
        raw = pidfile.read_text(encoding="utf-8").strip()
    except OSError as exc:
        raise Failure("canary pidfile is missing or unreadable") from exc
    if not raw.isdigit() or int(raw) <= 1:
        raise Failure("canary pidfile must contain a numeric process ID")
    return int(raw)


def loaded_executable_paths(pid):
    result = subprocess.run(
        ["/usr/sbin/lsof", "-a", "-p", str(pid), "-d", "txt", "-Fn"],
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        return []
    return [
        line[1:]
        for line in result.stdout.splitlines()
        if line.startswith("n")
    ]


def listener_pids(port):
    result = subprocess.run(
        ["/usr/sbin/lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN", "-Fp"],
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode not in (0, 1):
        raise Failure(f"lsof failed while checking listener ownership: {result.stderr.strip()}")
    return {
        int(line[1:])
        for line in result.stdout.splitlines()
        if line.startswith("p") and line[1:].isdigit()
    }


def verify_canary_identity(args):
    if pidfile_pid(args) != args.canary_pid:
        raise Failure("canary pidfile does not match --canary-pid")
    executable = canary_executable(args)
    if executable.is_symlink() or not os.access(executable, os.X_OK):
        raise Failure("exact canary executable is missing, symlinked, or not executable")
    resolved_executable = str(executable.resolve(strict=True))
    if resolved_executable != str(executable):
        raise Failure("exact canary executable path must not traverse symlinks")
    loaded_paths = loaded_executable_paths(args.canary_pid)
    # macOS reports the process executable first, followed by runtime images
    # such as /usr/lib/dyld. Match the primary image exactly; do not reject the
    # expected runtime mappings or accept the canary path only as a later image.
    if not loaded_paths or loaded_paths[0] != resolved_executable:
        raise Failure("canary PID primary executable is not the exact canary executable")
    owners = listener_pids(args.port)
    if owners != {args.canary_pid}:
        raise Failure("configured port listener owner is not exactly the canary PID")


def rpc(args, method, params=None, timeout_seconds=5):
    host = f"[{args.host}]" if ":" in args.host else args.host
    body = json.dumps({
        "jsonrpc": "2.0",
        "id": str(uuid.uuid4()),
        "method": method,
        "params": params or {},
    }).encode()
    request = urllib.request.Request(
        f"http://{host}:{args.port}/v1/rpc",
        data=body,
        headers={"content-type": "application/json"},
        method="POST",
    )
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({}),
        RefuseRedirects(),
    )
    with opener.open(request, timeout=timeout_seconds) as response:
        payload = json.loads(response.read())
    if payload.get("error"):
        raise Failure(f"rpc {method} failed: {payload['error']}")
    return payload.get("result")


def masked_client_frame(opcode, payload):
    if not 0 <= opcode <= 0x0F or len(payload) > 125:
        raise Failure("invalid WebSocket control frame")
    mask = os.urandom(4)
    masked = bytes(
        value ^ mask[index % 4]
        for index, value in enumerate(payload)
    )
    return bytes([0x80 | opcode, 0x80 | len(payload)]) + mask + masked


def read_control_frame(sock, buffer):
    while True:
        if len(buffer) >= 2:
            first, second = buffer[0], buffer[1]
            if first & 0x80 == 0:
                raise Failure("fragmented control WebSocket frame is unsupported")
            if second & 0x80:
                raise Failure("server WebSocket frame must not be masked")
            payload_length = second & 0x7F
            offset = 2
            if payload_length == 126:
                if len(buffer) >= 4:
                    payload_length = int.from_bytes(buffer[2:4], "big")
                    offset = 4
                else:
                    payload_length = None
            elif payload_length == 127:
                if len(buffer) >= 10:
                    payload_length = int.from_bytes(buffer[2:10], "big")
                    offset = 10
                else:
                    payload_length = None
            if payload_length is not None:
                if payload_length > MAX_CONTROL_FRAME_BYTES:
                    raise Failure("control WebSocket frame exceeded 1 MiB")
                frame_end = offset + payload_length
                if len(buffer) >= frame_end:
                    payload = bytes(buffer[offset:frame_end])
                    del buffer[:frame_end]
                    return first & 0x0F, payload
        chunk = sock.recv(64 * 1024)
        if not chunk:
            raise Failure("control WebSocket closed")
        buffer.extend(chunk)
        if len(buffer) > MAX_CONTROL_FRAME_BYTES + 10:
            raise Failure("control WebSocket receive buffer exceeded 1 MiB")


def open_control_websocket(args, timeout_seconds=5):
    key = base64.b64encode(os.urandom(16)).decode("ascii")
    host_header = f"[{args.host}]" if ":" in args.host else args.host
    sock = socket.create_connection((args.host, args.port), timeout=timeout_seconds)
    try:
        request = (
            "GET /v1/ws HTTP/1.1\r\n"
            f"Host: {host_header}:{args.port}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            "X-RC2-Since-Seq: 9223372036854775807\r\n"
            "X-RC2-WS-Filter: cellular-safe\r\n"
            "\r\n"
        ).encode("ascii")
        sock.sendall(request)
        response = bytearray()
        while b"\r\n\r\n" not in response:
            chunk = sock.recv(4096)
            if not chunk:
                raise Failure("control WebSocket closed during handshake")
            response.extend(chunk)
            if len(response) > 64 * 1024:
                raise Failure("control WebSocket handshake exceeded 64 KiB")
        raw_headers, initial_frame_bytes = bytes(response).split(b"\r\n\r\n", 1)
        lines = raw_headers.split(b"\r\n")
        if not lines or b" 101 " not in lines[0]:
            raise Failure("control WebSocket upgrade did not return HTTP 101")
        headers = {}
        for line in lines[1:]:
            if b":" not in line:
                raise Failure("control WebSocket returned a malformed header")
            name, value = line.split(b":", 1)
            headers[name.strip().lower()] = value.strip()
        expected_accept = base64.b64encode(hashlib.sha1(
            (key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode("ascii")
        ).digest())
        if headers.get(b"sec-websocket-accept") != expected_accept:
            raise Failure("control WebSocket accept token mismatched")
        sock.settimeout(min(1, timeout_seconds))
        return sock, bytearray(initial_frame_bytes)
    except Exception:
        sock.close()
        raise


def welcome_identity(value):
    connection_id = value.get("connectionId") if isinstance(value, dict) else None
    host_id = value.get("hostId") if isinstance(value, dict) else None
    boot_epoch = value.get("bootEpoch") if isinstance(value, dict) else None
    capabilities = value.get("capabilities") if isinstance(value, dict) else None
    if (
        value.get("protocolVersion") != 3
        or value.get("type") != "welcome"
        or not isinstance(connection_id, str)
        or not connection_id
        or not isinstance(host_id, str)
        or not host_id
        or not isinstance(boot_epoch, int)
        or isinstance(boot_epoch, bool)
        or boot_epoch < 0
        or not isinstance(capabilities, list)
        or "snapshot.v3" not in capabilities
    ):
        raise Failure("control WebSocket welcome contract is invalid")
    return {
        "connection_id": connection_id,
        "host_id": host_id,
        "boot_epoch": boot_epoch,
    }


def read_control_welcome(sock, buffer):
    opcode, payload = read_control_frame(sock, buffer)
    if opcode != 0x1:
        raise Failure("control WebSocket did not send welcome first")
    try:
        value = json.loads(payload)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise Failure("control WebSocket welcome is not valid JSON") from exc
    return welcome_identity(value)


def snapshot_matches_identity(value, identity):
    return (
        isinstance(value, dict)
        and value.get("protocolVersion") == 3
        and value.get("type") == "snapshot"
        and value.get("connectionId") == identity["connection_id"]
        and value.get("hostId") == identity["host_id"]
        and value.get("bootEpoch") == identity["boot_epoch"]
        and value.get("stateVersion") == 3
        and isinstance(value.get("state"), dict)
    )


class RemoteMutationController:
    def __init__(self, args):
        self.args = args
        self.lock = threading.Lock()
        self.sock = None
        self.identity = None
        self.reader = None
        self.closed = False
        self.pinned_host_id = None
        self.pinned_boot_epoch = None

    def close(self):
        with self.lock:
            self.closed = True
            sock = self.sock
            reader = self.reader
            self.sock = None
            self.identity = None
        if sock is not None:
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            sock.close()
        if reader is not None and reader is not threading.current_thread():
            reader.join(timeout=2)

    def invalidate(self, sock):
        with self.lock:
            if self.sock is sock:
                self.sock = None
                self.identity = None
        try:
            sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        sock.close()

    def read_forever(self, sock, buffer):
        try:
            while True:
                try:
                    opcode, payload = read_control_frame(sock, buffer)
                except socket.timeout:
                    continue
                if opcode == 0x8:
                    return
                if opcode == 0x9:
                    sock.sendall(masked_client_frame(0xA, payload))
                elif opcode not in (0x1, 0x2, 0xA):
                    raise Failure(f"unsupported control WebSocket opcode {opcode}")
        except (Failure, OSError):
            pass
        finally:
            self.invalidate(sock)

    def open_ready_connection(self, deadline_epoch_ms=None):
        timeout = remaining_rpc_timeout(deadline_epoch_ms)
        if timeout is None:
            sock, buffer = open_control_websocket(self.args)
        else:
            sock, buffer = open_control_websocket(self.args, timeout_seconds=timeout)
        try:
            identity = read_control_welcome(sock, buffer)
            if self.pinned_host_id is not None and (
                identity["host_id"] != self.pinned_host_id
                or identity["boot_epoch"] != self.pinned_boot_epoch
            ):
                raise CanaryIdentityChanged(
                    "canary host identity or boot epoch changed during the proof run"
                )
            with self.lock:
                if self.closed:
                    raise Failure("remote mutation controller is closed")
                self.sock = sock
                self.identity = None
            reader = threading.Thread(
                target=self.read_forever,
                args=(sock, buffer),
                name="terminal-ios-mutation-control",
                daemon=True,
            )
            with self.lock:
                self.reader = reader
            reader.start()
            snapshot_params = {
                "connectionId": identity["connection_id"],
                "expectedHostId": identity["host_id"],
                "expectedBootEpoch": identity["boot_epoch"],
                "supportedStateVersion": 3,
            }
            timeout = remaining_rpc_timeout(deadline_epoch_ms)
            if timeout is None:
                snapshot = rpc(self.args, "sync.snapshot", snapshot_params)
            else:
                snapshot = rpc(
                    self.args,
                    "sync.snapshot",
                    snapshot_params,
                    timeout_seconds=timeout,
                )
            if not snapshot_matches_identity(snapshot, identity):
                raise Failure("sync.snapshot did not bind the control connection identity")
            with self.lock:
                if self.sock is not sock or not reader.is_alive():
                    raise Failure("control WebSocket closed before snapshot adoption")
                self.identity = identity
                self.pinned_host_id = identity["host_id"]
                self.pinned_boot_epoch = identity["boot_epoch"]
                return dict(identity)
        except Exception:
            self.invalidate(sock)
            raise

    def ensure_ready(self, deadline_epoch_ms=None):
        with self.lock:
            if self.closed:
                raise Failure("remote mutation controller is closed")
            if self.identity is not None and self.sock is not None:
                return dict(self.identity)
        last_error = None
        for attempt in range(CONTROL_CONNECT_ATTEMPTS):
            if attempt:
                timeout = remaining_rpc_timeout(deadline_epoch_ms)
                time.sleep(min(CONTROL_RECONNECT_DELAY_SECONDS, timeout or CONTROL_RECONNECT_DELAY_SECONDS))
            try:
                return self.open_ready_connection(deadline_epoch_ms)
            except CanaryIdentityChanged:
                raise
            except Exception as exc:
                last_error = exc
        raise Failure(
            f"remote mutation control could not establish a snapshot-bound connection: {last_error}"
        ) from last_error

    def mutate(self, method, params, deadline_epoch_ms=None):
        if method not in REMOTE_MUTATION_METHODS:
            raise Failure(f"unsupported remote mutation method: {method}")
        if REMOTE_IDENTITY_KEYS.intersection(params):
            raise Failure("business params must not supply remote mutation identity")
        identity = self.ensure_ready(deadline_epoch_ms)
        wire_params = dict(params)
        wire_params.update({
            "client_request_id": str(uuid.uuid4()),
            "connection_id": identity["connection_id"],
            "expected_host_id": identity["host_id"],
            "expected_boot_epoch": identity["boot_epoch"],
        })
        # Fail closed after the HTTP request starts. Retrying an ambiguous
        # outcome with a new idempotency key could duplicate the effect.
        timeout = remaining_rpc_timeout(deadline_epoch_ms)
        if timeout is None:
            return rpc(self.args, method, wire_params)
        return rpc(
            self.args,
            method,
            wire_params,
            timeout_seconds=timeout,
        )


def atomic_write_json(path, value):
    if path.exists():
        raise Failure(f"refusing to overwrite protocol file: {path}")
    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    try:
        with temporary.open("x", encoding="utf-8") as handle:
            json.dump(value, handle, sort_keys=True, separators=(",", ":"))
            handle.flush()
            os.fsync(handle.fileno())
        try:
            # link(2) fails if the final name appeared after the exists check;
            # unlike rename/replace, it cannot overwrite a stale protocol file.
            os.link(temporary, path)
        except FileExistsError as exc:
            raise Failure(f"refusing to overwrite protocol file: {path}") from exc
        directory_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def read_json(path):
    if path.is_symlink():
        raise Failure(f"protocol file must not be a symlink: {path}")
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def matching_canary_root(expected, candidate):
    if not isinstance(candidate, str):
        return False
    candidate_path = Path(candidate)
    if not candidate_path.is_absolute():
        return False
    try:
        return candidate_path.resolve(strict=True) == expected
    except (OSError, RuntimeError, ValueError):
        return False


def matching_identity(args, value, mode):
    return (
        value.get("mode") == mode
        and value.get("runID") == args.run_id
        and value.get("host") == args.host
        and value.get("port") == args.port
        and value.get("profile") == args.profile
        and matching_canary_root(args.canary_root, value.get("canaryRoot"))
        and value.get("canaryPID") == args.canary_pid
        and value.get("workspaceID") == args.workspace_id
        and value.get("surfaceID") == args.surface_id
        and value.get("splitID") == args.split_id
    )


def cleanup_path(sync_dir, nonce, suffix):
    return sync_dir / f"cleanup-{nonce}.{suffix}.json"


def validated_cleanup_request(args, nonce, expected_geometry=None):
    if nonce is None:
        return None
    path = cleanup_path(args.sync_dir, nonce, "request")
    if not path.exists():
        return None
    request = read_json(path)
    if not matching_identity(args, request, CLEANUP_MODE):
        raise Failure("cleanup request identity does not match the active run")
    if request.get("nonce") != nonce:
        raise Failure("cleanup request nonce does not match the active run")
    if request.get("index") != args.sample_count:
        raise Failure("cleanup request index does not bind the completed sample set")
    rows = request.get("rows")
    cols = request.get("cols")
    if (
        not isinstance(rows, int)
        or isinstance(rows, bool)
        or rows <= 0
        or not isinstance(cols, int)
        or isinstance(cols, bool)
        or cols <= 0
    ):
        raise Failure("cleanup request rows and cols must be positive integers")
    if expected_geometry is not None and (rows, cols) != expected_geometry:
        raise Failure("cleanup request rows and cols do not bind the original geometry")
    now = epoch_milliseconds()
    created_at = int(request.get("createdAtEpochMs", 0))
    deadline = int(request.get("deadlineEpochMs", 0))
    if created_at <= 0 or not created_at <= now <= deadline:
        raise Failure("cleanup request is stale or already beyond deadline")
    return request


def cleanup_requested(args, nonce):
    return validated_cleanup_request(args, nonce) is not None


def raise_if_cleanup_requested(args, nonce):
    if cleanup_requested(args, nonce):
        raise CleanupRequested("iOS requested independent driver cleanup")


def wait_for_geometry_request(args, index, nonce, startup_deadline):
    suffix = f"-{index:03d}.request.json"
    while time.monotonic() < startup_deadline:
        raise_if_cleanup_requested(args, nonce)
        candidates = sorted(
            path for path in args.sync_dir.glob("geometry-*.request.json")
            if path.name.endswith(suffix)
        )
        for path in candidates:
            value = read_json(path)
            if (
                not matching_identity(args, value, GEOMETRY_MODE)
                or value.get("index") != index
            ):
                continue
            candidate_nonce = value.get("nonce")
            if not isinstance(candidate_nonce, str) or len(candidate_nonce) < 16:
                raise Failure("request nonce is missing or too short")
            if nonce is not None and candidate_nonce != nonce:
                continue
            now = epoch_milliseconds()
            if not value.get("createdAtEpochMs") <= now <= value.get("deadlineEpochMs"):
                raise Failure(f"request {index} is stale or already beyond deadline")
            return path, value, candidate_nonce
        time.sleep(0.01)
    raise Failure(f"timed out waiting for geometry request {index}")


def pane_layout(args):
    panes = rpc(args, "pane.list", {"workspace_id": args.workspace_id})
    if not isinstance(panes, list):
        raise Failure("pane.list did not return an array")
    splits = [row for row in panes if row.get("kind") == "split"]
    if len(splits) != 1 or splits[0].get("id") != args.split_id:
        raise Failure("workspace must expose exactly the configured split")
    split = splits[0]
    orientation = split.get("orientation")
    if orientation not in ("horizontal", "vertical"):
        raise Failure("configured split orientation is invalid")
    raw_ratios = split.get("ratios")
    if not isinstance(raw_ratios, list) or len(raw_ratios) != 2:
        raise Failure("configured split must expose exactly two ratios")
    ratios = [float(value) for value in raw_ratios]
    if any(not math.isfinite(value) or value <= 0 for value in ratios):
        raise Failure("configured split ratios must be finite and positive")

    pane_rows = [row for row in panes if row.get("kind") == "pane"]
    if len(pane_rows) != 2:
        raise Failure("single configured split must contain exactly two panes")
    target_panes = [
        row for row in pane_rows
        if isinstance(row.get("surface_ids"), list)
        and args.surface_id in row["surface_ids"]
    ]
    if len(target_panes) != 1:
        raise Failure("configured terminal surface must belong to exactly one pane")
    target_pane = target_panes[0]
    if target_pane.get("selected_surface_id") != args.surface_id:
        raise Failure("configured terminal surface must be selected in its pane")
    return {
        "orientation": orientation,
        "ratios": ratios,
        "target_pane_id": target_pane.get("id"),
    }


def pane_split(args):
    return pane_layout(args)["ratios"]


def alternating_ratios(original, index, delta):
    result = list(original)
    direction = 1 if index % 2 == 0 else -1
    requested = direction * delta
    first = min(0.9, max(0.1, original[0] + requested))
    applied = first - original[0]
    second = original[1] - applied
    if second < 0.1 or second > 0.9 or abs(applied) < 0.005:
        raise Failure("ratio-delta cannot produce a safe alternating split")
    result[0] = first
    result[1] = second
    return result


def terminal_geometry(args):
    health = rpc(args, "surface.health", {"id": args.surface_id})
    if not isinstance(health, dict):
        raise Failure("surface.health did not return an object")
    rows = int(health.get("rows", 0))
    cols = int(health.get("cols", 0))
    if rows <= 0 or cols <= 0:
        raise Failure(f"surface.health returned invalid geometry: {health}")
    return rows, cols


def terminal_surface_text(args):
    value = rpc(args, "surface.read_text", {"id": args.surface_id})
    if not isinstance(value, str):
        raise Failure("surface.read_text did not return terminal text")
    return value


def terminal_surface_title(args):
    surfaces = rpc(args, "pane.surfaces", {"workspace_id": args.workspace_id})
    if not isinstance(surfaces, list):
        raise Failure("pane.surfaces did not return an array")
    matches = [row for row in surfaces if row.get("id") == args.surface_id]
    if len(matches) != 1 or not isinstance(matches[0].get("title"), str):
        raise Failure("pane.surfaces did not expose the configured terminal title")
    return matches[0]["title"]


def expected_renderer_ax_role(renderer_mode):
    try:
        return RENDERER_AX_ROLES[renderer_mode]
    except KeyError as exc:
        raise Failure("renderer-mode must be fixed_grid or flow") from exc


def wait_for_flow_setup(args, deadline_epoch_ms):
    while epoch_milliseconds() <= deadline_epoch_ms:
        text = terminal_surface_text(args)
        if FLOW_READY_MARKER in text and FLOW_PROMPT in text:
            return epoch_milliseconds()
        time.sleep(0.02)
    raise Failure("flow renderer setup did not expose its marker and nested-shell prompt")


def prepare_flow_renderer(args, controller):
    deadline_epoch_ms = epoch_milliseconds() + (FLOW_STATE_TIMEOUT_SECONDS * 1_000)
    _, completed_at, result = timed_mutating_rpc(
        args,
        controller,
        "surface.send_text",
        {"id": args.surface_id, "text": FLOW_SETUP_COMMAND},
        deadline_epoch_ms,
    )
    if not isinstance(result, dict) or result.get("accepted") is not True:
        raise Failure(f"surface.send_text rejected flow renderer setup: {result}")
    try:
        verified_at = wait_for_flow_setup(args, deadline_epoch_ms)
    except Exception as setup_error:
        try:
            cleanup_flow_renderer(args, controller)
        except Exception as cleanup_error:
            raise Failure(
                f"{setup_error}; flow setup rollback failed: {cleanup_error}"
            ) from setup_error
        raise
    return {
        "flow_setup_applied": True,
        "flow_setup_rpc_completed_at_epoch_ms": completed_at,
        "flow_setup_verified_at_epoch_ms": verified_at,
    }


def wait_for_flow_cleanup(args, deadline_epoch_ms):
    last_title = None
    while epoch_milliseconds() <= deadline_epoch_ms:
        text = terminal_surface_text(args)
        last_title = terminal_surface_title(args)
        if (
            last_title == "terminal"
            and FLOW_READY_MARKER not in text
            and FLOW_PROMPT not in text
        ):
            return epoch_milliseconds()
        time.sleep(0.02)
    raise Failure(
        "flow cleanup did not restore title=terminal and clear the flow marker/prompt; "
        f"last title={last_title!r}"
    )


def cleanup_flow_renderer(args, controller):
    deadline_epoch_ms = epoch_milliseconds() + (FLOW_STATE_TIMEOUT_SECONDS * 1_000)
    _, completed_at, result = timed_mutating_rpc(
        args,
        controller,
        "surface.send_text",
        {"id": args.surface_id, "text": FLOW_CLEANUP_COMMAND},
        deadline_epoch_ms,
    )
    if not isinstance(result, dict) or result.get("accepted") is not True:
        raise Failure(f"surface.send_text rejected flow renderer cleanup: {result}")
    verified_at = wait_for_flow_cleanup(args, deadline_epoch_ms)
    return {
        "flow_cleanup_verified": True,
        "flow_cleanup_rpc_completed_at_epoch_ms": completed_at,
        "flow_cleanup_verified_at_epoch_ms": verified_at,
    }


def geometry_transition_matches(previous, current, orientation):
    if orientation == "horizontal":
        return current[0] == previous[0] and current[1] != previous[1]
    if orientation == "vertical":
        return current[0] != previous[0] and current[1] == previous[1]
    raise Failure("configured split orientation is invalid")


def validate_latency_sample(latency_ms, latency_limit_ms, label):
    if latency_ms < 0 or latency_ms > latency_limit_ms * 2:
        raise Failure(f"{label} exceeded the hard maximum latency")


def validate_latency_samples(samples, latency_limit_ms, label):
    if len(samples) != 100:
        raise Failure(f"{label} did not produce exactly 100 latency samples")
    values = [float(value) for value in samples]
    for value in values:
        validate_latency_sample(value, latency_limit_ms, label)
    ordered = sorted(values)
    p95_ms = ordered[math.ceil(0.95 * len(ordered)) - 1]
    violations = sum(value > latency_limit_ms for value in ordered)
    if violations > 1:
        raise Failure(
            f"{label} exceeded the near-real-time limit in more than 1 of 100 samples"
        )
    return {
        "p95_ms": p95_ms,
        "max_ms": ordered[-1],
        "over_limit_count": violations,
    }


def wait_for_geometry(
    args,
    nonce,
    previous,
    expected,
    deadline_epoch_ms,
    orientation=None,
):
    while epoch_milliseconds() <= deadline_epoch_ms:
        if nonce is not None:
            raise_if_cleanup_requested(args, nonce)
        current = terminal_geometry(args)
        if expected is not None:
            if current == expected:
                return current
        elif geometry_transition_matches(previous, current, orientation):
            return current
        time.sleep(0.01)
    raise Failure("host terminal geometry did not change before request deadline")


def wait_for_ratios(args, nonce, expected, deadline_epoch_ms):
    while epoch_milliseconds() <= deadline_epoch_ms:
        if nonce is not None:
            raise_if_cleanup_requested(args, nonce)
        current = pane_split(args)
        if ratios_match(current, expected):
            return current, epoch_milliseconds()
        time.sleep(0.01)
    raise Failure("pane.list did not read back the exact requested ratios before deadline")


def geometry_protocol_path(sync_dir, nonce, index, suffix):
    return sync_dir / f"geometry-{nonce}-{index:03d}.{suffix}.json"


def identity_payload(args):
    return {
        "runID": args.run_id,
        "host": args.host,
        "port": args.port,
        "profile": args.profile,
        "canaryRoot": str(args.canary_root),
        "canaryPID": args.canary_pid,
        "workspaceID": args.workspace_id,
        "surfaceID": args.surface_id,
        "splitID": args.split_id,
    }


def driver_ready_path(sync_dir):
    return sync_dir / "driver-ready.json"


def timed_mutating_rpc(args, controller, method, params, deadline_epoch_ms=None):
    remaining_rpc_timeout(deadline_epoch_ms)
    controller.ensure_ready(deadline_epoch_ms)
    verify_canary_identity(args)
    remaining_rpc_timeout(deadline_epoch_ms)
    # Captured after the last identity check and immediately BEFORE the RPC.
    started_at = epoch_milliseconds()
    result = controller.mutate(method, params, deadline_epoch_ms)
    return started_at, epoch_milliseconds(), result


def calibrate_and_restore_layout(args, controller, layout, original_geometry):
    original_ratios = layout["ratios"]
    calibration_ratios = alternating_ratios(
        original_ratios,
        0,
        args.ratio_delta,
    )
    calibration_deadline = epoch_milliseconds() + 10_000
    calibration_started_at, _, _ = timed_mutating_rpc(
        args,
        controller,
        "pane.resize",
        {
            "workspace_id": args.workspace_id,
            "split_id": args.split_id,
            "ratios": calibration_ratios,
        },
        calibration_deadline,
    )
    _, calibration_ratios_observed_at = wait_for_ratios(
        args,
        None,
        calibration_ratios,
        calibration_deadline,
    )
    calibrated_geometry = wait_for_geometry(
        args,
        None,
        original_geometry,
        None,
        calibration_deadline,
        orientation=layout["orientation"],
    )

    restore_deadline = epoch_milliseconds() + 10_000
    restore_started_at, _, _ = timed_mutating_rpc(
        args,
        controller,
        "pane.resize",
        {
            "workspace_id": args.workspace_id,
            "split_id": args.split_id,
            "ratios": original_ratios,
        },
        restore_deadline,
    )
    restored_ratios, restored_ratios_observed_at = wait_for_ratios(
        args,
        None,
        original_ratios,
        restore_deadline,
    )
    restored_geometry = wait_for_geometry(
        args,
        None,
        calibrated_geometry,
        original_geometry,
        restore_deadline,
    )
    if not ratios_match(restored_ratios, original_ratios):
        raise Failure("calibration did not restore the exact original pane ratios")
    if restored_geometry != original_geometry:
        raise Failure("calibration did not restore the exact original terminal geometry")
    return {
        "orientation": layout["orientation"],
        "targetPaneID": layout["target_pane_id"],
        "originalRatios": original_ratios,
        "calibrationRatios": calibration_ratios,
        "restoredRatios": restored_ratios,
        "originalRows": original_geometry[0],
        "originalCols": original_geometry[1],
        "calibratedRows": calibrated_geometry[0],
        "calibratedCols": calibrated_geometry[1],
        "restoredRows": restored_geometry[0],
        "restoredCols": restored_geometry[1],
        "ratioDelta": abs(calibration_ratios[0] - original_ratios[0]),
        "calibrationStartedAtEpochMs": calibration_started_at,
        "calibrationRatiosObservedAtEpochMs": calibration_ratios_observed_at,
        "restoreStartedAtEpochMs": restore_started_at,
        "restoredRatiosObservedAtEpochMs": restored_ratios_observed_at,
        "readyAtEpochMs": epoch_milliseconds(),
    }


def wait_for_geometry_ack(args, request, result):
    path = geometry_protocol_path(
        args.sync_dir,
        request["nonce"],
        request["index"],
        "ack",
    )
    while epoch_milliseconds() <= request["deadlineEpochMs"]:
        raise_if_cleanup_requested(args, request["nonce"])
        if path.exists():
            ack = read_json(path)
            if not matching_identity(args, ack, GEOMETRY_MODE):
                raise Failure("geometry ack identity does not match the active run")
            if any(ack.get(key) != request.get(key) for key in ("nonce", "index", "restore")):
                raise Failure("geometry ack nonce, index, or restore flag mismatched")
            if (ack.get("rows"), ack.get("cols")) != (result["rows"], result["cols"]):
                raise Failure("geometry ack does not bind the driver result rows and cols")
            observed = int(ack.get("iosAXObservedAtEpochMs", 0))
            latency = float(ack.get("latencyMilliseconds", -1))
            if observed < result["driverStartedAtEpochMs"] or observed > request["deadlineEpochMs"]:
                raise Failure("geometry ack timestamp is stale or precedes pane.resize")
            if abs(latency - (observed - result["driverStartedAtEpochMs"])) > 0.01:
                raise Failure("geometry ack latency does not match its timestamps")
            validate_latency_sample(latency, args.latency_limit_ms, "geometry ack")
            return ack
        time.sleep(0.01)
    raise Failure("iOS AX ack did not arrive before request deadline")


def run_geometry_protocol(args, controller, original_layout, original_geometry, state):
    original_ratios = original_layout["ratios"]
    samples = []
    for index in range(args.sample_count + 1):
        _, request, nonce = wait_for_geometry_request(
            args,
            index,
            state["nonce"],
            time.monotonic() + args.startup_timeout_seconds,
        )
        state["nonce"] = nonce
        restore = index == args.sample_count
        if bool(request.get("restore")) != restore:
            raise Failure(f"request {index} restore flag is invalid")
        previous = terminal_geometry(args)
        if previous != (int(request.get("rows", 0)), int(request.get("cols", 0))):
            raise Failure(f"request {index} does not bind the current host rows and cols")
        if restore:
            expected = (
                int(request.get("expectedRows", 0)),
                int(request.get("expectedCols", 0)),
            )
            if expected != original_geometry:
                raise Failure("restore request does not bind the original terminal geometry")
            ratios = original_ratios
        else:
            expected = None
            ratios = alternating_ratios(original_ratios, index, args.ratio_delta)

        driver_started_at, rpc_completed_at, _ = timed_mutating_rpc(
            args,
            controller,
            "pane.resize",
            {
                "workspace_id": args.workspace_id,
                "split_id": args.split_id,
                "ratios": ratios,
            },
            int(request["deadlineEpochMs"]),
        )
        observed_ratios, ratios_observed_at = wait_for_ratios(
            args,
            nonce,
            ratios,
            int(request["deadlineEpochMs"]),
        )
        current = wait_for_geometry(
            args,
            nonce,
            previous,
            expected,
            int(request["deadlineEpochMs"]),
            orientation=None if restore else original_layout["orientation"],
        )
        geometry_observed_at = epoch_milliseconds()
        result = {
            "mode": GEOMETRY_MODE,
            "nonce": nonce,
            "index": index,
            "previousRows": previous[0],
            "previousCols": previous[1],
            "rows": current[0],
            "cols": current[1],
            "ratios": observed_ratios,
            "restore": restore,
            "driverStartedAtEpochMs": driver_started_at,
            "rpcCompletedAtEpochMs": rpc_completed_at,
            "ratiosObservedAtEpochMs": ratios_observed_at,
            "geometryObservedAtEpochMs": geometry_observed_at,
            **identity_payload(args),
        }
        atomic_write_json(
            geometry_protocol_path(args.sync_dir, nonce, index, "result"),
            result,
        )
        ack = wait_for_geometry_ack(args, request, result)
        if not restore:
            samples.append(float(ack["latencyMilliseconds"]))
    validate_latency_samples(samples, args.latency_limit_ms, "geometry protocol")
    return samples


def mirror_protocol_path(sync_dir, nonce, kind, index, suffix):
    return sync_dir / f"mirror-{nonce}-{kind}-{index:03d}.{suffix}.json"


def expected_mirror_value(nonce, kind, index):
    if kind == "output":
        # Keep the proof marker on one rendered phone line. The full nonce is
        # still bound separately by the request path and JSON identity fields.
        return f"RC2O_{nonce[:16]}_{index:03d}"
    return f"RC2_HOST_{kind.upper()}_{nonce}_{index:03d}_"


def mirror_value_matches(nonce, kind, index, value):
    if not isinstance(value, str):
        return False
    expected = expected_mirror_value(nonce, kind, index)
    if kind == "output":
        return value == expected
    return re.fullmatch(re.escape(expected) + r"[0-9A-Fa-f]{32}", value) is not None


def wait_for_mirror_request(args, nonce, kind, index):
    path = mirror_protocol_path(args.sync_dir, nonce, kind, index, "request")
    deadline = time.monotonic() + args.startup_timeout_seconds
    while time.monotonic() <= deadline:
        raise_if_cleanup_requested(args, nonce)
        if path.exists():
            request = read_json(path)
            if not matching_identity(args, request, HOST_MIRROR_MODE):
                raise Failure(f"{kind} request identity does not match the active run")
            if (
                request.get("nonce") != nonce
                or request.get("kind") != kind
                or request.get("index") != index
            ):
                raise Failure(f"{kind} request nonce, kind, or index mismatched")
            if request.get("rendererMode") != args.renderer_mode:
                raise Failure(f"{kind} request renderer mode does not match the active run")
            expected_ax_role = expected_renderer_ax_role(args.renderer_mode)
            if kind == "output":
                if request.get("axRoleBefore") != expected_ax_role:
                    raise Failure(
                        "output request AX role does not match the configured renderer mode"
                    )
            elif request.get("axRoleBefore") is not None:
                raise Failure("title request must not claim a terminal-output AX role")
            value = request.get("value")
            if not mirror_value_matches(nonce, kind, index, value):
                raise Failure(f"{kind} request value is not bound to nonce and index")
            rows = request.get("rows")
            cols = request.get("cols")
            if (
                not isinstance(rows, int)
                or isinstance(rows, bool)
                or rows <= 0
                or not isinstance(cols, int)
                or isinstance(cols, bool)
                or cols <= 0
            ):
                raise Failure(f"{kind} request rows and cols must be positive integers")
            now = epoch_milliseconds()
            created_at = int(request.get("createdAtEpochMs", 0))
            request_deadline = int(request.get("deadlineEpochMs", 0))
            if created_at <= 0 or not created_at <= now <= request_deadline:
                raise Failure(f"{kind} request is stale or already beyond deadline")
            return request
        time.sleep(0.01)
    raise Failure(f"timed out waiting for host-origin {kind} request {index}")


def mirror_command(kind, value):
    if kind == "output":
        encoded = value.encode("ascii").hex()
        # The literal marker never enters the PTY input, so terminal echo alone
        # cannot satisfy the iOS output assertion.
        # Keep the marker as the newest completed visible line while the receipt
        # is captured. The next request waits for this short command to finish,
        # so shell prompts/echoes cannot satisfy or race the one-shot arm.
        return (
            f"printf '%s' '{encoded}' | /usr/bin/xxd -r -p; "
            "printf '\\n'; sleep 0.6\n"
        )
    if kind == "title":
        # Keep the OSC title observable for longer than the 250 ms gate before
        # shell prompt hooks can replace it.
        return f"printf '\\033]0;{value}\\007'; sleep 0.4\n"
    raise Failure(f"unsupported host mirror kind: {kind}")


def wait_for_mirror_ack(args, request, result):
    path = mirror_protocol_path(
        args.sync_dir,
        request["nonce"],
        request["kind"],
        request["index"],
        "ack",
    )
    while epoch_milliseconds() <= request["deadlineEpochMs"]:
        raise_if_cleanup_requested(args, request["nonce"])
        if path.exists():
            ack = read_json(path)
            if not matching_identity(args, ack, HOST_MIRROR_MODE):
                raise Failure("host mirror ack identity does not match the active run")
            for key in ("nonce", "kind", "index", "value"):
                if ack.get(key) != request.get(key):
                    raise Failure(f"host mirror ack {key} does not bind the request")
            if (
                ack.get("rendererMode") != args.renderer_mode
                or result.get("rendererMode") != args.renderer_mode
            ):
                raise Failure("host mirror artifacts do not bind the configured renderer mode")
            if (ack.get("rows"), ack.get("cols")) != (request["rows"], request["cols"]):
                raise Failure("host mirror ack rows and cols do not bind the request")
            ax_observed = int(ack.get("iosAXObservedAtEpochMs", 0))
            ax_latency = float(ack.get("axLatencyMilliseconds", -1))
            latency = float(ack.get("latencyMilliseconds", -1))
            if (
                ax_observed < result["driverStartedAtEpochMs"]
                or ax_observed > request["deadlineEpochMs"]
            ):
                raise Failure("host mirror AX timestamp is stale or precedes surface.send_text")
            if abs(ax_latency - (ax_observed - result["driverStartedAtEpochMs"])) > 0.01:
                raise Failure("host mirror AX latency does not match its timestamps")
            validate_latency_sample(ax_latency, args.latency_limit_ms, "host mirror AX ack")

            primary_observed = ax_observed
            if request["kind"] == "output":
                expected_ax_role = expected_renderer_ax_role(args.renderer_mode)
                if (
                    request.get("axRoleBefore") != expected_ax_role
                    or result.get("axRoleBefore") != expected_ax_role
                    or ack.get("axRoleBefore") != expected_ax_role
                    or ack.get("axRoleAfter") != expected_ax_role
                ):
                    raise Failure(
                        "host mirror output artifacts do not prove the expected AX role before and after the sample"
                    )
                expected_request_id = (
                    f"{request['nonce']}-output-{request['index']:03d}"
                )
                expected_digest = hashlib.sha256(
                    request["value"].encode("utf-8")
                ).hexdigest()
                presented = int(ack.get("iosPresentedAtEpochMs", 0))
                if (
                    ack.get("presentationRequestID") != expected_request_id
                    or ack.get("presentationLastLineSHA256") != expected_digest
                    or int(ack.get("presentationRenderRevision", 0)) <= 0
                    or int(ack.get("presentationDisplayCyclesObserved", 0)) < 2
                    or ack.get("presentationBoundary") != "second_display_refresh"
                    or not math.isfinite(float(ack.get("presentationDisplayTimestamp", 0)))
                    or float(ack.get("presentationDisplayTimestamp", 0)) <= 0
                    or ack.get("presentationSnapshotScope") != "visible_line_rect"
                    or ack.get("presentationSnapshotAfterScreenUpdates") is not False
                    or int(ack.get("presentationSnapshotDurationMilliseconds", -1)) < 0
                    or presented < result["driverStartedAtEpochMs"]
                    or presented > request["deadlineEpochMs"]
                ):
                    raise Failure(
                        "host mirror presentation receipt does not bind the request, digest, revision, and timestamp"
                    )
                primary_observed = presented
            elif any(
                ack.get(key) is not None
                for key in (
                    "axRoleBefore",
                    "axRoleAfter",
                    "presentationRequestID",
                    "presentationRenderRevision",
                    "presentationLastLineSHA256",
                    "presentationDisplayCyclesObserved",
                    "presentationBoundary",
                    "presentationDisplayTimestamp",
                    "presentationSnapshotScope",
                    "presentationSnapshotAfterScreenUpdates",
                    "presentationSnapshotDurationMilliseconds",
                    "iosPresentedAtEpochMs",
                )
            ):
                raise Failure("title ack must not claim a terminal-line presentation receipt")

            if abs(latency - (primary_observed - result["driverStartedAtEpochMs"])) > 0.01:
                raise Failure("host mirror primary latency does not match its timestamps")
            validate_latency_sample(latency, args.latency_limit_ms, "host mirror ack")
            return ack
        time.sleep(0.01)
    raise Failure("host mirror iOS AX ack did not arrive before request deadline")


def run_mirror_protocol(args, controller, nonce, kind):
    samples = []
    for index in range(args.sample_count):
        request = wait_for_mirror_request(args, nonce, kind, index)
        if terminal_geometry(args) != (request["rows"], request["cols"]):
            raise Failure(f"host-origin {kind} request does not bind current host geometry")
        driver_started_at, rpc_completed_at, rpc_result = timed_mutating_rpc(
            args,
            controller,
            "surface.send_text",
            {"id": args.surface_id, "text": mirror_command(kind, request["value"])},
            int(request["deadlineEpochMs"]),
        )
        if not isinstance(rpc_result, dict) or rpc_result.get("accepted") is not True:
            raise Failure(f"surface.send_text rejected host-origin {kind} sample {index}: {rpc_result}")
        result = {
            "mode": HOST_MIRROR_MODE,
            "nonce": nonce,
            "index": index,
            "kind": kind,
            "value": request["value"],
            "rows": request["rows"],
            "cols": request["cols"],
            "rendererMode": args.renderer_mode,
            "axRoleBefore": request.get("axRoleBefore"),
            "rpcAccepted": True,
            "rpcStatus": str(rpc_result.get("status", "accepted")),
            "driverStartedAtEpochMs": driver_started_at,
            "rpcCompletedAtEpochMs": rpc_completed_at,
            **identity_payload(args),
        }
        atomic_write_json(
            mirror_protocol_path(args.sync_dir, nonce, kind, index, "result"),
            result,
        )
        ack = wait_for_mirror_ack(args, request, result)
        samples.append(float(ack["latencyMilliseconds"]))
        if kind == "output" and index + 1 < args.sample_count:
            # Each output trial is independent: let the receipt-hold command
            # finish and its prompt settle before the next request is armed.
            time.sleep(0.65)
        elif kind == "title" and index + 1 < args.sample_count:
            # Each title command intentionally keeps the title stable for 400 ms.
            # Do not charge the next sample for the prior shell command's sleep.
            time.sleep(0.45)
    validate_latency_samples(samples, args.latency_limit_ms, f"host-origin {kind} protocol")
    return samples


def ratios_match(actual, expected):
    return len(actual) == len(expected) and all(
        abs(left - right) <= 1e-6
        for left, right in zip(actual, expected)
    )


def restore_and_confirm_layout(args, controller, original_ratios, original_geometry):
    started_at = epoch_milliseconds()
    restored_ratios = None
    restored_geometry = None
    error = None
    try:
        timed_mutating_rpc(
            args,
            controller,
            "pane.resize",
            {
                "workspace_id": args.workspace_id,
                "split_id": args.split_id,
                "ratios": original_ratios,
            },
        )
        deadline = time.monotonic() + 10
        while time.monotonic() <= deadline:
            restored_ratios = pane_split(args)
            restored_geometry = terminal_geometry(args)
            if (
                ratios_match(restored_ratios, original_ratios)
                and restored_geometry == original_geometry
            ):
                break
            time.sleep(0.01)
        else:
            raise Failure("cleanup could not confirm original pane ratios and terminal geometry")
    except Exception as exc:
        error = str(exc)
    return {
        "success": error is None,
        "paneListVerified": error is None and restored_ratios is not None,
        "surfaceHealthVerified": error is None and restored_geometry is not None,
        "originalRatios": original_ratios,
        "restoredRatios": restored_ratios,
        "originalRows": original_geometry[0],
        "originalCols": original_geometry[1],
        "restoredRows": restored_geometry[0] if restored_geometry else None,
        "restoredCols": restored_geometry[1] if restored_geometry else None,
        "startedAtEpochMs": started_at,
        "completedAtEpochMs": epoch_milliseconds(),
        "error": error,
    }


def run_protocol(args):
    require_terminal_geometry_environment()
    controller = RemoteMutationController(args)
    protocol_result = None
    primary_error = None
    flow_cleanup_required = False
    flow_setup = {
        "flow_setup_applied": False,
        "flow_setup_rpc_completed_at_epoch_ms": None,
        "flow_setup_verified_at_epoch_ms": None,
    }
    try:
        controller.ensure_ready()
        verify_canary_identity(args)
        original_layout = pane_layout(args)
        original_geometry = terminal_geometry(args)
        try:
            calibration = calibrate_and_restore_layout(
                args,
                controller,
                original_layout,
                original_geometry,
            )
        except Exception as exc:
            cleanup = restore_and_confirm_layout(
                args,
                controller,
                original_layout["ratios"],
                original_geometry,
            )
            if not cleanup["success"]:
                raise Failure(
                    f"calibration failed: {exc}; restore failed: {cleanup['error']}"
                ) from exc
            raise
        if args.renderer_mode == "flow":
            flow_setup = prepare_flow_renderer(args, controller)
            flow_cleanup_required = True
        ready_identity = controller.ensure_ready()
        verify_canary_identity(args)
        calibration["readyAtEpochMs"] = epoch_milliseconds()
        atomic_write_json(
            driver_ready_path(args.sync_dir),
            {
                "mode": DRIVER_READY_MODE,
                "rendererMode": args.renderer_mode,
                "expectedOutputAXRole": expected_renderer_ax_role(args.renderer_mode),
                "controlConnectionID": ready_identity["connection_id"],
                "hostID": ready_identity["host_id"],
                "bootEpoch": ready_identity["boot_epoch"],
                **calibration,
                **identity_payload(args),
            },
        )
        protocol_result = run_protocol_with_controller(
            args,
            controller,
            original_layout,
            original_geometry,
        )
    except Exception as exc:
        primary_error = exc
    finally:
        flow_cleanup = {
            "flow_cleanup_verified": args.renderer_mode == "fixed_grid",
            "flow_cleanup_rpc_completed_at_epoch_ms": None,
            "flow_cleanup_verified_at_epoch_ms": None,
        }
        flow_cleanup_error = None
        if flow_cleanup_required:
            try:
                flow_cleanup = cleanup_flow_renderer(args, controller)
            except Exception as exc:
                flow_cleanup_error = exc
        controller.close()
    if primary_error is not None:
        message = str(primary_error)
        if flow_cleanup_error is not None:
            message += f"; flow cleanup failed: {flow_cleanup_error}"
        raise Failure(message) from primary_error
    if flow_cleanup_error is not None:
        raise Failure(f"flow cleanup failed: {flow_cleanup_error}") from flow_cleanup_error
    if protocol_result is None:
        raise Failure("terminal renderer proof did not produce a result")
    protocol_result.update(flow_setup)
    protocol_result.update(flow_cleanup)
    return protocol_result


def run_protocol_with_controller(args, controller, original_layout, original_geometry):
    original_ratios = original_layout["ratios"]
    state = {"nonce": None}
    proof = None
    primary_error = None
    try:
        geometry_samples = run_geometry_protocol(
            args,
            controller,
            original_layout,
            original_geometry,
            state,
        )
        output_samples = run_mirror_protocol(args, controller, state["nonce"], "output")
        title_samples = run_mirror_protocol(args, controller, state["nonce"], "title")
        geometry_latency = validate_latency_samples(
            geometry_samples, args.latency_limit_ms, "geometry protocol"
        )
        output_latency = validate_latency_samples(
            output_samples, args.latency_limit_ms, "host-origin output protocol"
        )
        title_latency = validate_latency_samples(
            title_samples, args.latency_limit_ms, "host-origin title protocol"
        )
        proof = {
            "status": "PASS",
            "renderer_mode": args.renderer_mode,
            "expected_output_ax_role": expected_renderer_ax_role(args.renderer_mode),
            "geometry_mode": GEOMETRY_MODE,
            "host_mirror_mode": HOST_MIRROR_MODE,
            "geometry_claim": "RPC-driven host layout -> AppKit -> WS -> iOS AX",
            "host_mirror_claim": (
                "macOS host RPC surface.send_text -> terminal -> WS -> "
                "iOS UIKit presentation receipt with separate AX gate"
            ),
            "macos_ui_interaction": "NOT_CLAIMED",
            "geometry_samples": len(geometry_samples),
            "output_samples": len(output_samples),
            "output_ax_role_samples": len(output_samples),
            "title_samples": len(title_samples),
            "geometry_p95_latency_ms": geometry_latency["p95_ms"],
            "output_p95_latency_ms": output_latency["p95_ms"],
            "title_p95_latency_ms": title_latency["p95_ms"],
            "geometry_max_latency_ms": geometry_latency["max_ms"],
            "output_max_latency_ms": output_latency["max_ms"],
            "title_max_latency_ms": title_latency["max_ms"],
            "geometry_over_limit_count": geometry_latency["over_limit_count"],
            "output_over_limit_count": output_latency["over_limit_count"],
            "title_over_limit_count": title_latency["over_limit_count"],
        }
    except Exception as exc:
        primary_error = exc
    finally:
        cleanup = restore_and_confirm_layout(
            args,
            controller,
            original_ratios,
            original_geometry,
        )
        nonce = state["nonce"]
        cleanup_artifact_error = None
        if nonce is not None:
            cleanup_request_validated = False
            try:
                cleanup_request_validated = validated_cleanup_request(
                    args,
                    nonce,
                    expected_geometry=original_geometry,
                ) is not None
            except Exception as exc:
                cleanup_artifact_error = str(exc)
            cleanup_artifact = {
                "mode": CLEANUP_MODE,
                "nonce": nonce,
                "cleanupRequested": cleanup_path(args.sync_dir, nonce, "request").exists(),
                "cleanupRequestValidated": cleanup_request_validated,
                "index": args.sample_count,
                "rows": original_geometry[0],
                "cols": original_geometry[1],
                **cleanup,
                **identity_payload(args),
            }
            try:
                atomic_write_json(
                    cleanup_path(args.sync_dir, nonce, "result"),
                    cleanup_artifact,
                )
            except Exception as exc:
                artifact_write_error = str(exc)
                cleanup_artifact_error = (
                    f"{cleanup_artifact_error}; {artifact_write_error}"
                    if cleanup_artifact_error
                    else artifact_write_error
                )
        if primary_error is not None:
            message = str(primary_error)
            if not cleanup["success"]:
                message += f"; cleanup failed: {cleanup['error']}"
            if cleanup_artifact_error is not None:
                message += f"; cleanup artifact failed: {cleanup_artifact_error}"
            raise Failure(message) from primary_error
        if not cleanup["success"]:
            raise Failure(f"cleanup failed: {cleanup['error']}")
        if cleanup_artifact_error is not None:
            raise Failure(f"cleanup artifact failed: {cleanup_artifact_error}")
    proof["layout_restored"] = True
    proof["cleanup_verified"] = True
    return proof


def main():
    args = parse_args()
    validate(args)
    if args.validate_only:
        print(json.dumps({
            "geometry_mode": GEOMETRY_MODE,
            "host_mirror_mode": HOST_MIRROR_MODE,
            "renderer_mode": args.renderer_mode,
            "expected_output_ax_role": expected_renderer_ax_role(args.renderer_mode),
            "sample_count": args.sample_count,
            "latency_limit_ms": args.latency_limit_ms,
            "sync_dir": str(args.sync_dir.resolve()),
            "canary_root": str(args.canary_root),
            "canary_pid": args.canary_pid,
            "listener_owner_verified": True,
            "mutation_control": MUTATION_CONTROL_MODE,
        }, sort_keys=True))
        return
    print(json.dumps(run_protocol(args), sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(json.dumps({"status": "FAIL", "error": str(exc)}, sort_keys=True))
        raise
