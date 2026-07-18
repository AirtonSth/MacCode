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
# Same-process open/close cycles after the primary workload. Cycle 1 records the
# post-close warmed baseline; cycles 2..N must recover to that warmed baseline
# (no stacking). Cold pre-workspace delta remains diagnostic only.
RESOURCE_CLOSE_CYCLES = int(os.environ.get("RC2_E2E_RESOURCE_CLOSE_CYCLES", "2"))
REQUIRE_SLOW_WS = os.environ.get("RC2_E2E_REQUIRE_SLOW_WS", "0") == "1"
CANARY_ROOT_PREFIX = "RemoteCodeAgentCanary-"
RUN_ARTIFACT_PREFIX = "terminal-stability-e2e-"
DIAGNOSTIC_ONLY_METRICS = (
    "max_cpu_percent",
    "max_health_rpc_latency_ms",
    "post_idle_output_roundtrip_ms",
    # Post-soak materialization changes RSS/FD relative to the frozen soak end;
    # deltas are reported for diagnosis only. Gates use absolute MAX_RSS_KB,
    # zero sustained FD growth during soak, process-tree cleanup after close,
    # and cycle-to-cycle warmed recovery (cold pre-workspace delta is diagnostic).
    "post_soak_transition_rss_delta_kb",
    "post_soak_transition_fd_delta",
    "post_close_rss_delta_from_cold_kb",
    "post_close_fd_delta_from_cold",
    "post_close_cold_rss_within_budget",
    "post_close_cold_fd_recovered",
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


def parse_args(argv=None):
    parser = argparse.ArgumentParser(
        description="Run the terminal stability suite against an isolated RemoteCode canary.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Safe defaults: 2 terminals for 120 seconds on port 28217.
Release gate: --release-soak enforces 12 terminals for 60 minutes, a 15-minute pre-gate,
and a 30-second connected-client warmup before workload startup.

Memory-gate semantics (unchanged thresholds):
  Plateau / tail-slope / tail-net use the second half of the full soak sample
  window (not a rebaseline after --pre-gate-seconds). Pre-gate is an intermediate
  health+memory check only; it does not discard early samples from post-soak.
  Continuous stream + Ghostty scrollback fill produces step-wise RSS growth early
  in the soak. Short pre-gate=0 runs that end during that fill (e.g. 15-180s)
  will false-fail the memory gate and must not be labeled as a continuing leak.
  To prove plateau: duration must be long enough that the second half is past
  warmup (release uses 4500s with 900s pre-gate). Absolute MAX_RSS_KB still
  bounds total process size under product caps (ANSI ring, history retention,
  hidden mirror force-flush, Ghostty scrollback-limit).

Post-close resource contract:
  First terminal activation loads process-global Ghostty/Metal/font/SQLite caches
  that must not be purged between tabs (shared Ghostty runtime). Cold
  pre-workspace RSS/FD delta after the first close is diagnostic only and must
  not be "fixed" by raising MAX_POST_CLOSE_RSS_DELTA_KB. Hard gates are:
  (1) child/owned process cleanup on every close, (2) per-surface PTY/kqueue
  release (FD category diagnostics), (3) cycle-to-cycle warmed recovery across
  RC2_E2E_RESOURCE_CLOSE_CYCLES open/close cycles so residual cannot stack.
  Cycle recovery reuses the same RSS delta and zero-FD-growth tolerances vs the
  post-close-1 warmed baseline.

Environment equivalents:
  RC2_E2E_PORT, RC2_E2E_DURATION_SECONDS, RC2_E2E_TERMINAL_COUNT,
  RC2_E2E_PRE_GATE_SECONDS, RC2_E2E_SAMPLE_INTERVAL_SECONDS,
  RC2_E2E_CLIENT_WARMUP_SECONDS, RC2_E2E_WORKLOAD_STABILIZATION_SECONDS,
  RC2_E2E_MAX_RSS_KB, RC2_E2E_MAX_RSS_TAIL_SLOPE_KB_PER_MINUTE,
  RC2_E2E_MAX_RSS_PLATEAU_DELTA_KB, RC2_E2E_MAX_RSS_TAIL_NET_GROWTH_KB,
  RC2_E2E_MAX_POST_CLOSE_RSS_DELTA_KB, RC2_E2E_RESOURCE_CLOSE_CYCLES,
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
        help=(
            "elapsed soak time for the intermediate health and memory gate; "
            "0 disables. Does not rebaseline post-soak samples"
        ),
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
        "--resource-close-cycles",
        type=int,
        default=RESOURCE_CLOSE_CYCLES,
        help=(
            "same-process terminal open/close cycles after the primary workload; "
            "cycle 1 warms the baseline, cycles 2+ must recover without stacking "
            f"(default {RESOURCE_CLOSE_CYCLES}, minimum 2)"
        ),
    )
    parser.add_argument(
        "--validate-only",
        action="store_true",
        help="validate and print the effective configuration without building or launching",
    )
    args = parser.parse_args(argv)
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
    global HIDDEN_LINES, LARGE_INPUT_BYTES, TUI_SECONDS, RESOURCE_CLOSE_CYCLES
    PORT = args.port
    BASE = f"http://127.0.0.1:{PORT}"
    RUN_SECONDS = args.duration_seconds
    TERMINAL_COUNT = args.terminal_count
    PRE_GATE_SECONDS = args.pre_gate_seconds
    SAMPLE_INTERVAL_SECONDS = args.sample_interval_seconds
    CLIENT_WARMUP_SECONDS = args.client_warmup_seconds
    WORKLOAD_STABILIZATION_SECONDS = args.workload_stabilization_seconds
    REQUIRE_SLOW_WS = args.require_slow_ws
    RESOURCE_CLOSE_CYCLES = args.resource_close_cycles
    # Smoke (non-release) must stay short enough for 15-30s canaries. Release-soak
    # keeps the heavy hidden flood / large input / TUI budgets unless env overrides.
    if not args.release_soak:
        if "RC2_E2E_HIDDEN_LINES" not in os.environ:
            HIDDEN_LINES = min(HIDDEN_LINES, 800)
        if "RC2_E2E_LARGE_INPUT_BYTES" not in os.environ:
            LARGE_INPUT_BYTES = min(LARGE_INPUT_BYTES, 32 * 1024)
        if "RC2_E2E_TUI_SECONDS" not in os.environ:
            TUI_SECONDS = min(TUI_SECONDS, 3)


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
    primary_stream_done_path = contained_path(
        run_artifact_root / "primary-stream.done",
        run_artifact_root,
        "primary stream completion sentinel",
    )
    return (
        state_root,
        run_artifact_root,
        workspace_tui_path,
        large_input_path,
        workload_trigger_path,
        hidden_flood_done_path,
        primary_stream_done_path,
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
    if args.resource_close_cycles < 2:
        raise Failure(
            "resource close cycles must be at least 2 "
            "(cycle 1 warms baseline; cycle 2+ proves no stacking)"
        )
    if args.resource_close_cycles > 8:
        raise Failure("resource close cycles must be at most 8")
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


def classify_fd_path_category(fd_type, name):
    """Map one lsof (type, name) pair to a privacy-safe ownership category.

    Never returns raw paths, socket endpoints, or user-home segments. Used to
    distinguish per-surface PTY/kqueue leftovers from process-global first-use
    caches (SQLite/WAL, frameworks, Ghostty resources, Metal/font).
    """
    # lsof type tags are mixed case (IPv4); normalize for matching only.
    kind = (fd_type or "unknown").strip()
    kind_key = kind.upper()
    raw = name or ""
    lower = raw.lower()

    if kind_key == "KQUEUE":
        return "kqueue"
    if kind_key == "CHR":
        if any(token in lower for token in ("/dev/ttys", "/dev/pty", "/dev/ptmx", "ptmx")):
            return "pty_chr"
        if lower.endswith("/dev/null") or lower == "/dev/null":
            return "dev_null_chr"
        return "chr_other"
    if kind_key in ("IPV4", "IPV6"):
        return "ip_socket"
    if kind_key == "UNIX":
        return "unix_socket"
    if kind_key == "DIR":
        return "dir_handle"
    if kind_key == "PIPE":
        return "pipe"
    if kind_key == "NPOLICY":
        return "npolicy"
    if kind_key != "REG":
        return f"type_{kind_key.lower()}"

    # REG path categories only — match library/framework shapes, never emit path.
    if (
        lower.endswith(".sqlite")
        or lower.endswith(".sqlite-wal")
        or lower.endswith(".sqlite-shm")
        or lower.endswith("-wal")
        or lower.endswith("-shm")
        or "remote-code.sqlite" in lower
        or "remotecode.sqlite" in lower
    ):
        return "sqlite_reg"
    if "ghostty" in lower:
        return "ghostty_resource_reg"
    if (
        ".metallib" in lower
        or "/metal/" in lower
        or "agx" in lower
        or "gpucompiler" in lower
        or "applemetal" in lower
    ):
        return "metal_reg"
    if (
        ".ttf" in lower
        or ".otf" in lower
        or ".ttc" in lower
        or "/fonts/" in lower
        or "coretext" in lower
        or "fontregistry" in lower
    ):
        return "font_reg"
    if ".framework/" in lower or lower.endswith(".dylib") or "/dyld/" in lower:
        return "framework_dylib_reg"
    if "remotecode" in lower or "agentcanary" in lower or "agent-canary" in lower:
        return "app_bundle_reg"
    if "/system/" in lower or lower.startswith("/usr/lib") or lower.startswith("/usr/lib/"):
        return "system_reg"
    if "/private/var/folders/" in lower or "/tmp/" in lower or lower.startswith("/var/folders/"):
        return "tmp_cache_reg"
    return "reg_other"


def file_descriptor_category_counts(pid):
    """Count open FDs by privacy-safe ownership category (types + path class).

    Uses lsof -Fftn but never returns names/paths to callers.
    """
    result = subprocess.run(
        ["/usr/sbin/lsof", "-nP", "-a", "-p", str(pid), "-Fftn"],
        text=True,
        capture_output=True,
    )
    if result.returncode != 0:
        raise Failure("could not sample app file descriptor categories")
    counts = {}
    current_type = None
    current_name = ""
    saw_fd = False

    def commit():
        nonlocal saw_fd
        if not saw_fd:
            return
        category = classify_fd_path_category(current_type or "unknown", current_name)
        counts[category] = counts.get(category, 0) + 1

    for line in result.stdout.splitlines():
        if not line:
            continue
        code, value = line[0], line[1:]
        if code == "f":
            commit()
            saw_fd = True
            current_type = "unknown"
            current_name = ""
        elif code == "t" and saw_fd:
            current_type = value or "unknown"
        elif code == "n" and saw_fd:
            current_name = value
    commit()
    return {key: counts[key] for key in sorted(counts)}


def file_descriptor_category_delta(before, after):
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


def process_tree_cleaned(child_count, baseline_child_count, owned_process_count=0):
    return child_count <= baseline_child_count and owned_process_count == 0


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


def wait_for_process_tree_cleanup(
    pid,
    baseline_child_count,
    terminal_session_ids=(),
    terminal_process_groups=(),
    terminal_process_marker=None,
    timeout=30,
):
    """Hard gate: no residual shell children or owned terminal processes.

    Does not gate RSS/FD — those use warmed cycle recovery after first close.
    """
    deadline = time.monotonic() + timeout
    last_child_count = None
    last_owned_processes = []
    last_snapshot = None
    while time.monotonic() < deadline:
        last_snapshot = process_resource_snapshot(pid)
        last_child_count = last_snapshot["child_process_count"]
        last_owned_processes = owned_terminal_processes(
            terminal_session_ids,
            terminal_process_groups,
            terminal_process_marker,
        )
        if process_tree_cleaned(
            last_child_count,
            baseline_child_count,
            len(last_owned_processes),
        ):
            return {**last_snapshot, "owned_processes": []}
        time.sleep(0.5)
    raise Failure(
        "post-close process tree did not clean up: "
        f"children {last_child_count} > {baseline_child_count}, or owned terminal processes "
        f"remain {last_owned_processes}"
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
    baseline_label="warmed post-close baseline",
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
        f"post-close resources did not recover to the {baseline_label}: "
        f"rss {last_rss_kb} > {baseline_rss_kb} + {MAX_POST_CLOSE_RSS_DELTA_KB} KiB, "
        f"fd {last_fd_count} > {baseline_fd_count}, or "
        f"children {last_child_count} > {baseline_child_count}, or owned terminal processes "
        f"remain {last_owned_processes}"
    )


def assert_no_per_surface_fd_residue(post_categories, cold_categories=None):
    """Fail if post-close still holds surface-local PTY/kqueue FDs.

    Global first-use caches (sqlite/framework/metal/font) may remain; PTY CHR
    and kqueues must return to the cold (pre-workspace) level.
    """
    cold = cold_categories or {}
    post = post_categories or {}
    for key in ("pty_chr", "kqueue"):
        post_count = int(post.get(key, 0))
        cold_count = int(cold.get(key, 0))
        if post_count > cold_count:
            raise Failure(
                f"per-surface FD residue after close: {key}={post_count} "
                f"> cold {cold_count}"
            )


def run_resource_close_cycle(cycle_index, terminal_count, run_artifact_root):
    """Open terminals, prove a live marker, then close them. Returns ownership sets.

    Used after the primary soak to prove residuals do not stack across cycles.
    """
    if terminal_count < 1:
        raise Failure("resource close cycle requires at least one terminal")
    workspace_ids = []
    surface_ids = []
    for index in range(terminal_count):
        created = rpc(
            "workspace.create",
            {"name": f"E2ECloseCycle{cycle_index:02d}_{index:02d}", "cwd": "/tmp"},
        )
        workspace_id, surface_id = workspace_surface(created)
        workspace_ids.append(workspace_id)
        surface_ids.append(surface_id)
    session_ids = {wait_for_terminal_shell_pid(surface_id) for surface_id in surface_ids}
    if len(session_ids) != terminal_count:
        raise Failure(
            f"close-cycle {cycle_index} shell session identities were not unique: "
            f"{sorted(session_ids)}"
        )
    primary_sid = surface_ids[0]
    rpc("workspace.select", {"id": workspace_ids[0]})
    marker = runtime_marker(f"RC2_CLOSE_CYCLE_{cycle_index:02d}_", "OK")
    send_text(primary_sid, f"printf '{marker}\\n'\n")
    wait_snapshot_contains(primary_sid, marker, timeout=15)
    process_marker = (
        "RC2_E2E_CYCLE_BG_"
        + hashlib.sha256(
            f"{run_artifact_root}:{cycle_index}".encode()
        ).hexdigest()[:12]
    )
    # No stubborn background job: cycle only needs process-tree emptiness after close.
    for workspace_id in workspace_ids:
        rpc("workspace.close", {"id": workspace_id})
    return {
        "cycle_index": cycle_index,
        "workspace_ids": workspace_ids,
        "surface_ids": surface_ids,
        "session_ids": session_ids,
        "process_marker": process_marker,
        "marker": marker,
    }


def collect_sample(pid, stats, surface_ids=()):
    """Collect one resource sample and update running maxima; do not append."""
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
    return {
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
    }


def sample(pid, stats, surface_ids=()):
    stats["samples"].append(collect_sample(pid, stats, surface_ids))


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


def soak_gate_samples(stats):
    """Samples that define the steady soak resource gate.

    After the post-soak freeze, intentional transition work may append more
    samples. Stability gates (pre-gate / post-soak / pre-exit / final) must not
    mix those materialization samples into tail-net, plateau, or FD delta.
    """
    samples = stats.get("samples") or []
    count = stats.get("soak_sample_count")
    if count is None:
        return list(samples)
    count = int(count)
    if count < 0:
        raise Failure("soak_sample_count must be non-negative")
    return list(samples[:count])


def update_memory_evidence(stats):
    samples = soak_gate_samples(stats)
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


def sample_post_soak_transition(pid, stats, surface_ids, target_fd_count, timeout=30):
    """Record one post-soak transition sample when FD is at the freeze target.

    Intentional post-soak I/O can hold a transient REG (history/ledger write).
    Settle is condition-based readiness: each collect_sample while FD is above
    target is a readiness poll only — not appended to stats["samples"] and not
    part of the frozen soak window. The row stored as the transition sample is
    the same observation that satisfied the settle predicate (no wait-then-
    sample TOCTOU). Sticky FD above target fails after timeout; there is no
    tolerance band and no baseline recapture. Once recorded, the sample is
    never discarded, rebased, value-filtered, or re-taken.
    """
    deadline = time.monotonic() + timeout
    last_fd_count = None
    last_types = None
    while time.monotonic() < deadline:
        row = collect_sample(pid, stats, surface_ids)
        last_fd_count = int(row["fd_count"])
        if last_fd_count <= target_fd_count:
            stats["samples"].append(row)
            return row
        # Readiness poll rejected: do not append; freeze window unchanged.
        time.sleep(0.25)
    try:
        last_types = file_descriptor_type_counts(pid)
    except Exception:
        last_types = None
    raise Failure(
        "file descriptors did not settle to post-soak level after intentional "
        f"transition work: {last_fd_count} > {target_fd_count}"
        + (f"; type_counts={last_types}" if last_types is not None else "")
    )


def assert_post_soak_transition(stats):
    """Gate intentional post-soak materialization without inventing a delta cap.

    Soak stability metrics freeze at post-soak (soak_sample_count). Hidden
    flood drain, large input, TUI, and reconnect intentionally change process
    state afterward. Transition gates are only the product absolute MAX_RSS_KB
    budget and zero sustained FD growth vs the frozen post-soak FD count.
    RSS/FD deltas are diagnostic fields only. Post-close recovery remains the
    separate absolute assert against the pre-workspace baseline.
    """
    samples = stats.get("samples") or []
    soak_count = stats.get("soak_sample_count")
    if soak_count is None:
        raise Failure("post-soak transition requires soak_sample_count freeze")
    soak_count = int(soak_count)
    if soak_count < 1 or soak_count > len(samples):
        raise Failure(
            f"invalid soak_sample_count {soak_count} for {len(samples)} samples"
        )
    if len(samples) <= soak_count:
        raise Failure("post-soak transition requires a sample after soak freeze")
    soak_end = samples[soak_count - 1]
    transition = samples[-1]
    rss_delta = int(transition["rss_kb"]) - int(soak_end["rss_kb"])
    fd_delta = int(transition["fd_count"]) - int(soak_end["fd_count"])
    stats["post_soak_rss_kb"] = int(soak_end["rss_kb"])
    stats["post_soak_fd_count"] = int(soak_end["fd_count"])
    stats["post_transition_rss_kb"] = int(transition["rss_kb"])
    stats["post_transition_fd_count"] = int(transition["fd_count"])
    # Diagnostic only — not a gate. No invented transition-delta product cap.
    stats["post_soak_transition_rss_delta_kb"] = rss_delta
    stats["post_soak_transition_fd_delta"] = fd_delta
    if int(transition["rss_kb"]) > MAX_RSS_KB:
        raise Failure(
            f"post-transition RSS {transition['rss_kb']} KiB exceeds absolute "
            f"cap {MAX_RSS_KB} KiB"
        )
    if fd_delta > 0:
        raise Failure(
            f"post-soak transition sustained file descriptor growth: delta {fd_delta}"
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


def runtime_marker(*parts):
    """Join marker parts only at runtime so typed/echoed source cannot pre-match waits."""
    if not parts or any(not isinstance(part, str) or part == "" for part in parts):
        raise Failure("runtime marker parts must be non-empty strings")
    return "".join(parts)


def post_idle_input_command():
    """Shell probe typed after soak idle: split marker, printf \\n format, real Enter.

    Adjacent shell quotes keep RC2_POST_IDLE_INPUT_OK out of typed/echoed source.
    The printf format retains a backslash-n inside quotes; the command terminator
    must be an actual newline so the shell executes the probe.
    """
    return "printf 'RC2_POST_IDLE_INPUT_''OK\\n'\n"


def foreground_child_exit_command():
    """Deterministic foreground termination for the child-exit gate.

    Intent: the interactive shell (foreground PTY child) must exit while a
    SIGHUP/SIGTERM-ignoring background marker descendant remains for later
    workspace-close / reaper proof.

    Shell builtin ``exit`` is not used: interactive zsh job control can refuse
    the first exit while jobs exist, so condition polling stays alive forever.
    ``exec /usr/bin/true`` replaces the shell process; true exits 0 and the
    existing background marker process is left for orphan-reaping checks.
    """
    return "exec /usr/bin/true\n"


def python_print_runtime_marker(*parts, flush=True):
    """Emit a Python print statement whose contiguous marker exists only after eval."""
    marker = runtime_marker(*parts)
    expression = " + ".join(repr(part) for part in parts)
    flush_arg = ", flush=True" if flush else ""
    return f"print({expression}{flush_arg})"


def first_diff_offset(expected, actual):
    limit = min(len(expected), len(actual))
    for index in range(limit):
        if expected[index] != actual[index]:
            return index
    if len(expected) != len(actual):
        return limit
    return None


def large_input_mismatch_diagnostics(path, expected):
    """Privacy-safe mismatch facts only: lengths, hashes, first differing offset."""
    diagnostics = {
        "expected_len": len(expected),
        "expected_sha256": hashlib.sha256(expected).hexdigest(),
        "actual_len": None,
        "actual_sha256": None,
        "first_diff_offset": None,
        "read_error": None,
    }
    try:
        actual = path.read_bytes()
    except OSError as exc:
        diagnostics["read_error"] = exc.__class__.__name__
        return diagnostics
    diagnostics["actual_len"] = len(actual)
    diagnostics["actual_sha256"] = hashlib.sha256(actual).hexdigest()
    diagnostics["first_diff_offset"] = first_diff_offset(expected, actual)
    return diagnostics


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


def wait_for_process_exited(surface_id, timeout=10):
    """Poll surface.health until the shell exit contract is observed.

    Exact contract only: alive is False and terminal_dead_reason is
    process_exited. Other dead reasons never satisfy the gate. On timeout the
    last privacy-safe health object (IDs/status fields only from RPC) is
    reported; no terminal content is included.
    """
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        last = rpc("surface.health", {"id": surface_id})
        if (
            last.get("alive") is False
            and last.get("terminal_dead_reason") == "process_exited"
        ):
            return last
        time.sleep(0.1)
    raise Failure(f"child exit did not mark dead: {last}")


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


def primary_stream_done_timeout_seconds(elapsed_since_trigger, workload_seconds=None):
    """Remaining producer budget after elapsed soak/setup; no arbitrary long wait.

    Producers run for workload_duration_seconds after the shared trigger. Post-soak
    waits must cover only what is left (plus a short sentinel-write grace), not a
    fixed multi-second floor unrelated to remaining work.
    """
    if workload_seconds is None:
        workload_seconds = workload_duration_seconds()
    if elapsed_since_trigger < 0:
        raise Failure("elapsed_since_trigger must be non-negative")
    remaining = max(0.0, float(workload_seconds) - float(elapsed_since_trigger))
    # Grace covers done.write_text / scheduler lag after the producer loop ends.
    return remaining + 5.0


def producer_hard_deadline_grace_seconds():
    """Extra wall budget for SIGALRM after nominal stream end.

    Covers final marker writes and done-file creation. Must stay small so a
    stuck producer cannot stretch the harness wait indefinitely.
    """
    return 2.0


def time_bounded_stdout_helpers_python():
    """Shared producer primitives: non-blocking line writes + hard wall deadline.

    Intent: PTY slave stdout blocks when the master apply path is slower than the
    producer (kernel buffer full). A plain print(flush=True) then never returns,
    so wall-clock loop checks and done-file writes never run. Helpers keep stress
    high when the drain path is healthy and still exit under permanent backpressure.

    Completion authority is _commit_done_sentinel only: atomic tmp+replace of the
    done file, exactly once, with SIGALRM ignored. It must never require a
    successful write to the same PTY that may be permanently full. Path.write_text
    is unsafe here — open('w') truncates first; a signal before write leaves a
    0-byte file that fails wait_for_exact_file('done\\n').
    """
    return (
        "import fcntl, os, signal, sys, time\n"
        "from pathlib import Path\n"
        "class _ProducerBudgetExpired(Exception):\n"
        "    pass\n"
        "_DONE_COMMITTED=False\n"
        "def _install_stdout_nonblocking():\n"
        "    fd=sys.stdout.fileno()\n"
        "    flags=fcntl.fcntl(fd, fcntl.F_GETFL)\n"
        "    fcntl.fcntl(fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)\n"
        "    return fd\n"
        "def _write_line_until(fd, text, end):\n"
        "    data=(text if text.endswith('\\n') else text + '\\n').encode()\n"
        "    off=0\n"
        "    while off < len(data) and time.monotonic() < end:\n"
        "        try:\n"
        "            n=os.write(fd, data[off:])\n"
        "            if n is None or n <= 0:\n"
        "                time.sleep(0.01)\n"
        "                continue\n"
        "            off += n\n"
        "        except BlockingIOError:\n"
        "            time.sleep(0.01)\n"
        "        except InterruptedError:\n"
        "            continue\n"
        "        except BrokenPipeError:\n"
        "            return False\n"
        "    return off == len(data)\n"
        "def _arm_producer_deadline(seconds):\n"
        "    def _on_alarm(signum, frame):\n"
        "        raise _ProducerBudgetExpired()\n"
        "    signal.signal(signal.SIGALRM, _on_alarm)\n"
        "    signal.setitimer(signal.ITIMER_REAL, max(0.05, float(seconds)))\n"
        "def _disarm_producer_deadline():\n"
        "    signal.setitimer(signal.ITIMER_REAL, 0.0)\n"
        "def _commit_done_sentinel(path):\n"
        "    global _DONE_COMMITTED\n"
        "    if _DONE_COMMITTED:\n"
        "        return\n"
        "    _DONE_COMMITTED=True\n"
        "    _disarm_producer_deadline()\n"
        "    signal.signal(signal.SIGALRM, signal.SIG_IGN)\n"
        "    try:\n"
        "        signal.signal(signal.SIGPIPE, signal.SIG_IGN)\n"
        "    except Exception:\n"
        "        pass\n"
        "    target=Path(path) if not isinstance(path, Path) else path\n"
        "    tmp=f\"{target}.tmp.{os.getpid()}\"\n"
        "    data=b'done\\n'\n"
        "    fd=os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)\n"
        "    try:\n"
        "        written=0\n"
        "        while written < len(data):\n"
        "            written+=os.write(fd, data[written:])\n"
        "        os.fsync(fd)\n"
        "    finally:\n"
        "        os.close(fd)\n"
        "    os.replace(tmp, str(target))\n"
    )


def runtime_marker_write_line_call(*parts, end_expr="end"):
    """Emit split marker via non-blocking _write_line_until (no contiguous needle)."""
    expression = " + ".join(repr(part) for part in parts)
    return f"_write_line_until(fd, {expression}, {end_expr})"


def primary_stream_producer_command(
    workload_trigger_python_path,
    primary_stream_done_python_path,
    duration_seconds=None,
):
    """Foreground primary stream: sustained lines, hard-bounded, file sentinel.

    Completion proof is _commit_done_sentinel only — never a typed contiguous
    RC2_E2E_STREAM_DONE in command source (echo false-positive class), and never
    gated on a PTY write to a possibly full stdout.
    """
    if duration_seconds is None:
        duration_seconds = workload_duration_seconds()
    grace = producer_hard_deadline_grace_seconds()
    # Non-blocking READY: blocking print(flush=True) never reaches the budgeted
    # loop or done-sentinel if the PTY is already full when the producer starts.
    # Short budget: under a permanently full PTY the host will not see READY
    # anyway; do not stall the hard deadline or file sentinel on that write.
    ready_write = runtime_marker_write_line_call(
        "RC2_E2E_STREAM_",
        "READY",
        end_expr="time.monotonic()+5",
    )
    # Best-effort scrollback marker only; file sentinel is already committed.
    done_write = runtime_marker_write_line_call(
        "RC2_E2E_STREAM_",
        "DONE",
        end_expr="time.monotonic()+max(0.2, grace)",
    )
    return (
        "python3 - <<'PY'\n"
        f"{time_bounded_stdout_helpers_python()}"
        f"trigger=Path({workload_trigger_python_path})\n"
        f"done=Path({primary_stream_done_python_path})\n"
        "fd=_install_stdout_nonblocking()\n"
        f"duration={float(duration_seconds)}\n"
        f"grace={float(grace)}\n"
        "i=0\n"
        "try:\n"
        f"    {ready_write}\n"
        "    while not trigger.exists():\n"
        "        time.sleep(0.01)\n"
        "    end=time.monotonic()+duration\n"
        "    _arm_producer_deadline(duration+grace)\n"
        "    try:\n"
        "        while time.monotonic()<end:\n"
        "            _write_line_until(fd, f'RC2_E2E_STREAM_{i:06d}', end)\n"
        "            i+=1\n"
        "            now=time.monotonic()\n"
        "            if now>=end:\n"
        "                break\n"
        "            time.sleep(min(0.01, end-now))\n"
        "    except _ProducerBudgetExpired:\n"
        "        pass\n"
        "finally:\n"
        "    _commit_done_sentinel(done)\n"
        "    try:\n"
        f"        {done_write}\n"
        "    except Exception:\n"
        "        pass\n"
        "PY\n"
    )


def start_auxiliary_workload(surface_id, index, workload_trigger_python_path):
    mode = (index - 2) % 4
    ready_print = python_print_runtime_marker(f"RC2_AUX_{index:02d}_", "READY")
    done_print = python_print_runtime_marker(f"RC2_AUX_{index:02d}_", "DONE")
    done_write = runtime_marker_write_line_call(
        f"RC2_AUX_{index:02d}_",
        "DONE",
        end_expr="time.monotonic()+max(0.2, grace)",
    )
    duration = float(workload_duration_seconds())
    grace = float(producer_hard_deadline_grace_seconds())
    helpers = time_bounded_stdout_helpers_python()
    if mode == 0:
        command = (
            "python3 - <<'PY'\n"
            f"{helpers}"
            f"trigger=Path({workload_trigger_python_path})\n"
            f"{ready_print}\n"
            "while not trigger.exists():\n"
            "    time.sleep(0.01)\n"
            f"duration={duration}\n"
            f"grace={grace}\n"
            "end=time.monotonic()+duration\n"
            "fd=_install_stdout_nonblocking()\n"
            "_arm_producer_deadline(duration+grace)\n"
            "i=0\n"
            "try:\n"
            "    while time.monotonic()<end:\n"
            f"        _write_line_until(fd, f'RC2_AUX_{index:02d}_STREAM_{{i:06d}}', end)\n"
            "        i+=1\n"
            "        now=time.monotonic()\n"
            "        if now>=end:\n"
            "            break\n"
            "        time.sleep(min(0.025, end-now))\n"
            "except _ProducerBudgetExpired:\n"
            "    pass\n"
            "finally:\n"
            "    _disarm_producer_deadline()\n"
            "    try:\n"
            f"        {done_write}\n"
            "    except Exception:\n"
            "        pass\n"
            "PY\n"
        )
        workload = "stream"
    elif mode == 1:
        command = (
            "python3 - <<'PY'\n"
            f"{helpers}"
            f"trigger=Path({workload_trigger_python_path})\n"
            f"{ready_print}\n"
            "while not trigger.exists():\n"
            "    time.sleep(0.01)\n"
            f"duration={duration}\n"
            f"grace={grace}\n"
            "end=time.monotonic()+duration\n"
            "fd=_install_stdout_nonblocking()\n"
            "_arm_producer_deadline(duration+grace)\n"
            "i=0\n"
            "try:\n"
            "    _write_line_until(fd, '\\x1b[?1049h', end)\n"
            "    while time.monotonic()<end:\n"
            f"        _write_line_until(fd, '\\x1b[HRC2_AUX_{index:02d}_TUI_%06d' % i, end)\n"
            "        i+=1\n"
            "        now=time.monotonic()\n"
            "        if now>=end:\n"
            "            break\n"
            "        time.sleep(min(0.1, end-now))\n"
            f"    _write_line_until(fd, '\\x1b[?1049l' + 'RC2_AUX_{index:02d}_' + 'DONE', end+grace)\n"
            "except _ProducerBudgetExpired:\n"
            "    pass\n"
            "finally:\n"
            "    _disarm_producer_deadline()\n"
            "PY\n"
        )
        workload = "tui"
    elif mode == 2:
        command = (
            "python3 - <<'PY'\n"
            "from pathlib import Path\n"
            "import time\n"
            f"trigger=Path({workload_trigger_python_path})\n"
            f"{ready_print}\n"
            "while not trigger.exists():\n"
            "    time.sleep(0.01)\n"
            f"time.sleep({duration})\n"
            f"{done_print}\n"
            "PY\n"
        )
        workload = "idle"
    else:
        command = (
            "python3 - <<'PY'\n"
            f"{helpers}"
            f"trigger=Path({workload_trigger_python_path})\n"
            f"{ready_print}\n"
            "while not trigger.exists():\n"
            "    time.sleep(0.01)\n"
            f"duration={duration}\n"
            f"grace={grace}\n"
            "end=time.monotonic()+duration\n"
            "fd=_install_stdout_nonblocking()\n"
            "_arm_producer_deadline(duration+grace)\n"
            "burst=0\n"
            "try:\n"
            "    while time.monotonic()<end:\n"
            "        for line in range(50):\n"
            f"            _write_line_until(fd, f'RC2_AUX_{index:02d}_BURST_{{burst:05d}}_{{line:03d}}', end)\n"
            "            if time.monotonic()>=end:\n"
            "                break\n"
            "        burst+=1\n"
            "        now=time.monotonic()\n"
            "        if now>=end:\n"
            "            break\n"
            "        time.sleep(min(1.0, end-now))\n"
            "except _ProducerBudgetExpired:\n"
            "    pass\n"
            "finally:\n"
            "    _disarm_producer_deadline()\n"
            "    try:\n"
            f"        {done_write}\n"
            "    except Exception:\n"
            "        pass\n"
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
        "resource_close_cycles": args.resource_close_cycles,
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
        "configured_resource_close_cycles": RESOURCE_CLOSE_CYCLES,
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
            "resource_close_cycles": RESOURCE_CLOSE_CYCLES,
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
        "soak_sample_count": None,
        "post_soak_rss_kb": None,
        "post_soak_fd_count": None,
        "post_transition_rss_kb": None,
        "post_transition_fd_count": None,
        "post_soak_transition_rss_delta_kb": None,
        "post_soak_transition_fd_delta": None,
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
        "pre_workspace_fd_type_counts": None,
        "pre_workspace_fd_categories": None,
        "post_close_rss_kb": None,
        "post_close_rss_delta_kb": None,
        "post_close_rss_delta_from_cold_kb": None,
        "post_close_fd_count": None,
        "post_close_fd_delta_from_cold": None,
        "post_close_child_process_count": None,
        "post_close_fd_type_counts": None,
        "post_close_fd_categories": None,
        "post_close_fd_category_delta_from_cold": None,
        "post_close_cold_rss_within_budget": None,
        "post_close_cold_fd_recovered": None,
        "post_close_process_tree_cleaned": False,
        "post_close_per_surface_fds_cleaned": False,
        "warmed_post_close_rss_kb": None,
        "warmed_post_close_fd_count": None,
        "warmed_post_close_child_process_count": None,
        "resource_close_cycle_results": [],
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
    primary_stream_done_path = None
    terminal_process_marker = None
    try:
        (
            state_root,
            run_artifact_root,
            workspace_tui_path,
            large_input_path,
            workload_trigger_path,
            hidden_flood_done_path,
            primary_stream_done_path,
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
        primary_stream_done_python_path = repr(str(primary_stream_done_path))
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
        stats["pre_workspace_fd_type_counts"] = file_descriptor_type_counts(pid)
        stats["pre_workspace_fd_categories"] = file_descriptor_category_counts(pid)

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

        stream_ready_marker = runtime_marker("RC2_E2E_STREAM_", "READY")
        stream_done_marker = runtime_marker("RC2_E2E_STREAM_", "DONE")
        send_text(
            primary_sid,
            primary_stream_producer_command(
                workload_trigger_python_path,
                primary_stream_done_python_path,
            ),
        )
        stats["workloads"] = ["stream", "hidden-flood"]
        for index, surface_id in enumerate(all_surface_ids[2:], start=2):
            stats["workloads"].append(start_auxiliary_workload(
                surface_id,
                index,
                workload_trigger_python_path,
            ))

        wait_snapshot_contains(primary_sid, stream_ready_marker, timeout=30)
        for index, surface_id in enumerate(all_surface_ids[2:], start=2):
            wait_snapshot_contains(
                surface_id,
                runtime_marker(f"RC2_AUX_{index:02d}_", "READY"),
                timeout=30,
            )
        workload_trigger_path.write_text("start\n")
        workload_started_monotonic = time.monotonic()
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
        # Freeze the soak gate window here. Later intentional work (hidden
        # drain, large input, TUI, reconnect) materializes different state and
        # must not rewrite soak tail-net / FD delta.
        stats["soak_sample_count"] = len(stats["samples"])
        stats["post_soak_rss_kb"] = stats["samples"][-1]["rss_kb"]
        stats["post_soak_fd_count"] = stats["samples"][-1]["fd_count"]
        # File sentinel is authoritative: snapshot needles must not match echoed
        # script source while the stream child still owns the foreground tty.
        primary_done_timeout = primary_stream_done_timeout_seconds(
            time.monotonic() - workload_started_monotonic
        )
        wait_for_exact_file(
            primary_stream_done_path,
            "done\n",
            timeout=primary_done_timeout,
            description="primary stream producer completion",
        )
        # Marker should already be in scrollback once the done-file exists; keep
        # a short bounded snapshot wait independent of remaining producer budget.
        wait_snapshot_contains(primary_sid, stream_done_marker, timeout=15)
        for index, surface_id in enumerate(all_surface_ids[2:], start=2):
            wait_snapshot_contains(
                surface_id,
                runtime_marker(f"RC2_AUX_{index:02d}_", "DONE"),
                timeout=max(15.0, primary_done_timeout),
            )
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
        post_idle_marker = runtime_marker("RC2_POST_IDLE_INPUT_", "OK")
        send_text(primary_sid, post_idle_input_command())
        wait_snapshot_contains(primary_sid, post_idle_marker, timeout=10)
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
        try:
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
        except Failure as large_input_error:
            # Disposable run artifact: lengths/hashes/offset only — never payload bytes.
            stats["large_input_mismatch"] = large_input_mismatch_diagnostics(
                large_input_path,
                expected_large_input,
            )
            raise Failure(
                f"{large_input_error}; mismatch={stats['large_input_mismatch']}"
            ) from large_input_error

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

        # Record transition with FD settle in the same observation (no
        # wait-then-sample TOCTOU). Gate: absolute MAX_RSS_KB + zero FD growth.
        # Transition RSS/FD deltas are diagnostic; soak metrics stay frozen.
        sample_post_soak_transition(
            pid, stats, all_surface_ids, stats["post_soak_fd_count"]
        )
        assert_post_soak_transition(stats)
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
        send_text(primary_sid, foreground_child_exit_command())
        dead = wait_for_process_exited(primary_sid)
        stats["child_exit_dead_seen"] = True
        after_exit = send_text(primary_sid, "pwd\n")
        if after_exit.get("accepted") is not False or after_exit.get("status") != "process_exited":
            raise Failure(f"send after exit was not explicit process_exited: {after_exit}")
        stats["app_alive_after_child_exit"] = app_pid(canary_root) is not None
        for workspace_id in all_workspace_ids:
            rpc("workspace.close", {"id": workspace_id})
        # Cycle 1: hard process-tree cleanup + per-surface FD category proof.
        # Cold RSS/FD delta is diagnostic — first Ghostty/Metal/font/SQLite
        # activation is process-global and must not be purged between tabs.
        # Cycle-to-cycle warmed recovery (below) is the stacking gate.
        recovered = wait_for_process_tree_cleanup(
            pid,
            pre_workspace_resources["child_process_count"],
            terminal_session_ids=terminal_session_ids,
            terminal_process_groups=terminal_process_groups,
            terminal_process_marker=terminal_process_marker,
        )
        stats["post_close_process_tree_cleaned"] = True
        # Brief settle after tree cleanup so FD/kqueue cancel handlers finish.
        settle_deadline = time.monotonic() + 5.0
        while time.monotonic() < settle_deadline:
            candidate = process_resource_snapshot(pid)
            if process_tree_cleaned(
                candidate["child_process_count"],
                pre_workspace_resources["child_process_count"],
                0,
            ):
                recovered = {**candidate, "owned_processes": []}
            time.sleep(0.25)
        post_categories = file_descriptor_category_counts(pid)
        post_types = file_descriptor_type_counts(pid)
        assert_no_per_surface_fd_residue(
            post_categories,
            stats.get("pre_workspace_fd_categories"),
        )
        stats["post_close_per_surface_fds_cleaned"] = True
        stats["post_close_rss_kb"] = recovered["rss_kb"]
        stats["post_close_rss_delta_kb"] = (
            recovered["rss_kb"] - pre_workspace_resources["rss_kb"]
        )
        stats["post_close_rss_delta_from_cold_kb"] = stats["post_close_rss_delta_kb"]
        stats["post_close_fd_count"] = recovered["fd_count"]
        stats["post_close_fd_delta_from_cold"] = (
            recovered["fd_count"] - pre_workspace_resources["fd_count"]
        )
        stats["post_close_child_process_count"] = recovered["child_process_count"]
        stats["post_close_owned_terminal_processes"] = len(recovered["owned_processes"])
        stats["post_close_fd_type_counts"] = post_types
        stats["post_close_fd_categories"] = post_categories
        stats["post_close_fd_category_delta_from_cold"] = file_descriptor_category_delta(
            stats.get("pre_workspace_fd_categories"),
            post_categories,
        )
        stats["post_close_cold_rss_within_budget"] = (
            recovered["rss_kb"]
            <= pre_workspace_resources["rss_kb"] + MAX_POST_CLOSE_RSS_DELTA_KB
        )
        stats["post_close_cold_fd_recovered"] = (
            recovered["fd_count"] <= pre_workspace_resources["fd_count"]
        )
        warmed_resources = {
            "rss_kb": recovered["rss_kb"],
            "fd_count": recovered["fd_count"],
            "child_process_count": recovered["child_process_count"],
        }
        stats["warmed_post_close_rss_kb"] = warmed_resources["rss_kb"]
        stats["warmed_post_close_fd_count"] = warmed_resources["fd_count"]
        stats["warmed_post_close_child_process_count"] = warmed_resources[
            "child_process_count"
        ]
        cycle_results = [
            {
                "cycle_index": 1,
                "role": "warmed_baseline",
                "rss_kb": warmed_resources["rss_kb"],
                "fd_count": warmed_resources["fd_count"],
                "child_process_count": warmed_resources["child_process_count"],
                "rss_delta_from_warmed_kb": 0,
                "fd_delta_from_warmed": 0,
                "recovered": True,
            }
        ]
        for cycle_index in range(2, RESOURCE_CLOSE_CYCLES + 1):
            cycle = run_resource_close_cycle(
                cycle_index,
                TERMINAL_COUNT,
                run_artifact_root,
            )
            cycle_recovered = wait_for_resource_recovery(
                pid,
                warmed_resources["rss_kb"],
                warmed_resources["fd_count"],
                warmed_resources["child_process_count"],
                terminal_session_ids=cycle["session_ids"],
                terminal_process_groups=(),
                terminal_process_marker=cycle["process_marker"],
                baseline_label=(
                    f"warmed post-close baseline (cycle {cycle_index} vs cycle 1)"
                ),
            )
            cycle_categories = file_descriptor_category_counts(pid)
            assert_no_per_surface_fd_residue(
                cycle_categories,
                stats.get("pre_workspace_fd_categories"),
            )
            cycle_results.append(
                {
                    "cycle_index": cycle_index,
                    "role": "stacking_probe",
                    "rss_kb": cycle_recovered["rss_kb"],
                    "fd_count": cycle_recovered["fd_count"],
                    "child_process_count": cycle_recovered["child_process_count"],
                    "rss_delta_from_warmed_kb": (
                        cycle_recovered["rss_kb"] - warmed_resources["rss_kb"]
                    ),
                    "fd_delta_from_warmed": (
                        cycle_recovered["fd_count"] - warmed_resources["fd_count"]
                    ),
                    "fd_categories": cycle_categories,
                    "recovered": True,
                }
            )
        stats["resource_close_cycle_results"] = cycle_results
        # Final reported post-close sample is the last cycle (stacking proof).
        final_cycle = cycle_results[-1]
        stats["post_close_rss_kb"] = final_cycle["rss_kb"]
        stats["post_close_fd_count"] = final_cycle["fd_count"]
        stats["post_close_child_process_count"] = final_cycle["child_process_count"]
        stats["post_close_rss_delta_kb"] = (
            final_cycle["rss_kb"] - pre_workspace_resources["rss_kb"]
        )
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
                current_categories = file_descriptor_category_counts(stats["canary_pid"])
                failure_diagnostics["fd_type_counts"] = current_types
                failure_diagnostics["fd_type_delta_from_pre_baseline"] = (
                    file_descriptor_type_delta(
                        stats.get("pre_baseline_fd_type_counts"),
                        current_types,
                    )
                )
                failure_diagnostics["fd_categories"] = current_categories
                failure_diagnostics["fd_category_delta_from_cold"] = (
                    file_descriptor_category_delta(
                        stats.get("pre_workspace_fd_categories"),
                        current_categories,
                    )
                )
                failure_diagnostics["fd_category_delta_from_warmed"] = (
                    file_descriptor_category_delta(
                        stats.get("post_close_fd_categories"),
                        current_categories,
                    )
                    if stats.get("post_close_fd_categories")
                    else None
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
