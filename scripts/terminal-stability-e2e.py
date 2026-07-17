#!/usr/bin/env python3
import argparse
import base64
import hashlib
import json
import os
import shlex
import shutil
import signal
import socket
import statistics
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
import uuid
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CANARY_SCRIPT = ROOT / "scripts" / "canary-app.sh"
PRIMARY_PORT = int(os.environ.get("RC2_PRIMARY_PORT", "18217"))
PORT = int(os.environ.get("RC2_E2E_PORT", "28217"))
BASE = f"http://127.0.0.1:{PORT}"
RUN_SECONDS = int(os.environ.get("RC2_E2E_DURATION_SECONDS", "120"))
TERMINAL_COUNT = int(os.environ.get("RC2_E2E_TERMINAL_COUNT", "2"))
PRE_GATE_SECONDS = int(os.environ.get("RC2_E2E_PRE_GATE_SECONDS", "0"))
SAMPLE_INTERVAL_SECONDS = float(os.environ.get("RC2_E2E_SAMPLE_INTERVAL_SECONDS", "10"))
CLIENT_WARMUP_SECONDS = float(os.environ.get("RC2_E2E_CLIENT_WARMUP_SECONDS", "0"))
WORKLOAD_STABILIZATION_SECONDS = float(
    os.environ.get("RC2_E2E_WORKLOAD_STABILIZATION_SECONDS", "3")
)
LINES = int(os.environ.get("RC2_E2E_LINES", "4000"))
HIDDEN_LINES = int(os.environ.get("RC2_E2E_HIDDEN_LINES", "22000"))
LARGE_INPUT_BYTES = int(os.environ.get("RC2_E2E_LARGE_INPUT_BYTES", str(256 * 1024)))
TUI_SECONDS = int(os.environ.get("RC2_E2E_TUI_SECONDS", "10"))
MAX_RSS_KB = int(os.environ.get("RC2_E2E_MAX_RSS_KB", "900000"))
MAX_RSS_TAIL_SLOPE_KB_PER_MINUTE = float(
    os.environ.get("RC2_E2E_MAX_RSS_TAIL_SLOPE_KB_PER_MINUTE", "256")
)
MAX_RSS_PLATEAU_DELTA_KB = int(os.environ.get("RC2_E2E_MAX_RSS_PLATEAU_DELTA_KB", "8192"))
MAX_RSS_TAIL_NET_GROWTH_KB = int(
    os.environ.get("RC2_E2E_MAX_RSS_TAIL_NET_GROWTH_KB", "8192")
)
MAX_POST_CLOSE_RSS_DELTA_KB = int(
    os.environ.get("RC2_E2E_MAX_POST_CLOSE_RSS_DELTA_KB", "32768")
)
REQUIRE_SLOW_WS = os.environ.get("RC2_E2E_REQUIRE_SLOW_WS", "0") == "1"
CANARY_ROOT_PREFIX = "RemoteCodeAgentCanary-"
RUN_ARTIFACT_PREFIX = "terminal-stability-e2e-"
DIAGNOSTIC_ONLY_METRICS = (
    "max_cpu_percent",
    "max_health_rpc_latency_ms",
    "post_idle_output_roundtrip_ms",
    "samples[].cpu_percent",
    "samples[].max_health_rpc_latency_ms",
)
MUTATING_RPC_METHODS = {
    "surface.send_text",
    "workspace.close",
    "workspace.create",
    "workspace.select",
}
MUTATION_IDENTITY_KEYS = {
    "client_request_id",
    "connection_id",
    "expected_host_id",
    "expected_boot_epoch",
}
_MUTATION_CONTROL = None


class Failure(RuntimeError):
    pass


def run(cmd, **kwargs):
    return subprocess.run(cmd, check=True, text=True, **kwargs)


def rpc(method, params=None):
    request_params = dict(params or {})
    if method in MUTATING_RPC_METHODS:
        if _MUTATION_CONTROL is None:
            raise Failure(f"{method} requires an active mutation control websocket")
        if MUTATION_IDENTITY_KEYS.intersection(request_params):
            raise Failure(f"{method} caller must not supply mutation identity fields")
        request_params.update(_MUTATION_CONTROL.request_identity())
    body = json.dumps({
        "jsonrpc": "2.0",
        "id": "1",
        "method": method,
        "params": request_params,
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


def parse_args():
    parser = argparse.ArgumentParser(
        description="Run the terminal stability suite against an isolated RemoteCode canary.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Safe defaults: 2 terminals for 120 seconds on port 28217.
Release gate: --release-soak enforces 12 terminals for 60 minutes, a 15-minute pre-gate,
and a 30-second connected-client warmup before workload startup.

Environment equivalents:
  RC2_E2E_PORT, RC2_E2E_DURATION_SECONDS, RC2_E2E_TERMINAL_COUNT,
  RC2_E2E_PRE_GATE_SECONDS, RC2_E2E_SAMPLE_INTERVAL_SECONDS,
  RC2_E2E_CLIENT_WARMUP_SECONDS, RC2_E2E_WORKLOAD_STABILIZATION_SECONDS,
  RC2_E2E_MAX_RSS_KB, RC2_E2E_MAX_RSS_TAIL_SLOPE_KB_PER_MINUTE,
  RC2_E2E_MAX_RSS_PLATEAU_DELTA_KB, RC2_E2E_MAX_RSS_TAIL_NET_GROWTH_KB,
  RC2_E2E_MAX_POST_CLOSE_RSS_DELTA_KB,
  RC2_E2E_REQUIRE_SLOW_WS.

This harness proves the isolated macOS host and RPC/event mirror seam. It does not claim real iOS UI coverage.
CPU and RPC/input latency metrics are diagnostic_only; they have no pass/fail threshold.
""",
    )
    parser.add_argument("--port", type=int, default=PORT, help="isolated canary HTTP port")
    parser.add_argument("--duration-seconds", type=int, default=RUN_SECONDS, help="concurrent workload duration")
    parser.add_argument("--terminal-count", type=int, default=TERMINAL_COUNT, help="number of terminal workspaces")
    parser.add_argument(
        "--pre-gate-seconds",
        type=int,
        default=PRE_GATE_SECONDS,
        help="elapsed time for the intermediate health and memory gate; 0 disables",
    )
    parser.add_argument(
        "--sample-interval-seconds",
        type=float,
        default=SAMPLE_INTERVAL_SECONDS,
        help="process and terminal-health sample interval",
    )
    parser.add_argument(
        "--client-warmup-seconds",
        type=float,
        default=CLIENT_WARMUP_SECONDS,
        help="connected-client warmup before terminal workloads start",
    )
    parser.add_argument(
        "--workload-stabilization-seconds",
        type=float,
        default=WORKLOAD_STABILIZATION_SECONDS,
        help="workload stabilization after a synchronized start and before the first resource baseline",
    )
    parser.add_argument(
        "--release-soak",
        action="store_true",
        help="require at least 12 terminals, 3600 seconds, and a 900-second pre-gate",
    )
    parser.add_argument(
        "--canary-root",
        type=Path,
        help="explicit RemoteCodeAgentCanary-* root; required with --no-build",
    )
    parser.add_argument(
        "--no-build",
        "--skip-build",
        dest="no_build",
        action="store_true",
        help="reuse an existing canary build under --canary-root",
    )
    parser.add_argument(
        "--validate-only",
        action="store_true",
        help="validate and print the effective configuration without building or launching",
    )
    args = parser.parse_args()
    if args.release_soak:
        args.duration_seconds = max(args.duration_seconds, 3600)
        args.terminal_count = max(args.terminal_count, 12)
        args.pre_gate_seconds = max(args.pre_gate_seconds, 900)
        args.client_warmup_seconds = max(args.client_warmup_seconds, 30)
        args.workload_stabilization_seconds = max(args.workload_stabilization_seconds, 3)
    args.require_slow_ws = REQUIRE_SLOW_WS or args.release_soak
    return args


def configure(args):
    global PORT, BASE, RUN_SECONDS, TERMINAL_COUNT, PRE_GATE_SECONDS, SAMPLE_INTERVAL_SECONDS
    global CLIENT_WARMUP_SECONDS, WORKLOAD_STABILIZATION_SECONDS, REQUIRE_SLOW_WS
    PORT = args.port
    BASE = f"http://127.0.0.1:{PORT}"
    RUN_SECONDS = args.duration_seconds
    TERMINAL_COUNT = args.terminal_count
    PRE_GATE_SECONDS = args.pre_gate_seconds
    SAMPLE_INTERVAL_SECONDS = args.sample_interval_seconds
    CLIENT_WARMUP_SECONDS = args.client_warmup_seconds
    WORKLOAD_STABILIZATION_SECONDS = args.workload_stabilization_seconds
    REQUIRE_SLOW_WS = args.require_slow_ws


def validated_canary_root(path):
    resolved = path.resolve()
    if not resolved.name.startswith(CANARY_ROOT_PREFIX):
        raise Failure(f"canary root must resolve to a {CANARY_ROOT_PREFIX}* directory")
    return resolved


def contained_path(path, parent, description):
    resolved_parent = parent.resolve()
    resolved = path.resolve()
    try:
        relative = resolved.relative_to(resolved_parent)
    except ValueError as exc:
        raise Failure(f"{description} escapes validated root {resolved_parent}: {resolved}") from exc
    if relative == Path("."):
        raise Failure(f"{description} must be below validated root {resolved_parent}")
    return resolved


def prepare_run_artifacts(canary_root):
    resolved_canary_root = validated_canary_root(canary_root)
    state_candidate = resolved_canary_root / "state"
    state_candidate.mkdir(parents=True, exist_ok=True)
    if state_candidate.is_symlink():
        raise Failure(f"refusing symlinked canary state root: {state_candidate}")
    state_root = contained_path(state_candidate, resolved_canary_root, "canary state root")
    run_artifact_root = Path(tempfile.mkdtemp(
        prefix=RUN_ARTIFACT_PREFIX,
        dir=str(state_root),
    ))
    run_artifact_root = contained_path(
        run_artifact_root,
        state_root,
        "terminal stability run artifact root",
    )
    workspace_tui_path = contained_path(
        run_artifact_root / "workspace-tui.sh",
        run_artifact_root,
        "workspace TUI artifact",
    )
    large_input_path = contained_path(
        run_artifact_root / "large-input.txt",
        run_artifact_root,
        "large input artifact",
    )
    workload_trigger_path = contained_path(
        run_artifact_root / "workload-start.trigger",
        run_artifact_root,
        "workload start trigger",
    )
    hidden_flood_done_path = contained_path(
        run_artifact_root / "hidden-flood.done",
        run_artifact_root,
        "hidden flood completion sentinel",
    )
    return (
        state_root,
        run_artifact_root,
        workspace_tui_path,
        large_input_path,
        workload_trigger_path,
        hidden_flood_done_path,
    )


def shell_quote_contained_path(path, parent, description):
    return shlex.quote(str(contained_path(path, parent, description)))


def cleanup_run_artifacts(run_artifact_root, state_root):
    if run_artifact_root is None or state_root is None:
        return
    if not run_artifact_root.exists() and not run_artifact_root.is_symlink():
        return
    if run_artifact_root.is_symlink():
        raise Failure(f"refusing symlinked terminal stability cleanup root: {run_artifact_root}")
    validated_run_root = contained_path(
        run_artifact_root,
        state_root,
        "terminal stability cleanup root",
    )
    if not validated_run_root.is_dir():
        raise Failure(f"refusing non-directory terminal stability cleanup root: {validated_run_root}")
    shutil.rmtree(validated_run_root)


def wait_for_exact_file(path, expected, timeout, description):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            if path.read_text(encoding="utf-8") == expected:
                return
        except FileNotFoundError:
            pass
        time.sleep(0.05)
    raise Failure(f"timed out waiting for {description}: {path}")


def validate_configuration(args):
    if not 1 <= args.port <= 65535:
        raise Failure(f"invalid E2E port {args.port}")
    if args.port == PRIMARY_PORT:
        raise Failure(f"refusing primary RemoteCode port {PRIMARY_PORT}")
    if args.duration_seconds < 1:
        raise Failure("duration must be at least 1 second")
    if not 2 <= args.terminal_count <= 24:
        raise Failure("terminal count must be between 2 and 24")
    if args.pre_gate_seconds < 0 or args.pre_gate_seconds >= args.duration_seconds:
        raise Failure("pre-gate must be 0 or shorter than the workload duration")
    if args.sample_interval_seconds <= 0 or args.sample_interval_seconds > 60:
        raise Failure("sample interval must be greater than 0 and no more than 60 seconds")
    if args.client_warmup_seconds < 0 or args.client_warmup_seconds > 300:
        raise Failure("client warmup must be between 0 and 300 seconds")
    if args.workload_stabilization_seconds < 1 or args.workload_stabilization_seconds > 60:
        raise Failure("workload stabilization must be between 1 and 60 seconds")
    if LARGE_INPUT_BYTES < 1:
        raise Failure("large input byte count must be at least 1")
    if MAX_POST_CLOSE_RSS_DELTA_KB < 0:
        raise Failure("post-close RSS delta must be non-negative")
    if args.no_build and args.canary_root is None:
        raise Failure("--no-build requires --canary-root; refusing an ambiguous build identity")
    if args.canary_root is not None:
        validated_canary_root(args.canary_root)


def refuse_unsafe_target():
    if PORT == PRIMARY_PORT:
        raise Failure(f"refusing primary RemoteCode port {PRIMARY_PORT}")
    owners = listener_pids(PORT)
    if owners:
        raise Failure(f"refusing occupied E2E port {PORT}; listener pid(s) {sorted(owners)}")
    try:
        with socket.create_connection(("127.0.0.1", PORT), timeout=0.25):
            raise Failure(f"refusing occupied E2E port {PORT}")
    except ConnectionRefusedError:
        return
    except socket.timeout:
        raise Failure(f"refusing unresponsive occupied E2E port {PORT}")


def app_pid(canary_root):
    pid_file = canary_root / "run" / "RemoteCodeAgentCanary.pid"
    try:
        pid = int(pid_file.read_text().strip())
    except (FileNotFoundError, ValueError):
        return None
    executable = canary_root / "app" / "RemoteCodeAgentCanary.app" / "Contents" / "MacOS" / "RemoteCodeAgentCanary"
    result = subprocess.run(
        ["lsof", "-a", "-p", str(pid), "-d", "txt", "-Fn"],
        text=True,
        capture_output=True,
    )
    loaded = [line[1:] for line in result.stdout.splitlines() if line.startswith("n")]
    return pid if result.returncode == 0 and str(executable) in loaded else None


def refuse_running_canary(canary_root):
    pid = app_pid(canary_root)
    if pid is not None:
        raise Failure(
            f"refusing already-running canary pid {pid} under {validated_canary_root(canary_root)}"
        )


def canary_app_support_path(canary_root):
    resolved_canary_root = validated_canary_root(canary_root)
    state_candidate = resolved_canary_root / "state"
    state_candidate.mkdir(parents=True, exist_ok=True)
    if state_candidate.is_symlink():
        raise Failure(f"refusing symlinked canary state root: {state_candidate}")
    state_root = contained_path(state_candidate, resolved_canary_root, "canary state root")
    support_parent = state_root / "Application Support"
    if support_parent.is_symlink():
        raise Failure(f"refusing symlinked canary Application Support root: {support_parent}")
    app_support = support_parent / "RemoteCodeAgentCanary"
    if app_support.is_symlink():
        raise Failure(f"refusing symlinked canary app support: {app_support}")
    return contained_path(app_support, state_root, "canary app support")


def reset_canary_app_support(canary_root):
    app_support = canary_app_support_path(canary_root)
    if not app_support.exists():
        return app_support
    if not app_support.is_dir():
        raise Failure(f"refusing non-directory canary app support reset: {app_support}")
    shutil.rmtree(app_support)
    return app_support


def listener_pids(port):
    result = subprocess.run(
        ["/usr/sbin/lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN", "-Fp"],
        text=True,
        capture_output=True,
    )
    if result.returncode not in (0, 1):
        raise Failure(f"could not inspect listener ownership for port {port}: {result.stderr.strip()}")
    return {
        int(line[1:])
        for line in result.stdout.splitlines()
        if line.startswith("p") and line[1:].isdigit()
    }


def wait_for_canary_listener(pid, canary_root):
    deadline = time.time() + 30
    while time.time() < deadline:
        if app_pid(canary_root) != pid:
            raise Failure(f"canary pid {pid} no longer maps to the exact canary executable")
        owners = listener_pids(PORT)
        if owners == {pid}:
            return
        if owners and owners != {pid}:
            raise Failure(f"configured E2E port {PORT} is owned by unexpected pid(s) {sorted(owners)}")
        time.sleep(0.25)
    raise Failure(f"canary pid {pid} did not become the sole listener on port {PORT}")


def run_canary(action, canary_root, env):
    run([str(CANARY_SCRIPT), action], cwd=ROOT, env=env)


def file_descriptor_count(pid):
    result = subprocess.run(
        ["/usr/sbin/lsof", "-nP", "-a", "-p", str(pid), "-Ff"],
        text=True,
        capture_output=True,
    )
    if result.returncode != 0:
        raise Failure("could not sample app file descriptors")
    return sum(1 for line in result.stdout.splitlines() if line.startswith("f"))


def file_descriptor_type_counts(pid):
    """Count open FDs by lsof type only (no paths/names; diagnostic-only)."""
    result = subprocess.run(
        ["/usr/sbin/lsof", "-nP", "-a", "-p", str(pid), "-Fft"],
        text=True,
        capture_output=True,
    )
    if result.returncode != 0:
        raise Failure("could not sample app file descriptor types")
    counts = {}
    current_type = None
    for line in result.stdout.splitlines():
        if not line:
            continue
        code, value = line[0], line[1:]
        if code == "f":
            if current_type is not None:
                counts[current_type] = counts.get(current_type, 0) + 1
            current_type = "unknown"
        elif code == "t" and current_type is not None:
            current_type = value or "unknown"
    if current_type is not None:
        counts[current_type] = counts.get(current_type, 0) + 1
    return {key: counts[key] for key in sorted(counts)}


def file_descriptor_type_delta(before, after):
    keys = set(before or {}) | set(after or {})
    delta = {}
    for key in sorted(keys):
        change = int((after or {}).get(key, 0)) - int((before or {}).get(key, 0))
        if change:
            delta[key] = change
    return delta


def child_process_count(pid):
    result = subprocess.run(["ps", "-axo", "pid=,ppid="], text=True, capture_output=True)
    if result.returncode != 0:
        raise Failure("could not sample app child processes")
    children = {}
    for line in result.stdout.splitlines():
        parts = line.split()
        if len(parts) != 2:
            continue
        child, parent = (int(part) for part in parts)
        children.setdefault(parent, []).append(child)
    descendants = set()
    pending = list(children.get(pid, []))
    while pending:
        child = pending.pop()
        if child in descendants:
            continue
        descendants.add(child)
        pending.extend(children.get(child, []))
    return len(descendants)


def process_table():
    result = subprocess.run(
        ["ps", "-axo", "pid=,ppid=,pgid=,sess=,args="],
        text=True,
        capture_output=True,
    )
    if result.returncode != 0:
        raise Failure("could not inspect process sessions and groups")
    records = []
    for line in result.stdout.splitlines():
        parts = line.strip().split(maxsplit=4)
        if len(parts) < 4 or not all(part.lstrip("-").isdigit() for part in parts[:4]):
            continue
        records.append({
            "pid": int(parts[0]),
            "ppid": int(parts[1]),
            "pgid": int(parts[2]),
            "sid": int(parts[3]),
            "args": parts[4] if len(parts) == 5 else "",
        })
    return records


def owned_terminal_processes(session_ids, process_groups, marker):
    sessions = {int(value) for value in session_ids if int(value) > 0}
    groups = {int(value) for value in process_groups if int(value) > 0}
    return [
        record
        for record in process_table()
        if record["pid"] > 1 and (
            record["sid"] in sessions
            or record["pgid"] in groups
            or (marker and marker in record["args"])
        )
    ]


def wait_for_owned_process_marker(marker, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        matches = owned_terminal_processes((), (), marker)
        if matches:
            return matches
        time.sleep(0.1)
    raise Failure(f"terminal background process marker did not start: {marker}")


def cleanup_owned_process_marker(marker):
    if not marker:
        return
    try:
        matches = owned_terminal_processes((), (), marker)
    except Exception:
        return
    for record in matches:
        try:
            os.kill(record["pid"], signal.SIGKILL)
        except ProcessLookupError:
            pass


def process_rss_kb(pid):
    result = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], text=True, capture_output=True)
    if result.returncode != 0 or not result.stdout.strip():
        raise Failure("app process disappeared while sampling RSS")
    return int(float(result.stdout.strip()))


def process_resource_snapshot(pid):
    return {
        "rss_kb": process_rss_kb(pid),
        "fd_count": file_descriptor_count(pid),
        "child_process_count": child_process_count(pid),
    }


def wait_for_canary_duration(pid, canary_root, duration_seconds, phase):
    deadline = time.monotonic() + duration_seconds
    while time.monotonic() < deadline:
        if app_pid(canary_root) != pid:
            raise Failure(f"canary disappeared during {phase}")
        time.sleep(min(1, max(0.01, deadline - time.monotonic())))


def resource_counts_recovered(fd_count, child_count, baseline_fd_count, baseline_child_count):
    return fd_count <= baseline_fd_count and child_count <= baseline_child_count


def post_close_resources_recovered(
    rss_kb,
    fd_count,
    child_count,
    baseline_rss_kb,
    baseline_fd_count,
    baseline_child_count,
    owned_process_count=0,
):
    return (
        resource_counts_recovered(
            fd_count,
            child_count,
            baseline_fd_count,
            baseline_child_count,
        )
        and rss_kb <= baseline_rss_kb + MAX_POST_CLOSE_RSS_DELTA_KB
        and owned_process_count == 0
    )


def wait_for_resource_recovery(
    pid,
    baseline_rss_kb,
    baseline_fd_count,
    baseline_child_count,
    terminal_session_ids=(),
    terminal_process_groups=(),
    terminal_process_marker=None,
    timeout=30,
):
    deadline = time.monotonic() + timeout
    last_rss_kb = None
    last_fd_count = None
    last_child_count = None
    last_owned_processes = []
    while time.monotonic() < deadline:
        snapshot = process_resource_snapshot(pid)
        last_rss_kb = snapshot["rss_kb"]
        last_fd_count = snapshot["fd_count"]
        last_child_count = snapshot["child_process_count"]
        last_owned_processes = owned_terminal_processes(
            terminal_session_ids,
            terminal_process_groups,
            terminal_process_marker,
        )
        if post_close_resources_recovered(
            last_rss_kb,
            last_fd_count,
            last_child_count,
            baseline_rss_kb,
            baseline_fd_count,
            baseline_child_count,
            len(last_owned_processes),
        ):
            return {**snapshot, "owned_processes": []}
        time.sleep(0.5)
    raise Failure(
        "post-close resources did not recover to the pre-workspace baseline: "
        f"rss {last_rss_kb} > {baseline_rss_kb} + {MAX_POST_CLOSE_RSS_DELTA_KB} KiB, "
        f"fd {last_fd_count} > {baseline_fd_count}, or "
        f"children {last_child_count} > {baseline_child_count}, or owned terminal processes "
        f"remain {last_owned_processes}"
    )


def sample(pid, stats, surface_ids=()):
    if _MUTATION_CONTROL is None:
        raise Failure("soak sample requires an active mutation control websocket")
    _MUTATION_CONTROL.assert_active()
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
    fd_count = file_descriptor_count(pid)
    child_count = child_process_count(pid)
    stats["max_fd_count"] = max(stats["max_fd_count"], fd_count)
    stats["max_child_process_count"] = max(stats["max_child_process_count"], child_count)

    max_pending = 0
    history_failures = 0
    dropped_bytes = 0
    health_latency_ms = 0.0
    for surface_id in surface_ids:
        request_started = time.monotonic()
        health = rpc("surface.health", {"id": surface_id})
        health_latency_ms = max(health_latency_ms, (time.monotonic() - request_started) * 1000)
        if not health.get("process_alive", False):
            raise Failure(f"terminal {surface_id} died during soak: {health}")
        max_pending = max(max_pending, int(health.get("output_pending_bytes", 0)))
        history_failures += int(health.get("history_write_failures", 0))
        dropped_bytes += int(health.get("dropped_output_bytes", 0))
    stats["max_output_pending_bytes"] = max(stats["max_output_pending_bytes"], max_pending)
    stats["max_health_rpc_latency_ms"] = max(stats["max_health_rpc_latency_ms"], health_latency_ms)
    stats["max_observed_history_write_failures"] = max(
        stats["max_observed_history_write_failures"], history_failures
    )
    stats["max_observed_dropped_output_bytes"] = max(
        stats["max_observed_dropped_output_bytes"], dropped_bytes
    )
    stats["samples"].append({
        "elapsed_seconds": round(time.monotonic() - stats["soak_started_monotonic"], 3),
        "rss_kb": rss,
        "cpu_percent": cpu,
        "fd_count": fd_count,
        "child_process_count": child_count,
        "terminal_count": len(surface_ids),
        "max_output_pending_bytes": max_pending,
        "history_write_failures": history_failures,
        "dropped_output_bytes": dropped_bytes,
        "max_health_rpc_latency_ms": round(health_latency_ms, 3),
    })


def linear_slope_per_minute(samples):
    if len(samples) < 2:
        return 0.0
    x_values = [sample["elapsed_seconds"] / 60 for sample in samples]
    y_values = [sample["rss_kb"] for sample in samples]
    x_mean = statistics.fmean(x_values)
    y_mean = statistics.fmean(y_values)
    denominator = sum((value - x_mean) ** 2 for value in x_values)
    if denominator == 0:
        return 0.0
    return sum(
        (x_value - x_mean) * (y_value - y_mean)
        for x_value, y_value in zip(x_values, y_values)
    ) / denominator


def update_memory_evidence(stats):
    samples = stats["samples"]
    if not samples:
        return
    tail = samples[len(samples) // 2:]
    quarter = max(1, len(samples) // 4)
    previous_window = samples[-2 * quarter:-quarter] or samples[:quarter]
    final_window = samples[-quarter:]
    full_slope = linear_slope_per_minute(samples)
    tail_slope = linear_slope_per_minute(tail)
    tail_net_growth = tail[-1]["rss_kb"] - tail[0]["rss_kb"]
    plateau_delta = statistics.median(sample["rss_kb"] for sample in final_window) - statistics.median(
        sample["rss_kb"] for sample in previous_window
    )
    stats["rss_slope_kb_per_minute"] = round(full_slope, 3)
    stats["rss_tail_slope_kb_per_minute"] = round(tail_slope, 3)
    stats["rss_tail_net_growth_kb"] = tail_net_growth
    stats["rss_plateau_delta_kb"] = round(plateau_delta, 3)
    stats["rss_plateau_seen"] = (
        tail_slope <= MAX_RSS_TAIL_SLOPE_KB_PER_MINUTE
        and plateau_delta <= MAX_RSS_PLATEAU_DELTA_KB
        and tail_net_growth <= MAX_RSS_TAIL_NET_GROWTH_KB
    )
    stats["fd_count_delta"] = samples[-1]["fd_count"] - samples[0]["fd_count"]
    stats["child_process_count_delta"] = (
        samples[-1]["child_process_count"] - samples[0]["child_process_count"]
    )


def assert_stability_gate(stats, gate_name):
    update_memory_evidence(stats)
    if not stats.get("rss_plateau_seen", False):
        raise Failure(
            f"{gate_name} memory gate failed: tail slope "
            f"{stats.get('rss_tail_slope_kb_per_minute')} KiB/min, plateau delta "
            f"{stats.get('rss_plateau_delta_kb')} KiB, tail net growth "
            f"{stats.get('rss_tail_net_growth_kb')} KiB"
        )
    fd_delta = int(stats.get("fd_count_delta") or 0)
    if fd_delta > 0:
        raise Failure(f"{gate_name} sustained file descriptor growth: delta {fd_delta}")
    child_delta = int(stats.get("child_process_count_delta") or 0)
    if child_delta > 0:
        raise Failure(f"{gate_name} sustained child process growth: delta {child_delta}")
    dropped_bytes = int(stats.get("max_observed_dropped_output_bytes") or 0)
    if dropped_bytes > 0:
        raise Failure(f"{gate_name} terminal output loss: {dropped_bytes} dropped byte(s)")
    history_write_failures = int(stats.get("max_observed_history_write_failures") or 0)
    if history_write_failures > 0:
        raise Failure(
            f"{gate_name} history persistence failure: "
            f"{history_write_failures} failed write(s)"
        )


def workspace_surface(created):
    pane = created["layout"]["pane"]["_0"]
    surface = pane["surfaces"][0]
    return created["id"]["value"], surface["id"]["value"]


def listed_workspace_ids(value):
    items = value if isinstance(value, list) else (
        value.get("workspaces", []) if isinstance(value, dict) else []
    )
    result = set()
    for item in items:
        if not isinstance(item, dict):
            continue
        identifier = item.get("id")
        if isinstance(identifier, dict):
            identifier = identifier.get("value")
        if isinstance(identifier, str):
            result.add(identifier)
    return result


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


def assert_large_input_accepted(result):
    if not isinstance(result, dict) or result.get("accepted") is not True:
        raise Failure(f"large input must be accepted by a healthy terminal: {result}")


def deterministic_large_input_bytes(byte_count):
    if byte_count < 1:
        raise Failure("large input byte count must be at least 1")
    body_size = byte_count - 1
    chunks = []
    produced = 0
    index = 0
    while produced < body_size:
        line = (
            f"{index:08x}:{(index * 2654435761) & 0xFFFFFFFF:08x}:"
            f"RemoteCode-terminal-payload-{index % 997:03d}\n"
        ).encode("ascii")
        take = min(len(line), body_size - produced)
        chunks.append(line[:take])
        produced += take
        index += 1
    return b"".join(chunks) + b"\n"


def assert_alive(surface_id):
    health = rpc("surface.health", {"id": surface_id})
    if not health.get("alive"):
        raise Failure(f"expected alive terminal, got {health}")
    if health.get("input_accepting") is False:
        raise Failure(f"expected input accepting terminal, got {health}")
    return health


def wait_for_terminal_shell_pid(surface_id, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        health = assert_alive(surface_id)
        child_pid = health.get("child_pid")
        if isinstance(child_pid, (int, float)) and int(child_pid) > 0:
            return int(child_pid)
        time.sleep(0.1)
    raise Failure(f"terminal {surface_id} did not expose its shell pid")


def capture_terminal_diagnostics(surface_id):
    if not surface_id:
        return None
    try:
        health = rpc("surface.health", {"id": surface_id})
        snap = snapshot(surface_id)
        return {
            "health": health,
            "snapshot": {
                "complete": snap.get("complete"),
                "partial": snap.get("partial"),
                "partial_reason": snap.get("partial_reason"),
                "pending_bytes": snap.get("pending_bytes"),
                "source": snap.get("source"),
                "render_diagnostics": snap.get("render_diagnostics"),
            },
        }
    except Exception as exc:
        return {"error": str(exc)}


def open_websocket(since_seq=None, receive_buffer_size=None, stream_filter=None):
    key = base64.b64encode(os.urandom(16)).decode()
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    if receive_buffer_size is not None:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, receive_buffer_size)
    sock.settimeout(10)
    sock.connect(("127.0.0.1", PORT))
    since_header = f"X-RC2-Since-Seq: {since_seq}\r\n" if since_seq is not None else ""
    filter_header = f"X-RC2-WS-Filter: {stream_filter}\r\n" if stream_filter else ""
    request = (
        "GET /v1/ws HTTP/1.1\r\n"
        "Host: 127.0.0.1\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        f"{since_header}"
        f"{filter_header}"
        "\r\n"
    ).encode()
    sock.sendall(request)
    response = bytearray()
    while b"\r\n\r\n" not in response:
        chunk = sock.recv(4096)
        if not chunk:
            raise Failure("websocket closed during handshake")
        response.extend(chunk)
        if len(response) > 64 * 1024:
            raise Failure("websocket handshake exceeded 64 KiB")
    header, initial_frame_bytes = bytes(response).split(b"\r\n\r\n", 1)
    accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest())
    if b"101 Switching Protocols" not in header or accept not in header:
        raise Failure(f"websocket handshake failed: {header[:200]!r}")
    return sock, bytearray(initial_frame_bytes)


def decode_websocket_frame(buffer):
    if len(buffer) < 2:
        return None
    first, second = buffer[0], buffer[1]
    opcode = first & 0x0F
    masked = (second & 0x80) != 0
    payload_length = second & 0x7F
    offset = 2
    if payload_length == 126:
        if len(buffer) < offset + 2:
            return None
        payload_length = int.from_bytes(buffer[offset:offset + 2], "big")
        offset += 2
    elif payload_length == 127:
        if len(buffer) < offset + 8:
            return None
        payload_length = int.from_bytes(buffer[offset:offset + 8], "big")
        offset += 8
    if payload_length > 16 * 1024 * 1024:
        raise Failure(f"websocket frame exceeded 16 MiB: {payload_length}")
    mask = None
    if masked:
        if len(buffer) < offset + 4:
            return None
        mask = bytes(buffer[offset:offset + 4])
        offset += 4
    frame_end = offset + payload_length
    if len(buffer) < frame_end:
        return None
    payload = bytes(buffer[offset:frame_end])
    del buffer[:frame_end]
    if mask is not None:
        payload = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
    return opcode, payload


def wait_for_websocket_json(sock, buffer, predicate, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        frame = decode_websocket_frame(buffer)
        if frame is None:
            sock.settimeout(max(0.01, deadline - time.monotonic()))
            try:
                chunk = sock.recv(64 * 1024)
            except socket.timeout as exc:
                raise Failure("timed out waiting for reconnected websocket evidence") from exc
            if not chunk:
                raise Failure("reconnected websocket closed before matching evidence")
            buffer.extend(chunk)
            continue
        opcode, payload = frame
        if opcode == 0x8:
            raise Failure(f"reconnected websocket sent close frame: {payload[:200]!r}")
        if opcode not in (0x1, 0x2):
            continue
        try:
            value = json.loads(payload)
        except (UnicodeDecodeError, json.JSONDecodeError):
            continue
        if isinstance(value, dict) and predicate(value):
            return value
    raise Failure("reconnected websocket did not deliver matching evidence")


def send_masked_websocket_frame(sock, opcode, payload):
    payload = bytes(payload)
    length = len(payload)
    header = bytearray([0x80 | opcode])
    if length < 126:
        header.append(0x80 | length)
    elif length <= 0xFFFF:
        header.append(0x80 | 126)
        header.extend(length.to_bytes(2, "big"))
    else:
        header.append(0x80 | 127)
        header.extend(length.to_bytes(8, "big"))
    mask = os.urandom(4)
    masked = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
    sock.sendall(bytes(header) + mask + masked)


class MutationControlConnection:
    def __init__(self, sock, buffer, welcome):
        connection_id = welcome.get("connectionId")
        host_id = welcome.get("hostId")
        boot_epoch = welcome.get("bootEpoch")
        if not isinstance(connection_id, str) or not connection_id:
            raise Failure("mutation control welcome is missing connectionId")
        if not isinstance(host_id, str) or not host_id:
            raise Failure("mutation control welcome is missing hostId")
        if (
            not isinstance(boot_epoch, int)
            or isinstance(boot_epoch, bool)
            or boot_epoch < 0
        ):
            raise Failure("mutation control welcome has an invalid bootEpoch")
        self.sock = sock
        self.buffer = buffer
        self.connection_id = connection_id
        self.host_id = host_id
        self.boot_epoch = boot_epoch
        self.stop_event = threading.Event()
        self.failure = None
        self.failure_lock = threading.Lock()
        self.thread = threading.Thread(
            target=self._drain,
            name="terminal-e2e-mutation-control",
            daemon=True,
        )

    def start(self):
        self.thread.start()
        return self

    def _record_failure(self, message):
        with self.failure_lock:
            if self.failure is None:
                self.failure = message

    def _drain(self):
        try:
            while not self.stop_event.is_set():
                frame = decode_websocket_frame(self.buffer)
                if frame is None:
                    self.sock.settimeout(1)
                    try:
                        chunk = self.sock.recv(64 * 1024)
                    except socket.timeout:
                        continue
                    except OSError:
                        if self.stop_event.is_set():
                            return
                        raise
                    if not chunk:
                        raise Failure("mutation control websocket closed")
                    self.buffer.extend(chunk)
                    continue
                opcode, payload = frame
                if opcode == 0x8:
                    raise Failure(
                        f"mutation control websocket sent close frame: {payload[:200]!r}"
                    )
                if opcode == 0x9:
                    send_masked_websocket_frame(self.sock, 0xA, payload)
        except Exception as exc:
            if not self.stop_event.is_set():
                self._record_failure(str(exc))

    def request_identity(self):
        self.assert_active()
        return {
            "client_request_id": str(uuid.uuid4()),
            "connection_id": self.connection_id,
            "expected_host_id": self.host_id,
            "expected_boot_epoch": self.boot_epoch,
        }

    def assert_active(self):
        with self.failure_lock:
            failure = self.failure
        if failure is not None:
            raise Failure(f"mutation control websocket failed: {failure}")
        if not self.thread.is_alive():
            raise Failure("mutation control websocket reader is not active")

    def close(self):
        self.stop_event.set()
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            self.sock.close()
        except OSError:
            pass
        self.thread.join(timeout=2)
        if self.thread.is_alive():
            raise Failure("mutation control websocket reader did not stop")


def open_mutation_control():
    sock, buffer = open_websocket(
        since_seq=(1 << 63) - 1,
        receive_buffer_size=256 * 1024,
        stream_filter="cellular-safe",
    )
    try:
        welcome = wait_for_websocket_json(
            sock,
            buffer,
            lambda value: value.get("type") == "welcome",
        )
        return MutationControlConnection(sock, buffer, welcome).start()
    except Exception:
        sock.close()
        raise


class SlowWebSocketConnection:
    """Long-lived slow-event client used by the release soak.

    Stays registered through welcome + server-side client accounting by answering
    WebSocket pings while setup runs. After enter_slow_mode(), the reader stops
    draining so the server outbound path can back up under load. Does not log
    frame payloads.
    """

    def __init__(self, sock, buffer, welcome):
        connection_id = welcome.get("connectionId")
        if not isinstance(connection_id, str) or not connection_id:
            raise Failure("slow websocket welcome is missing connectionId")
        self.sock = sock
        self.buffer = buffer
        self.connection_id = connection_id
        self.welcome = welcome
        self.stop_event = threading.Event()
        self.slow_mode = threading.Event()
        self.failure = None
        self.failure_lock = threading.Lock()
        self.thread = threading.Thread(
            target=self._drain,
            name="terminal-e2e-slow-ws",
            daemon=True,
        )

    def start(self):
        self.thread.start()
        return self

    def _record_failure(self, message):
        with self.failure_lock:
            if self.failure is None:
                self.failure = message

    def _drain(self):
        try:
            while not self.stop_event.is_set():
                if self.slow_mode.is_set():
                    # Keep the TCP peer open without draining so the server can
                    # observe queue_full/write_failed under workload pressure.
                    self.stop_event.wait(0.25)
                    continue
                frame = decode_websocket_frame(self.buffer)
                if frame is None:
                    self.sock.settimeout(1)
                    try:
                        chunk = self.sock.recv(64 * 1024)
                    except socket.timeout:
                        continue
                    except OSError:
                        if self.stop_event.is_set() or self.slow_mode.is_set():
                            return
                        raise
                    if not chunk:
                        raise Failure("slow websocket closed before slow mode")
                    self.buffer.extend(chunk)
                    continue
                opcode, payload = frame
                if opcode == 0x8:
                    raise Failure("slow websocket sent close frame before slow mode")
                if opcode == 0x9:
                    send_masked_websocket_frame(self.sock, 0xA, payload)
        except Exception as exc:
            if not self.stop_event.is_set() and not self.slow_mode.is_set():
                self._record_failure(str(exc))

    def enter_slow_mode(self):
        self.assert_active()
        self.slow_mode.set()

    def assert_active(self):
        with self.failure_lock:
            failure = self.failure
        if failure is not None:
            raise Failure(f"slow websocket failed: {failure}")
        if self.slow_mode.is_set():
            return
        if not self.thread.is_alive():
            raise Failure("slow websocket reader is not active")

    def close(self):
        self.stop_event.set()
        self.slow_mode.set()
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            self.sock.close()
        except OSError:
            pass
        self.thread.join(timeout=2)
        if self.thread.is_alive():
            raise Failure("slow websocket reader did not stop")


def open_slow_ws():
    sock, buffer = open_websocket(receive_buffer_size=1024)
    try:
        welcome = wait_for_websocket_json(
            sock,
            buffer,
            lambda value: value.get("type") == "welcome",
        )
        return SlowWebSocketConnection(sock, buffer, welcome).start()
    except Exception:
        sock.close()
        raise


def host_connection_metrics():
    req = urllib.request.Request(f"{BASE}/v1/health", method="GET")
    with urllib.request.urlopen(req, timeout=5) as response:
        payload = json.loads(response.read())
    if not isinstance(payload, dict):
        raise Failure("/v1/health returned a non-object payload")
    connections = payload.get("connections")
    if not isinstance(connections, dict):
        raise Failure("/v1/health is missing connections metrics")
    try:
        active_clients = int(connections.get("active_clients"))
        total_queued_bytes = int(connections.get("total_queued_bytes") or 0)
        slow_client_drops = int(connections.get("slow_client_drops") or 0)
    except (TypeError, ValueError) as exc:
        raise Failure(f"/v1/health connections metrics are invalid: {connections}") from exc
    return {
        "active_clients": active_clients,
        "total_queued_bytes": total_queued_bytes,
        "slow_client_drops": slow_client_drops,
    }


def wait_for_active_websocket_clients(expected, timeout=15):
    if expected < 1:
        raise Failure("expected active websocket client count must be at least 1")
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        last = host_connection_metrics()
        if last["active_clients"] >= expected:
            return last
        time.sleep(0.05)
    raise Failure(
        f"expected at least {expected} active websocket client(s) before resource baseline; "
        f"last={last}"
    )


def recent(max_bytes=512):
    return rpc("events.recent", {"since_seq": 0, "max_bytes": max_bytes})


def observe_slow_ws_disconnect(stats):
    events = recent(max_bytes=256 * 1024).get("events", [])
    slow_count = sum(
        1 for event in events if event.get("kind") == "diagnostic.ws_slow_client"
    )
    stats["dropped_event_count"] = max(stats["dropped_event_count"], slow_count)
    stats["slow_ws_disconnect_seen"] = stats["slow_ws_disconnect_seen"] or slow_count > 0
    try:
        metrics = host_connection_metrics()
        stats["max_slow_client_drops"] = max(
            int(stats.get("max_slow_client_drops") or 0),
            int(metrics["slow_client_drops"]),
        )
        if metrics["slow_client_drops"] > 0:
            stats["slow_ws_disconnect_seen"] = True
    except Exception:
        # Diagnostic only; events.recent remains the primary evidence path.
        pass


def workload_duration_seconds():
    return RUN_SECONDS + WORKLOAD_STABILIZATION_SECONDS


def start_auxiliary_workload(surface_id, index, workload_trigger_python_path):
    mode = (index - 2) % 4
    if mode == 0:
        command = (
            "python3 - <<'PY'\n"
            "from pathlib import Path\n"
            "import time\n"
            f"trigger=Path({workload_trigger_python_path})\n"
            f"print('RC2_AUX_{index:02d}_READY', flush=True)\n"
            "while not trigger.exists():\n"
            "    time.sleep(0.01)\n"
            f"end=time.monotonic()+{workload_duration_seconds()}\n"
            "i=0\n"
            "while time.monotonic()<end:\n"
            f"    print(f'RC2_AUX_{index:02d}_STREAM_{{i:06d}}', flush=True)\n"
            "    i+=1\n"
            "    time.sleep(0.025)\n"
            f"print('RC2_AUX_{index:02d}_DONE', flush=True)\n"
            "PY\n"
        )
        workload = "stream"
    elif mode == 1:
        command = (
            "python3 - <<'PY'\n"
            "from pathlib import Path\n"
            "import sys, time\n"
            f"trigger=Path({workload_trigger_python_path})\n"
            f"print('RC2_AUX_{index:02d}_READY', flush=True)\n"
            "while not trigger.exists():\n"
            "    time.sleep(0.01)\n"
            "sys.stdout.write('\\x1b[?1049h')\n"
            f"end=time.monotonic()+{workload_duration_seconds()}\n"
            "i=0\n"
            "while time.monotonic()<end:\n"
            f"    sys.stdout.write('\\x1b[HRC2_AUX_{index:02d}_TUI_%06d\\n' % i)\n"
            "    sys.stdout.flush()\n"
            "    i+=1\n"
            "    time.sleep(0.1)\n"
            f"sys.stdout.write('\\x1b[?1049lRC2_AUX_{index:02d}_DONE\\n')\n"
            "sys.stdout.flush()\n"
            "PY\n"
        )
        workload = "tui"
    elif mode == 2:
        command = (
            "python3 - <<'PY'\n"
            "from pathlib import Path\n"
            "import time\n"
            f"trigger=Path({workload_trigger_python_path})\n"
            f"print('RC2_AUX_{index:02d}_READY', flush=True)\n"
            "while not trigger.exists():\n"
            "    time.sleep(0.01)\n"
            f"time.sleep({workload_duration_seconds()})\n"
            f"print('RC2_AUX_{index:02d}_DONE', flush=True)\n"
            "PY\n"
        )
        workload = "idle"
    else:
        command = (
            "python3 - <<'PY'\n"
            "from pathlib import Path\n"
            "import time\n"
            f"trigger=Path({workload_trigger_python_path})\n"
            f"print('RC2_AUX_{index:02d}_READY', flush=True)\n"
            "while not trigger.exists():\n"
            "    time.sleep(0.01)\n"
            f"end=time.monotonic()+{workload_duration_seconds()}\n"
            "burst=0\n"
            "while time.monotonic()<end:\n"
            "    for line in range(50):\n"
            f"        print(f'RC2_AUX_{index:02d}_BURST_{{burst:05d}}_{{line:03d}}')\n"
            "    burst+=1\n"
            "    time.sleep(1)\n"
            f"print('RC2_AUX_{index:02d}_DONE', flush=True)\n"
            "PY\n"
        )
        workload = "burst"
    send_text(surface_id, command)
    return workload


def effective_configuration(args):
    return {
        "canary_root": str(args.canary_root.resolve()) if args.canary_root else None,
        "client_warmup_seconds": args.client_warmup_seconds,
        "diagnostic_only_metrics": list(DIAGNOSTIC_ONLY_METRICS),
        "duration_seconds": args.duration_seconds,
        "ios_ui_coverage": "NOT_RUN",
        "no_build": args.no_build,
        "port": args.port,
        "pre_gate_seconds": args.pre_gate_seconds,
        "profile": "release-soak" if args.release_soak else "custom-smoke",
        "require_slow_ws": args.require_slow_ws,
        "sample_interval_seconds": args.sample_interval_seconds,
        "terminal_count": args.terminal_count,
        "workload_command_seconds": (
            args.duration_seconds + args.workload_stabilization_seconds
        ),
        "workload_stabilization_seconds": args.workload_stabilization_seconds,
    }


def public_stats(stats):
    return {key: value for key, value in stats.items() if key != "soak_started_monotonic"}


def main():
    global _MUTATION_CONTROL
    args = parse_args()
    configure(args)
    validate_configuration(args)
    if args.validate_only:
        print(json.dumps(effective_configuration(args), sort_keys=True))
        return
    refuse_unsafe_target()
    start = time.time()
    owns_canary_root = args.canary_root is None
    canary_root = validated_canary_root(
        Path(tempfile.mkdtemp(prefix="RemoteCodeAgentCanary-terminal-e2e-"))
        if owns_canary_root
        else args.canary_root.resolve()
    )
    refuse_running_canary(canary_root)
    primary_sid = None
    hidden_sid = None
    all_workspace_ids = []
    all_surface_ids = []
    terminal_session_ids = set()
    terminal_process_groups = set()
    stats = {
        "status": "PASS",
        "scope": "isolated macOS host plus RPC/event mirror seam",
        "ios_ui_coverage": "NOT_RUN",
        "duration_seconds": 0,
        "configured_run_seconds": RUN_SECONDS,
        "configured_terminal_count": TERMINAL_COUNT,
        "configured_pre_gate_seconds": PRE_GATE_SECONDS,
        "configured_sample_interval_seconds": SAMPLE_INTERVAL_SECONDS,
        "configured_client_warmup_seconds": CLIENT_WARMUP_SECONDS,
        "configured_workload_stabilization_seconds": WORKLOAD_STABILIZATION_SECONDS,
        "workload_command_seconds": workload_duration_seconds(),
        "measured_soak_seconds": None,
        "diagnostic_only_metrics": list(DIAGNOSTIC_ONLY_METRICS),
        "gate_thresholds": {
            "max_rss_kb": MAX_RSS_KB,
            "max_rss_tail_slope_kb_per_minute": MAX_RSS_TAIL_SLOPE_KB_PER_MINUTE,
            "max_rss_plateau_delta_kb": MAX_RSS_PLATEAU_DELTA_KB,
            "max_rss_tail_net_growth_kb": MAX_RSS_TAIL_NET_GROWTH_KB,
            "max_post_close_rss_delta_kb": MAX_POST_CLOSE_RSS_DELTA_KB,
            "max_fd_count_delta": 0,
            "max_child_process_count_delta": 0,
            "max_observed_dropped_output_bytes": 0,
        },
        "release_soak": args.release_soak,
        "listener_owner_pid_verified": False,
        "fresh_app_support_reset": False,
        "client_warmup_completed": False,
        "workload_stabilization_completed": False,
        "pre_gate_passed": PRE_GATE_SECONDS == 0,
        "pre_gate_elapsed_seconds": None,
        "max_rss_kb": 0,
        "max_cpu_percent": 0.0,
        "max_fd_count": 0,
        "max_child_process_count": 0,
        "max_output_pending_bytes": 0,
        "max_health_rpc_latency_ms": 0.0,
        "max_observed_history_write_failures": 0,
        "max_observed_dropped_output_bytes": 0,
        "rss_slope_kb_per_minute": None,
        "rss_tail_slope_kb_per_minute": None,
        "rss_tail_net_growth_kb": None,
        "rss_plateau_delta_kb": None,
        "rss_plateau_seen": False,
        "fd_count_delta": None,
        "child_process_count_delta": None,
        "samples": [],
        "soak_started_monotonic": 0.0,
        "workloads": [],
        "disconnect_count": 0,
        "dropped_event_count": 0,
        "slow_ws_disconnect_seen": False,
        "slow_ws_reconnect_seen": False,
        "slow_ws_welcome_seen": False,
        "slow_ws_live_event_seen": False,
        "slow_ws_slow_mode_entered": False,
        "connected_clients_ready": False,
        "pre_baseline_active_clients": None,
        "pre_baseline_fd_type_counts": None,
        "max_slow_client_drops": 0,
        "baseline_required_seen": False,
        "baseline_converged_after_reconnect": False,
        "hidden_partial_seen": False,
        "hidden_producer_completed": False,
        "hidden_output_drained": False,
        "workspace_tui_return_input_seen": False,
        "post_idle_input_seen": False,
        "render_diagnostics_seen": False,
        "large_input_bytes": LARGE_INPUT_BYTES,
        "large_input_expected_sha256": None,
        "large_input_sha256_seen": False,
        "large_input_accepted": False,
        "large_input_exact_bytes_seen": False,
        "tui_seconds": TUI_SECONDS,
        "child_exit_dead_seen": False,
        "app_alive_after_child_exit": False,
        "post_close_resources_recovered": False,
        "post_close_owned_terminal_processes": None,
        "pre_workspace_rss_kb": None,
        "pre_workspace_fd_count": None,
        "pre_workspace_child_process_count": None,
        "post_close_rss_kb": None,
        "post_close_rss_delta_kb": None,
        "post_close_fd_count": None,
        "post_close_child_process_count": None,
    }
    slow_sock = None
    mutation_control = None
    canary_started = False
    canary_env = os.environ.copy()
    state_root = None
    run_artifact_root = None
    workspace_tui_path = None
    large_input_path = None
    workload_trigger_path = None
    hidden_flood_done_path = None
    terminal_process_marker = None
    try:
        (
            state_root,
            run_artifact_root,
            workspace_tui_path,
            large_input_path,
            workload_trigger_path,
            hidden_flood_done_path,
        ) = prepare_run_artifacts(canary_root)
        isolated_home = state_root / "home"
        isolated_home.mkdir(parents=True, exist_ok=True)
        (isolated_home / ".codex").mkdir(parents=True, exist_ok=True)
        workspace_tui_shell_path = shell_quote_contained_path(
            workspace_tui_path,
            run_artifact_root,
            "workspace TUI artifact",
        )
        large_input_shell_path = shell_quote_contained_path(
            large_input_path,
            run_artifact_root,
            "large input artifact",
        )
        large_input_python_path = repr(str(large_input_path))
        workload_trigger_python_path = repr(str(workload_trigger_path))
        hidden_flood_done_python_path = repr(str(hidden_flood_done_path))
        canary_env["RC2_CANARY_ROOT"] = str(canary_root)
        canary_env["RC2_HTTP_PORT"] = str(PORT)
        canary_env["RC2_ENABLE_GHOSTTY_IN_TESTS"] = "1"
        canary_env["RC2_SPARKLE_PUBLIC_ED_KEY"] = ""
        canary_env["XCTestConfigurationFilePath"] = str(state_root / "xctest-isolation-sentinel")
        canary_env["HOME"] = str(isolated_home)
        canary_env["ZDOTDIR"] = str(isolated_home)
        canary_env["HISTFILE"] = str(isolated_home / ".zsh_history")
        canary_env["CODEX_HOME"] = str(isolated_home / ".codex")
        if args.no_build:
            executable = (
                canary_root / "app" / "RemoteCodeAgentCanary.app"
                / "Contents" / "MacOS" / "RemoteCodeAgentCanary"
            )
            if not os.access(executable, os.X_OK):
                raise Failure(f"--no-build canary executable is missing or not executable: {executable}")
        else:
            run_canary("build", canary_root, canary_env)
        reset_canary_app_support(canary_root)
        stats["fresh_app_support_reset"] = True
        refuse_running_canary(canary_root)
        run_canary("run", canary_root, canary_env)
        canary_started = True
        pid = app_pid(canary_root)
        if pid is None:
            raise Failure("app process missing after launch")
        wait_for_canary_listener(pid, canary_root)
        stats["listener_owner_pid_verified"] = True
        stats["canary_pid"] = pid
        wait_for_host()

        mutation_control = open_mutation_control()
        _MUTATION_CONTROL = mutation_control
        slow_sock = open_slow_ws()
        stats["slow_ws_welcome_seen"] = True
        # Fail fast once both long-lived clients are welcome-ready and
        # server-registered. The soak FD baseline is gated again below.
        wait_for_active_websocket_clients(2)
        stats["connected_clients_ready"] = True
        wait_for_canary_duration(
            pid,
            canary_root,
            CLIENT_WARMUP_SECONDS,
            "connected-client warmup",
        )
        mutation_control.assert_active()
        slow_sock.assert_active()
        stats["client_warmup_completed"] = True
        wait_for_canary_duration(
            pid,
            canary_root,
            WORKLOAD_STABILIZATION_SECONDS,
            "pre-workspace baseline stabilization",
        )
        pre_workspace_resources = process_resource_snapshot(pid)
        if pre_workspace_resources["rss_kb"] > MAX_RSS_KB:
            raise Failure(
                "pre-workspace RSS exceeded cap: "
                f"{pre_workspace_resources['rss_kb']} > {MAX_RSS_KB}"
            )
        stats["pre_workspace_rss_kb"] = pre_workspace_resources["rss_kb"]
        stats["pre_workspace_fd_count"] = pre_workspace_resources["fd_count"]
        stats["pre_workspace_child_process_count"] = pre_workspace_resources[
            "child_process_count"
        ]

        primary = rpc("workspace.create", {"name": "E2EPrimary", "cwd": "/tmp"})
        primary_wid, primary_sid = workspace_surface(primary)
        all_workspace_ids.append(primary_wid)
        all_surface_ids.append(primary_sid)
        hidden = rpc("workspace.create", {"name": "E2EHidden", "cwd": "/tmp"})
        hidden_wid, hidden_sid = workspace_surface(hidden)
        all_workspace_ids.append(hidden_wid)
        all_surface_ids.append(hidden_sid)
        for index in range(2, TERMINAL_COUNT):
            created = rpc("workspace.create", {"name": f"E2EAux{index:02d}", "cwd": "/tmp"})
            workspace_id, surface_id = workspace_surface(created)
            all_workspace_ids.append(workspace_id)
            all_surface_ids.append(surface_id)
        terminal_session_ids = {
            wait_for_terminal_shell_pid(surface_id)
            for surface_id in all_surface_ids
        }
        if len(terminal_session_ids) != TERMINAL_COUNT:
            raise Failure(
                "terminal shell session identities were not unique: "
                f"{sorted(terminal_session_ids)}"
            )
        rpc("workspace.select", {"id": primary_wid})

        send_text(hidden_sid, (
            "python3 - <<'PY'\n"
            "from pathlib import Path\n"
            f"for i in range({HIDDEN_LINES}):\n"
            "    print(f'RC2_E2E_HIDDEN_{i:06d}_abcdefghijklmnopqrstuvwxyz0123456789')\n"
            "print('RC2_E2E_HIDDEN_DONE', flush=True)\n"
            f"Path({hidden_flood_done_python_path}).write_text('done\\n')\n"
            "PY\n"
        ))
        wait_for_exact_file(
            hidden_flood_done_path,
            "done\n",
            timeout=30,
            description="hidden terminal producer completion",
        )
        stats["hidden_producer_completed"] = True
        observe_slow_ws_disconnect(stats)

        send_text(primary_sid, (
            "python3 - <<'PY'\n"
            "from pathlib import Path\n"
            "import time\n"
            f"trigger=Path({workload_trigger_python_path})\n"
            "print('RC2_E2E_STREAM_READY', flush=True)\n"
            "while not trigger.exists():\n"
            "    time.sleep(0.01)\n"
            f"end=time.monotonic()+{workload_duration_seconds()}\n"
            "i=0\n"
            "while time.monotonic()<end:\n"
            "    print(f'RC2_E2E_STREAM_{i:06d}', flush=True)\n"
            "    i+=1\n"
            "    time.sleep(0.01)\n"
            "print('RC2_E2E_STREAM_DONE', flush=True)\n"
            "PY\n"
        ))
        stats["workloads"] = ["stream", "hidden-flood"]
        for index, surface_id in enumerate(all_surface_ids[2:], start=2):
            stats["workloads"].append(start_auxiliary_workload(
                surface_id,
                index,
                workload_trigger_python_path,
            ))

        wait_snapshot_contains(primary_sid, "RC2_E2E_STREAM_READY", timeout=30)
        for index, surface_id in enumerate(all_surface_ids[2:], start=2):
            wait_snapshot_contains(surface_id, f"RC2_AUX_{index:02d}_READY", timeout=30)
        workload_trigger_path.write_text("start\n")
        wait_for_canary_duration(
            pid,
            canary_root,
            WORKLOAD_STABILIZATION_SECONDS,
            "workload stabilization",
        )
        stats["workload_stabilization_completed"] = True

        # Re-verify long-lived clients immediately before the first soak sample
        # (resource baseline). Fail setup rather than measuring an incomplete
        # baseline or retaking the baseline after growth is observed.
        mutation_control.assert_active()
        slow_sock.assert_active()
        ready_metrics = wait_for_active_websocket_clients(2)
        stats["pre_baseline_active_clients"] = ready_metrics["active_clients"]
        stats["pre_baseline_fd_type_counts"] = file_descriptor_type_counts(pid)
        stats["connected_clients_ready"] = True
        # Stop draining only after readiness is proven so the soak baseline
        # includes the intended slow-client socket FD.
        slow_sock.enter_slow_mode()
        stats["slow_ws_slow_mode_entered"] = True

        stats["soak_started_monotonic"] = time.monotonic()
        soak_deadline = stats["soak_started_monotonic"] + RUN_SECONDS
        next_sample = stats["soak_started_monotonic"]
        pre_gate_deadline = (
            stats["soak_started_monotonic"] + PRE_GATE_SECONDS
            if PRE_GATE_SECONDS > 0
            else None
        )
        while time.monotonic() < soak_deadline:
            now = time.monotonic()
            if now >= next_sample:
                sample(pid, stats, all_surface_ids)
                if REQUIRE_SLOW_WS and not stats["slow_ws_disconnect_seen"]:
                    observe_slow_ws_disconnect(stats)
                next_sample = now + SAMPLE_INTERVAL_SECONDS
            if pre_gate_deadline is not None and now >= pre_gate_deadline:
                assert_stability_gate(stats, "pre-gate")
                stats["pre_gate_passed"] = True
                stats["pre_gate_elapsed_seconds"] = round(
                    now - stats["soak_started_monotonic"], 3
                )
                pre_gate_deadline = None
            time.sleep(min(0.25, max(0.01, soak_deadline - time.monotonic())))
        stats["measured_soak_seconds"] = round(
            time.monotonic() - stats["soak_started_monotonic"],
            3,
        )
        sample(pid, stats, all_surface_ids)
        assert_stability_gate(stats, "post-soak")
        wait_snapshot_contains(primary_sid, "RC2_E2E_STREAM_DONE")
        for index, surface_id in enumerate(all_surface_ids[2:], start=2):
            wait_snapshot_contains(surface_id, f"RC2_AUX_{index:02d}_DONE", timeout=15)
            assert_alive(surface_id)
        stats["terminals_alive_after_soak"] = sum(
            1 for surface_id in all_surface_ids if assert_alive(surface_id).get("process_alive")
        )
        if stats["terminals_alive_after_soak"] != TERMINAL_COUNT:
            raise Failure(
                f"only {stats['terminals_alive_after_soak']} of {TERMINAL_COUNT} terminals survived the soak"
            )
        if stats["max_observed_history_write_failures"] != 0:
            raise Failure(
                f"history persistence reported {stats['max_observed_history_write_failures']} write failures"
            )
        primary_health = assert_alive(primary_sid)
        if isinstance(primary_health.get("render_diagnostics"), dict):
            stats["render_diagnostics_seen"] = True
        post_idle_started = time.monotonic()
        send_text(primary_sid, "printf 'RC2_POST_IDLE_INPUT_OK\\n'\n")
        wait_snapshot_contains(primary_sid, "RC2_POST_IDLE_INPUT_OK", timeout=10)
        stats["post_idle_input_seen"] = True
        stats["post_idle_output_roundtrip_ms"] = round(
            (time.monotonic() - post_idle_started) * 1000, 3
        )

        hidden_health = rpc("surface.health", {"id": hidden_sid})
        hidden_snap = snapshot(hidden_sid)
        if hidden_health.get("output_partial") or hidden_snap.get("complete") is False or hidden_snap.get("partial"):
            stats["hidden_partial_seen"] = True
        else:
            raise Failure(f"hidden output did not report honest partial state: health={hidden_health} snapshot={hidden_snap}")
        rpc("workspace.select", {"id": hidden_wid})
        wait_snapshot_contains(hidden_sid, "RC2_E2E_HIDDEN_DONE", timeout=30)
        stats["hidden_output_drained"] = True
        rpc("workspace.select", {"id": primary_wid})

        send_text(primary_sid, (
            "stty -echo\n"
            f"cat >{workspace_tui_shell_path} <<'SH'\n"
            "printf '\\033[?1049h'\n"
            "printf 'RC2_TUI_RUNTIME_READY\\n'\n"
            "sleep 3\n"
            "printf '\\033[?1049lRC2_TUI_WORKSPACE_RETURN_DONE\\n'\n"
            "SH\n"
            "stty echo\n"
            f"sh {workspace_tui_shell_path}\n"
        ))
        wait_snapshot_contains(primary_sid, "RC2_TUI_RUNTIME_READY", timeout=10)
        rpc("workspace.select", {"id": hidden_wid})
        send_text(hidden_sid, "ls; printf 'RC2_OTHER_WORKSPACE_LS_OK\\n'\n")
        time.sleep(5)
        wait_snapshot_contains(hidden_sid, "RC2_OTHER_WORKSPACE_LS_OK", timeout=10)
        rpc("workspace.select", {"id": primary_wid})
        wait_snapshot_contains(primary_sid, "RC2_TUI_WORKSPACE_RETURN_DONE", timeout=10)
        send_text(primary_sid, "printf 'RC2_TUI_PROGRESS_INPUT:how is the progress?\\n'\n")
        wait_snapshot_contains(primary_sid, "RC2_TUI_PROGRESS_INPUT:how is the progress?", timeout=10)
        stats["workspace_tui_return_input_seen"] = True

        expected_large_input = deterministic_large_input_bytes(LARGE_INPUT_BYTES)
        expected_large_input_sha256 = hashlib.sha256(expected_large_input).hexdigest()
        stats["large_input_expected_sha256"] = expected_large_input_sha256
        payload = expected_large_input[:-1].decode("ascii")
        large_command = (
            "stty -echo\n"
            f"cat >{large_input_shell_path} <<'RC2EOF'\n"
            f"{payload}\n"
            "RC2EOF\n"
            "python3 - <<'PY'\n"
            "import hashlib\n"
            "from pathlib import Path\n"
            f"p=Path({large_input_python_path})\n"
            "data=p.read_bytes()\n"
            "print(f'RC2_LARGE_INPUT_BYTES:{len(data)}')\n"
            "print(f'RC2_LARGE_INPUT_SHA256:{hashlib.sha256(data).hexdigest()}')\n"
            "PY\n"
            "stty echo\n"
        )
        large_result = send_text(primary_sid, large_command)
        assert_large_input_accepted(large_result)
        stats["large_input_accepted"] = True
        wait_snapshot_contains(
            primary_sid,
            f"RC2_LARGE_INPUT_BYTES:{LARGE_INPUT_BYTES}",
            timeout=60,
        )
        stats["large_input_exact_bytes_seen"] = True
        wait_snapshot_contains(
            primary_sid,
            f"RC2_LARGE_INPUT_SHA256:{expected_large_input_sha256}",
            timeout=60,
        )
        stats["large_input_sha256_seen"] = True

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

        time.sleep(6)
        observe_slow_ws_disconnect(stats)
        if REQUIRE_SLOW_WS and not stats["slow_ws_disconnect_seen"]:
            raise Failure("slow websocket diagnostic was not observed")
        if stats["slow_ws_disconnect_seen"]:
            reconnect_cursor = int(recent(max_bytes=256 * 1024).get("last_seq", 0))
            previous_slow = slow_sock
            slow_sock = None
            if previous_slow is not None:
                previous_slow.close()
            reconnect_sock, reconnect_buffer = open_websocket(
                since_seq=reconnect_cursor,
                receive_buffer_size=256 * 1024,
            )
            # Raw reconnect socket (not SlowWebSocketConnection). Assign only
            # after open so finally cleanup owns it if welcome/live waits fail.
            slow_sock = reconnect_sock
            wait_for_websocket_json(
                reconnect_sock,
                reconnect_buffer,
                lambda value: (
                    value.get("type") == "welcome"
                    and int(value.get("currentSequence", -1)) >= reconnect_cursor
                ),
            )
            stats["slow_ws_welcome_seen"] = True
            rpc("workspace.select", {"id": hidden_wid})
            wait_for_websocket_json(
                reconnect_sock,
                reconnect_buffer,
                lambda value: (
                    value.get("type") == "event"
                    and value.get("kind") == "workspace.selected"
                    and isinstance(value.get("payload"), dict)
                    and value["payload"].get("workspace_id") == hidden_wid
                    and int(value.get("sequence", 0)) > reconnect_cursor
                ),
            )
            stats["slow_ws_live_event_seen"] = True
            stats["slow_ws_reconnect_seen"] = True
            rpc("workspace.select", {"id": primary_wid})

        baseline = recent(max_bytes=64)
        if baseline.get("requires_baseline"):
            stats["baseline_required_seen"] = True
        else:
            raise Failure(f"events.recent did not require baseline under tiny replay cap: {baseline}")
        if stats["slow_ws_disconnect_seen"]:
            present_workspace_ids = listed_workspace_ids(rpc("workspace.list"))
            if present_workspace_ids != set(all_workspace_ids):
                raise Failure(
                    "workspace baseline did not converge after slow-client reconnect: "
                    f"expected {sorted(all_workspace_ids)}, got {sorted(present_workspace_ids)}"
                )
            for surface_id in all_surface_ids:
                assert_alive(surface_id)
            stats["baseline_converged_after_reconnect"] = True

        sample(pid, stats, all_surface_ids)
        assert_stability_gate(stats, "pre-exit")
        terminal_process_marker = (
            "RC2_E2E_BG_"
            + hashlib.sha256(str(run_artifact_root).encode()).hexdigest()[:16]
        )
        background_lifetime = workload_duration_seconds() + 900
        send_text(primary_sid, (
            "python3 -c \"import signal,time; "
            "signal.signal(signal.SIGHUP, signal.SIG_IGN); "
            "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
            f"time.sleep({background_lifetime})\" "
            f"{shlex.quote(terminal_process_marker)} &\n"
            "printf 'RC2_E2E_BACKGROUND_READY:%s\\n' $!\n"
        ))
        wait_snapshot_contains(primary_sid, "RC2_E2E_BACKGROUND_READY:", timeout=10)
        marker_processes = wait_for_owned_process_marker(terminal_process_marker)
        active_session_processes = owned_terminal_processes(
            terminal_session_ids,
            (),
            terminal_process_marker,
        )
        terminal_process_groups = {
            record["pgid"]
            for record in marker_processes + active_session_processes
            if record["pgid"] > 0
        }
        send_text(primary_sid, "exit\n")
        time.sleep(1)
        dead = rpc("surface.health", {"id": primary_sid})
        if dead.get("alive") is not False or dead.get("terminal_dead_reason") != "process_exited":
            raise Failure(f"child exit did not mark dead: {dead}")
        stats["child_exit_dead_seen"] = True
        after_exit = send_text(primary_sid, "pwd\n")
        if after_exit.get("accepted") is not False or after_exit.get("status") != "process_exited":
            raise Failure(f"send after exit was not explicit process_exited: {after_exit}")
        stats["app_alive_after_child_exit"] = app_pid(canary_root) is not None
        for workspace_id in all_workspace_ids:
            rpc("workspace.close", {"id": workspace_id})
        recovered = wait_for_resource_recovery(
            pid,
            pre_workspace_resources["rss_kb"],
            pre_workspace_resources["fd_count"],
            pre_workspace_resources["child_process_count"],
            terminal_session_ids=terminal_session_ids,
            terminal_process_groups=terminal_process_groups,
            terminal_process_marker=terminal_process_marker,
        )
        stats["post_close_rss_kb"] = recovered["rss_kb"]
        stats["post_close_rss_delta_kb"] = (
            recovered["rss_kb"] - pre_workspace_resources["rss_kb"]
        )
        stats["post_close_fd_count"] = recovered["fd_count"]
        stats["post_close_child_process_count"] = recovered["child_process_count"]
        stats["post_close_owned_terminal_processes"] = len(recovered["owned_processes"])
        stats["post_close_resources_recovered"] = True
        assert_stability_gate(stats, "final")
        stats["duration_seconds"] = int(time.time() - start)
        print(json.dumps(public_stats(stats), sort_keys=True))
    except Exception as exc:
        stats["status"] = "FAIL"
        stats["error"] = str(exc)
        failure_diagnostics = {
            "primary": capture_terminal_diagnostics(primary_sid),
            "hidden": capture_terminal_diagnostics(hidden_sid),
        }
        try:
            if stats.get("canary_pid"):
                current_types = file_descriptor_type_counts(stats["canary_pid"])
                failure_diagnostics["fd_type_counts"] = current_types
                failure_diagnostics["fd_type_delta_from_pre_baseline"] = (
                    file_descriptor_type_delta(
                        stats.get("pre_baseline_fd_type_counts"),
                        current_types,
                    )
                )
        except Exception as diagnostic_exc:
            failure_diagnostics["fd_type_error"] = str(diagnostic_exc)
        stats["failure_diagnostics"] = failure_diagnostics
        update_memory_evidence(stats)
        stats["duration_seconds"] = int(time.time() - start)
        print(json.dumps(public_stats(stats), sort_keys=True), file=sys.stderr)
        raise
    finally:
        if slow_sock is not None:
            try:
                slow_sock.close()
            except Exception:
                pass
        try:
            if mutation_control is not None:
                mutation_control.close()
        finally:
            _MUTATION_CONTROL = None
            try:
                if canary_started:
                    run_canary("stop", canary_root, canary_env)
            finally:
                try:
                    cleanup_owned_process_marker(terminal_process_marker)
                finally:
                    try:
                        cleanup_run_artifacts(run_artifact_root, state_root)
                    finally:
                        if owns_canary_root:
                            shutil.rmtree(canary_root, ignore_errors=True)


if __name__ == "__main__":
    main()
