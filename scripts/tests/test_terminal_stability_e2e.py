import importlib.util
import json
import os
import socket
import subprocess
import sys
import time
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "terminal-stability-e2e.py"
SPEC = importlib.util.spec_from_file_location("terminal_stability_e2e", SCRIPT)
HARNESS = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(HARNESS)


class FakeHTTPResponse:
    def __init__(self, payload):
        self.payload = payload

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        return False

    def read(self):
        return json.dumps(self.payload).encode()


class FakeMutationControl:
    def __init__(self):
        self.requests = 0

    def request_identity(self):
        self.requests += 1
        return {
            "client_request_id": f"harness-request-{self.requests}",
            "connection_id": "connection-1",
            "expected_host_id": "host-1",
            "expected_boot_epoch": 17,
        }


class TerminalStabilityMutationIdentityTests(unittest.TestCase):
    def setUp(self):
        self.previous_control = getattr(HARNESS, "_MUTATION_CONTROL", None)
        HARNESS._MUTATION_CONTROL = None

    def tearDown(self):
        HARNESS._MUTATION_CONTROL = self.previous_control

    def test_mutation_rpc_binds_unique_active_websocket_identity(self):
        control = FakeMutationControl()
        HARNESS._MUTATION_CONTROL = control
        requests = []

        def urlopen(request, timeout):
            requests.append(json.loads(request.data))
            return FakeHTTPResponse({"jsonrpc": "2.0", "id": "1", "result": {}})

        with mock.patch.object(HARNESS.urllib.request, "urlopen", side_effect=urlopen):
            HARNESS.rpc("workspace.create", {"name": "one", "cwd": "/tmp"})
            HARNESS.rpc("workspace.create", {"name": "two", "cwd": "/tmp"})

        first = requests[0]["params"]
        second = requests[1]["params"]
        self.assertEqual(first["connection_id"], "connection-1")
        self.assertEqual(first["expected_host_id"], "host-1")
        self.assertEqual(first["expected_boot_epoch"], 17)
        self.assertEqual(first["client_request_id"], "harness-request-1")
        self.assertEqual(second["client_request_id"], "harness-request-2")

    def test_read_rpc_does_not_receive_mutation_identity(self):
        HARNESS._MUTATION_CONTROL = FakeMutationControl()
        requests = []

        def urlopen(request, timeout):
            requests.append(json.loads(request.data))
            return FakeHTTPResponse({"jsonrpc": "2.0", "id": "1", "result": []})

        with mock.patch.object(HARNESS.urllib.request, "urlopen", side_effect=urlopen):
            HARNESS.rpc("workspace.list")

        self.assertEqual(requests[0]["params"], {})

    def test_mutation_rpc_fails_closed_without_control_connection(self):
        with mock.patch.object(HARNESS.urllib.request, "urlopen") as urlopen:
            with self.assertRaisesRegex(HARNESS.Failure, "mutation control websocket"):
                HARNESS.rpc("surface.send_text", {"id": "surface-1", "text": "pwd\n"})
        urlopen.assert_not_called()

    def test_control_connection_drains_and_answers_websocket_ping(self):
        client, server = socket.socketpair()
        self.addCleanup(server.close)
        control = HARNESS.MutationControlConnection(
            client,
            bytearray(),
            {
                "connectionId": "connection-1",
                "hostId": "host-1",
                "bootEpoch": 17,
            },
        ).start()
        self.addCleanup(control.close)

        server.sendall(bytes([0x89, 4]) + b"ping")
        server.settimeout(2)
        response = bytearray(server.recv(1024))
        frame = HARNESS.decode_websocket_frame(response)

        self.assertEqual(frame, (0xA, b"ping"))
        identity = control.request_identity()
        self.assertEqual(identity["connection_id"], "connection-1")
        self.assertEqual(identity["expected_host_id"], "host-1")
        self.assertEqual(identity["expected_boot_epoch"], 17)
        self.assertTrue(identity["client_request_id"])


class TerminalStabilitySlowWSReadinessTests(unittest.TestCase):
    def test_open_slow_ws_requires_welcome_before_returning(self):
        # WHY: a slow client that returns after the HTTP upgrade alone is not
        # server-registered; measuring FD baseline before welcome makes the
        # intended long-lived socket look like +1 growth.
        welcome = {
            "type": "welcome",
            "connectionId": "slow-1",
            "hostId": "host-1",
            "bootEpoch": 3,
        }
        welcome_payload = json.dumps(welcome).encode()
        buffer = bytearray([0x81, len(welcome_payload)])
        buffer.extend(welcome_payload)
        sock = mock.Mock()
        # After welcome is consumed from the buffer, the keepalive drain may poll.
        sock.recv.side_effect = socket.timeout

        with mock.patch.object(
            HARNESS,
            "open_websocket",
            return_value=(sock, buffer),
        ):
            connection = HARNESS.open_slow_ws()
        self.addCleanup(connection.close)

        self.assertEqual(connection.connection_id, "slow-1")
        connection.assert_active()

    def test_open_slow_ws_fails_setup_when_welcome_never_arrives(self):
        sock = mock.Mock()
        sock.recv.side_effect = socket.timeout

        with mock.patch.object(
            HARNESS,
            "open_websocket",
            return_value=(sock, bytearray()),
        ):
            with self.assertRaisesRegex(HARNESS.Failure, "timed out"):
                HARNESS.open_slow_ws()
        sock.close.assert_called()

    def test_slow_ws_answers_ping_until_slow_mode_then_stops_draining(self):
        client, server = socket.socketpair()
        self.addCleanup(server.close)
        connection = HARNESS.SlowWebSocketConnection(
            client,
            bytearray(),
            {"connectionId": "slow-1"},
        ).start()
        self.addCleanup(connection.close)

        server.sendall(bytes([0x89, 4]) + b"ping")
        server.settimeout(2)
        response = bytearray(server.recv(1024))
        self.assertEqual(HARNESS.decode_websocket_frame(response), (0xA, b"ping"))

        connection.enter_slow_mode()
        server.sendall(bytes([0x89, 4]) + b"pong?")
        server.settimeout(0.4)
        with self.assertRaises(socket.timeout):
            server.recv(1024)

    def test_wait_for_active_websocket_clients_requires_server_ready_count(self):
        # WHY: readiness must come from server-side active_clients, not a sleep
        # or a post-growth baseline recapture.
        responses = [
            {"connections": {"active_clients": 1, "total_queued_bytes": 0, "slow_client_drops": 0}},
            {"connections": {"active_clients": 2, "total_queued_bytes": 0, "slow_client_drops": 0}},
        ]

        def urlopen(request, timeout=5):
            self.assertIn("/v1/health", request.full_url)
            return FakeHTTPResponse(responses.pop(0))

        with mock.patch.object(HARNESS.urllib.request, "urlopen", side_effect=urlopen):
            metrics = HARNESS.wait_for_active_websocket_clients(2, timeout=2)
        self.assertEqual(metrics["active_clients"], 2)
        self.assertEqual(responses, [])

    def test_wait_for_active_websocket_clients_fails_when_never_ready(self):
        def urlopen(request, timeout=5):
            return FakeHTTPResponse(
                {
                    "connections": {
                        "active_clients": 1,
                        "total_queued_bytes": 0,
                        "slow_client_drops": 0,
                    }
                }
            )

        with mock.patch.object(HARNESS.urllib.request, "urlopen", side_effect=urlopen):
            with self.assertRaisesRegex(
                HARNESS.Failure,
                "active websocket client",
            ):
                HARNESS.wait_for_active_websocket_clients(2, timeout=0.2)

    def test_file_descriptor_type_counts_ignore_names(self):
        # WHY: FD identity diagnostics must classify types without exposing path
        # contents, socket endpoints, or terminal text.
        lsof_output = "\n".join(
            [
                "f0",
                "tCHR",
                "n/dev/null",
                "f1",
                "tIPv4",
                "n127.0.0.1:18217",
                "f2",
                "tIPv4",
                "n127.0.0.1:18217",
                "f3",
                "tREG",
                "n/secret/path/history.db",
                "",
            ]
        )
        completed = mock.Mock(returncode=0, stdout=lsof_output, stderr="")
        with mock.patch.object(HARNESS.subprocess, "run", return_value=completed) as run:
            counts = HARNESS.file_descriptor_type_counts(1234)
        self.assertEqual(counts, {"CHR": 1, "IPv4": 2, "REG": 1})
        args = run.call_args[0][0]
        self.assertIn("-Fft", args)
        self.assertNotIn("-Fn", args)
        delta = HARNESS.file_descriptor_type_delta(
            {"CHR": 1, "IPv4": 1, "REG": 1},
            counts,
        )
        self.assertEqual(delta, {"IPv4": 1})

    def test_file_descriptor_categories_are_privacy_safe_and_typed(self):
        # WHY: residual +6 FD ownership after close must distinguish per-surface
        # PTY/kqueue from process-global first-use caches without leaking paths,
        # home directories, or socket endpoints into stats/logs.
        cases = [
            ("CHR", "/dev/ttys003", "pty_chr"),
            ("CHR", "/dev/null", "dev_null_chr"),
            ("KQUEUE", "", "kqueue"),
            ("IPv4", "127.0.0.1:29305->127.0.0.1:9", "ip_socket"),
            ("REG", "/Users/private/Library/X/RemoteCode.sqlite-wal", "sqlite_reg"),
            ("REG", "/System/Library/Frameworks/Metal.framework/Metal", "framework_dylib_reg"),
            ("REG", "/private/var/folders/ab/cd/T/font-cache", "tmp_cache_reg"),
            ("REG", "/app/RemoteCode_Surfaces.bundle/ghostty/themes/x", "ghostty_resource_reg"),
            ("REG", "/tmp/unknown-blob", "tmp_cache_reg"),
        ]
        for fd_type, name, expected in cases:
            category = HARNESS.classify_fd_path_category(fd_type, name)
            self.assertEqual(category, expected, msg=(fd_type, name))
            self.assertNotIn("private", category)
            self.assertNotIn("Users", category)
            self.assertNotIn("127.0.0.1", category)
            if name:
                self.assertNotIn(name, category)

        lsof_output = "\n".join(
            [
                "f0",
                "tCHR",
                "n/dev/ttys001",
                "f1",
                "tKQUEUE",
                "n",
                "f2",
                "tREG",
                "n/secret/home/RemoteCode.sqlite",
                "f3",
                "tREG",
                "n/System/Library/Frameworks/AppKit.framework/AppKit",
                "",
            ]
        )
        completed = mock.Mock(returncode=0, stdout=lsof_output, stderr="")
        with mock.patch.object(HARNESS.subprocess, "run", return_value=completed) as run:
            counts = HARNESS.file_descriptor_category_counts(99)
        self.assertEqual(
            counts,
            {
                "framework_dylib_reg": 1,
                "kqueue": 1,
                "pty_chr": 1,
                "sqlite_reg": 1,
            },
        )
        args = run.call_args[0][0]
        self.assertIn("-Fftn", args)
        # Returned structure is categories only — no path strings.
        serialized = json.dumps(counts)
        self.assertNotIn("/secret", serialized)
        self.assertNotIn("ttys", serialized)

    def test_assert_no_per_surface_fd_residue_allows_global_caches(self):
        # WHY: SQLite/Metal/framework FDs may stay after first activation; PTY and
        # kqueues must not. Raising cold RSS/FD tolerance would hide surface leaks.
        cold = {"dev_null_chr": 1, "sqlite_reg": 0, "kqueue": 0, "pty_chr": 0}
        post_ok = {
            "dev_null_chr": 1,
            "sqlite_reg": 3,
            "framework_dylib_reg": 4,
            "kqueue": 0,
            "pty_chr": 0,
        }
        HARNESS.assert_no_per_surface_fd_residue(post_ok, cold)
        with self.assertRaisesRegex(HARNESS.Failure, "per-surface FD residue.*kqueue"):
            HARNESS.assert_no_per_surface_fd_residue(
                {**post_ok, "kqueue": 2},
                cold,
            )
        with self.assertRaisesRegex(HARNESS.Failure, "per-surface FD residue.*pty_chr"):
            HARNESS.assert_no_per_surface_fd_residue(
                {**post_ok, "pty_chr": 1},
                cold,
            )

    def test_main_orders_client_readiness_before_soak_baseline(self):
        # WHY: the zero-FD-growth gate uses sample[0] as baseline; long-lived
        # clients must be welcome-ready and server-registered before that sample.
        source = Path(HARNESS.__file__).read_text()
        main = source.split("def main():", 1)[1]
        welcome = main.index('stats["slow_ws_welcome_seen"] = True')
        clients_ready = main.index("wait_for_active_websocket_clients(2)")
        slow_mode = main.index("slow_sock.enter_slow_mode()")
        soak = main.index('stats["soak_started_monotonic"] = time.monotonic()')
        self.assertLess(welcome, clients_ready)
        self.assertLess(clients_ready, slow_mode)
        self.assertLess(slow_mode, soak)
        # Slow mode (stop draining) must not precede the pre-baseline readiness check.
        pre_baseline_ready = main.rindex(
            "wait_for_active_websocket_clients(2)",
            0,
            soak,
        )
        self.assertLess(pre_baseline_ready, slow_mode)
        self.assertIn("pre_baseline_fd_type_counts", main)
        self.assertNotIn("max_fd_count_delta\": 1", main)
        self.assertIn('"max_fd_count_delta": 0', main)

    def test_main_freezes_soak_gate_before_post_soak_transition(self):
        # WHY: pre-exit must not mix intentional hidden-drain/large-input/TUI
        # materialization into the soak plateau tail-net gate (final4 false fail).
        # Post-close: process-tree + per-surface FD hard gates, then multi-cycle
        # warmed recovery (cold delta is diagnostic; do not raise 32MiB/FD).
        source = Path(HARNESS.__file__).read_text()
        main = source.split("def main():", 1)[1]
        post_soak = main.index('assert_stability_gate(stats, "post-soak")')
        freeze = main.index('stats["soak_sample_count"] = len(stats["samples"])')
        hidden_drain = main.index('stats["hidden_output_drained"] = True')
        transition_sample = main.index("sample_post_soak_transition(")
        transition = main.index("assert_post_soak_transition(stats)")
        pre_exit = main.index('assert_stability_gate(stats, "pre-exit")')
        tree_cleanup = main.index("wait_for_process_tree_cleanup(")
        cycle_probe = main.index("run_resource_close_cycle(")
        cycle_recovery = main.index("wait_for_resource_recovery(")
        self.assertLess(post_soak, freeze)
        self.assertLess(freeze, hidden_drain)
        self.assertLess(hidden_drain, transition_sample)
        self.assertLess(transition_sample, transition)
        self.assertLess(transition, pre_exit)
        self.assertLess(pre_exit, tree_cleanup)
        self.assertLess(tree_cleanup, cycle_probe)
        self.assertLess(cycle_probe, cycle_recovery)
        # No invented transition-delta product gate/env.
        self.assertNotIn("max_post_soak_transition_rss_delta_kb", main)
        self.assertNotIn("MAX_POST_SOAK_TRANSITION_RSS_DELTA_KB", source)
        self.assertNotIn("RC2_E2E_MAX_POST_SOAK_TRANSITION_RSS_DELTA_KB", source)
        self.assertNotIn("_PROCESS_RSS_BYTES_PER_PAYLOAD_BYTE", source)
        # Cold absolute RSS/FD recovery is no longer the sole hard post-close gate.
        self.assertIn("post_close_rss_delta_from_cold_kb", main)
        self.assertIn("warmed_post_close_rss_kb", main)
        self.assertIn("resource_close_cycle_results", main)
        self.assertIn("assert_no_per_surface_fd_residue(", main)
        # Thresholds must not be raised to hide the one-time activation jump.
        self.assertIn('MAX_POST_CLOSE_RSS_DELTA_KB", "32768")', source)
        self.assertIn('"max_fd_count_delta": 0', main)
        self.assertNotIn("wait_for_fd_settle(", main)
        self.assertNotIn(
            "sample(pid, stats, all_surface_ids)\n        assert_post_soak_transition",
            main,
        )

    def test_resource_close_cycles_default_and_validation(self):
        # WHY: one open/close cannot distinguish one-time Ghostty/Metal caches
        # from per-surface stacking; minimum two cycles is mandatory.
        self.assertGreaterEqual(HARNESS.RESOURCE_CLOSE_CYCLES, 2)
        args = HARNESS.parse_args(
            [
                "--port",
                "29306",
                "--duration-seconds",
                "10",
                "--pre-gate-seconds",
                "0",
                "--resource-close-cycles",
                "1",
            ]
        )
        with self.assertRaisesRegex(HARNESS.Failure, "at least 2"):
            HARNESS.validate_configuration(args)
        args = HARNESS.parse_args(
            [
                "--port",
                "29306",
                "--duration-seconds",
                "10",
                "--pre-gate-seconds",
                "0",
                "--resource-close-cycles",
                "3",
            ]
        )
        HARNESS.validate_configuration(args)
        self.assertEqual(args.resource_close_cycles, 3)

    def test_post_close_resources_recovered_uses_unchanged_tolerances(self):
        # WHY: cycle-to-cycle gate reuses 32MiB RSS + zero FD growth vs warmed
        # baseline — never raise those tolerances to absorb cumulative growth.
        previous = HARNESS.MAX_POST_CLOSE_RSS_DELTA_KB
        HARNESS.MAX_POST_CLOSE_RSS_DELTA_KB = 32768
        self.addCleanup(lambda: setattr(HARNESS, "MAX_POST_CLOSE_RSS_DELTA_KB", previous))
        self.assertTrue(
            HARNESS.post_close_resources_recovered(
                rss_kb=200_000,
                fd_count=58,
                child_count=0,
                baseline_rss_kb=200_000,
                baseline_fd_count=58,
                baseline_child_count=0,
            )
        )
        # Same residual as warmed is OK; another 40MiB stack fails.
        self.assertFalse(
            HARNESS.post_close_resources_recovered(
                rss_kb=200_000 + 40_000,
                fd_count=58,
                child_count=0,
                baseline_rss_kb=200_000,
                baseline_fd_count=58,
                baseline_child_count=0,
            )
        )
        # FD stacking of even one descriptor fails (tolerance stays 0).
        self.assertFalse(
            HARNESS.post_close_resources_recovered(
                rss_kb=200_000,
                fd_count=59,
                child_count=0,
                baseline_rss_kb=200_000,
                baseline_fd_count=58,
                baseline_child_count=0,
            )
        )

    def test_wait_for_resource_recovery_labels_warmed_baseline(self):
        # WHY: failure text must say warmed baseline so operators do not re-raise
        # cold pre-workspace tolerance when cycle stacking is the real fail.
        snapshots = [
            {"rss_kb": 300_000, "fd_count": 60, "child_process_count": 0},
            {"rss_kb": 300_000, "fd_count": 60, "child_process_count": 0},
        ]

        def snapshot(_pid):
            return snapshots[min(len(snapshots) - 1, 0)]

        with mock.patch.object(HARNESS, "process_resource_snapshot", side_effect=snapshot):
            with mock.patch.object(HARNESS, "owned_terminal_processes", return_value=[]):
                with mock.patch.object(HARNESS.time, "sleep", return_value=None):
                    with mock.patch.object(
                        HARNESS.time,
                        "monotonic",
                        side_effect=[0.0, 0.0, 0.6, 31.0],
                    ):
                        with self.assertRaisesRegex(
                            HARNESS.Failure,
                            "warmed post-close baseline",
                        ):
                            HARNESS.wait_for_resource_recovery(
                                1,
                                baseline_rss_kb=200_000,
                                baseline_fd_count=50,
                                baseline_child_count=0,
                                timeout=0.5,
                                baseline_label="warmed post-close baseline",
                            )

    def _lock_default_memory_thresholds(self):
        previous = HARNESS.MAX_RSS_TAIL_NET_GROWTH_KB
        previous_slope = HARNESS.MAX_RSS_TAIL_SLOPE_KB_PER_MINUTE
        previous_plateau = HARNESS.MAX_RSS_PLATEAU_DELTA_KB
        HARNESS.MAX_RSS_TAIL_NET_GROWTH_KB = 8192
        HARNESS.MAX_RSS_TAIL_SLOPE_KB_PER_MINUTE = 256
        HARNESS.MAX_RSS_PLATEAU_DELTA_KB = 8192
        self.addCleanup(
            lambda: (
                setattr(HARNESS, "MAX_RSS_TAIL_NET_GROWTH_KB", previous),
                setattr(HARNESS, "MAX_RSS_TAIL_SLOPE_KB_PER_MINUTE", previous_slope),
                setattr(HARNESS, "MAX_RSS_PLATEAU_DELTA_KB", previous_plateau),
            )
        )

    def test_soak_gate_ignores_post_transition_sample_for_tail_net(self):
        # WHY: a single post-soak materialization sample must not rewrite
        # rss_tail_net_growth or fd_count_delta for the steady soak gate.
        self._lock_default_memory_thresholds()
        soak = [
            {
                "elapsed_seconds": float(index),
                "rss_kb": 500_000,
                "fd_count": 100,
                "child_process_count": 10,
            }
            for index in range(20)
        ]
        transition = {
            "elapsed_seconds": 20.0,
            "rss_kb": 575_000,
            "fd_count": 101,
            "child_process_count": 8,
        }
        stats = {
            "samples": soak + [transition],
            "soak_sample_count": len(soak),
            "max_observed_dropped_output_bytes": 0,
            "max_observed_history_write_failures": 0,
        }
        HARNESS.assert_stability_gate(stats, "pre-exit")
        self.assertEqual(stats["rss_tail_net_growth_kb"], 0)
        self.assertEqual(stats["fd_count_delta"], 0)
        self.assertTrue(stats["rss_plateau_seen"])
        # Final gate after freeze is the same soak window, not a silent rebase.
        HARNESS.assert_stability_gate(stats, "final")
        self.assertEqual(stats["rss_tail_net_growth_kb"], 0)
        self.assertEqual(stats["fd_count_delta"], 0)

    def test_short_step_warmup_curve_fails_but_long_plateau_tail_passes(self):
        # WHY: repro9 (180s, pre-gate=0) saw ~22 MiB RSS steps every ~50s during
        # continuous stream scrollback fill, then false-failed the post-soak
        # memory gate. That pattern is early bounded warmup under product caps,
        # not a continuing leak: inter-step segments are flat, FD/children/pending
        # stay stable, and a longer window whose second half is plateau must PASS
        # with unchanged thresholds. A continuing 22 MiB/50s step leak must still
        # FAIL. Pre-gate does not rebaseline post-soak samples.
        self._lock_default_memory_thresholds()

        # Exact repro9 soak RSS curve (KiB) at ~10s samples.
        repro9_rss = [
            163568,
            160128,
            160656,
            161040,
            162768,
            164224,
            186400,
            186464,
            186496,
            186512,
            185392,
            207744,
            207776,
            207792,
            207824,
            207856,
            216944,
            216992,
            217056,
        ]
        short = [
            {
                "elapsed_seconds": float(index * 10),
                "rss_kb": value,
                "fd_count": 65,
                "child_process_count": 3,
            }
            for index, value in enumerate(repro9_rss)
        ]
        short_stats = {
            "samples": short,
            "soak_sample_count": len(short),
            "max_observed_dropped_output_bytes": 0,
            "max_observed_history_write_failures": 0,
        }
        with self.assertRaises(HARNESS.Failure) as short_fail:
            HARNESS.assert_stability_gate(short_stats, "post-soak")
        self.assertIn("memory gate failed", str(short_fail.exception))
        self.assertGreater(short_stats["rss_tail_net_growth_kb"], 8192)

        # Same early steps, then multi-minute plateau so the second half is flat.
        # duration math: last repro9 growth ~160s => need duration/2 > 160 so
        # duration >= ~400s; use 600s / 10s samples (tail starts at 300s).
        plateau_rss = repro9_rss + [217056] * (61 - len(repro9_rss))
        self.assertEqual(len(plateau_rss), 61)
        long_plateau = [
            {
                "elapsed_seconds": float(index * 10),
                "rss_kb": value,
                "fd_count": 65,
                "child_process_count": 3,
            }
            for index, value in enumerate(plateau_rss)
        ]
        plateau_stats = {
            "samples": long_plateau,
            "soak_sample_count": len(long_plateau),
            "max_observed_dropped_output_bytes": 0,
            "max_observed_history_write_failures": 0,
        }
        HARNESS.assert_stability_gate(plateau_stats, "post-soak")
        self.assertTrue(plateau_stats["rss_plateau_seen"])
        self.assertLessEqual(plateau_stats["rss_tail_net_growth_kb"], 8192)
        self.assertLessEqual(plateau_stats["rss_tail_slope_kb_per_minute"], 256)
        self.assertLessEqual(plateau_stats["rss_plateau_delta_kb"], 8192)

        # Continuing step growth every 50s for the full 600s must still fail.
        continuing = []
        rss = 160_000
        for index in range(61):
            if index > 0 and index % 5 == 0:
                rss += 22_000
            continuing.append(
                {
                    "elapsed_seconds": float(index * 10),
                    "rss_kb": rss,
                    "fd_count": 65,
                    "child_process_count": 3,
                }
            )
        leak_stats = {
            "samples": continuing,
            "soak_sample_count": len(continuing),
            "max_observed_dropped_output_bytes": 0,
            "max_observed_history_write_failures": 0,
        }
        with self.assertRaises(HARNESS.Failure) as leak_fail:
            HARNESS.assert_stability_gate(leak_stats, "post-soak")
        self.assertIn("memory gate failed", str(leak_fail.exception))
        self.assertFalse(leak_stats["rss_plateau_seen"])

    def test_help_documents_short_run_memory_false_fail_semantics(self):
        # WHY: controllers must not treat pre-gate=0 15-180s canaries as leak proof.
        source = Path(HARNESS.__file__).read_text()
        self.assertIn("false-fail the memory gate", source)
        self.assertIn("Does not rebaseline post-soak samples", source)
        self.assertIn("second half of the full soak sample", source)

    def test_post_soak_transition_absolute_cap_zero_fd_and_diagnostic_deltas(self):
        # WHY: transition gate is product absolute MAX_RSS_KB + zero FD growth;
        # RSS/FD deltas are diagnostic output only (no invented delta cap).
        base = {
            "elapsed_seconds": 0.0,
            "rss_kb": 500_000,
            "fd_count": 100,
            "child_process_count": 10,
        }
        soak_end = {
            "elapsed_seconds": 10.0,
            "rss_kb": 510_000,
            "fd_count": 100,
            "child_process_count": 10,
        }
        transition = {
            "elapsed_seconds": 11.0,
            "rss_kb": 510_000 + 80_000,
            "fd_count": 100,
            "child_process_count": 8,
        }
        stats = {
            "samples": [base, soak_end, transition],
            "soak_sample_count": 2,
        }
        HARNESS.assert_post_soak_transition(stats)
        self.assertEqual(stats["post_soak_rss_kb"], 510_000)
        self.assertEqual(stats["post_soak_fd_count"], 100)
        self.assertEqual(stats["post_transition_rss_kb"], 590_000)
        self.assertEqual(stats["post_transition_fd_count"], 100)
        self.assertEqual(stats["post_soak_transition_rss_delta_kb"], 80_000)
        self.assertEqual(stats["post_soak_transition_fd_delta"], 0)
        self.assertIn(
            "post_soak_transition_rss_delta_kb", HARNESS.DIAGNOSTIC_ONLY_METRICS
        )
        self.assertIn(
            "post_soak_transition_fd_delta", HARNESS.DIAGNOSTIC_ONLY_METRICS
        )

        absolute = dict(transition)
        absolute["rss_kb"] = HARNESS.MAX_RSS_KB + 1
        with self.assertRaisesRegex(HARNESS.Failure, "post-transition RSS"):
            HARNESS.assert_post_soak_transition(
                {"samples": [base, soak_end, absolute], "soak_sample_count": 2}
            )

        fd_growth = dict(transition)
        fd_growth["fd_count"] = 101
        with self.assertRaisesRegex(
            HARNESS.Failure,
            "post-soak transition sustained file descriptor growth",
        ):
            HARNESS.assert_post_soak_transition(
                {"samples": [base, soak_end, fd_growth], "soak_sample_count": 2}
            )

    def test_sample_post_soak_transition_readiness_polls_not_frozen_measurements(self):
        # WHY: unsettled collects are readiness polls (not sample window rows);
        # recorded row is the same observation that met FD settle (no TOCTOU).
        # Sticky +1 above target fails after timeout; no tolerance/rebase.
        attempts = [
            {
                "elapsed_seconds": 1.0,
                "rss_kb": 520_000,
                "cpu_percent": 1.0,
                "fd_count": 102,
                "child_process_count": 8,
                "terminal_count": 2,
                "max_output_pending_bytes": 0,
                "history_write_failures": 0,
                "dropped_output_bytes": 0,
                "max_health_rpc_latency_ms": 1.0,
            },
            {
                "elapsed_seconds": 1.25,
                "rss_kb": 521_000,
                "cpu_percent": 1.0,
                "fd_count": 100,
                "child_process_count": 8,
                "terminal_count": 2,
                "max_output_pending_bytes": 0,
                "history_write_failures": 0,
                "dropped_output_bytes": 0,
                "max_health_rpc_latency_ms": 1.0,
            },
        ]
        stats = {"samples": [], "soak_started_monotonic": 0.0}
        with mock.patch.object(HARNESS, "collect_sample", side_effect=attempts):
            with mock.patch.object(HARNESS.time, "sleep", return_value=None):
                row = HARNESS.sample_post_soak_transition(
                    1, stats, surface_ids=(), target_fd_count=100, timeout=2
                )
        self.assertEqual(row["fd_count"], 100)
        self.assertEqual(len(stats["samples"]), 1)
        self.assertIs(stats["samples"][0], row)
        self.assertEqual(stats["samples"][0]["rss_kb"], 521_000)

        sticky = {
            "elapsed_seconds": 2.0,
            "rss_kb": 522_000,
            "cpu_percent": 1.0,
            "fd_count": 101,
            "child_process_count": 8,
            "terminal_count": 2,
            "max_output_pending_bytes": 0,
            "history_write_failures": 0,
            "dropped_output_bytes": 0,
            "max_health_rpc_latency_ms": 1.0,
        }
        stuck_stats = {"samples": [], "soak_started_monotonic": 0.0}
        with mock.patch.object(HARNESS, "collect_sample", return_value=sticky):
            with mock.patch.object(
                HARNESS,
                "file_descriptor_type_counts",
                return_value={"REG": 53, "IPv4": 3},
            ):
                with mock.patch.object(HARNESS.time, "sleep", return_value=None):
                    with mock.patch.object(
                        HARNESS.time,
                        "monotonic",
                        side_effect=[0.0, 0.0, 0.5],
                    ):
                        with self.assertRaisesRegex(HARNESS.Failure, "did not settle"):
                            HARNESS.sample_post_soak_transition(
                                1,
                                stuck_stats,
                                surface_ids=(),
                                target_fd_count=100,
                                timeout=0.3,
                            )
        self.assertEqual(stuck_stats["samples"], [])


class TerminalStabilityLargeInputMarkerTests(unittest.TestCase):
    def test_runtime_markers_are_not_contiguous_in_typed_stream_source(self):
        # WHY: final5 large-input SHA mismatch followed a post-soak wait that can
        # match echoed script source for RC2_E2E_STREAM_DONE while the stream
        # child still owns the foreground PTY. Typed source must not embed the
        # wait needle contiguously; completion is proven by a done-file sentinel.
        source = Path(HARNESS.__file__).read_text()
        self.assertNotIn("print('RC2_E2E_STREAM_DONE'", source)
        self.assertNotIn('print("RC2_E2E_STREAM_DONE"', source)
        self.assertNotIn("print('RC2_E2E_STREAM_READY'", source)
        self.assertIn(
            'runtime_marker_write_line_call(\n        "RC2_E2E_STREAM_",\n        "READY"',
            source,
        )
        self.assertIn("primary_stream_producer_command(", source)
        self.assertIn("runtime_marker_write_line_call(", source)
        self.assertIn("_commit_done_sentinel(", source)
        self.assertIn("primary-stream.done", source)
        self.assertIn("wait_for_exact_file(", source)
        self.assertIn("primary_stream_done_path", source)
        self.assertIn("large_input_mismatch_diagnostics(", source)
        self.assertIn("printf 'RC2_POST_IDLE_INPUT_''OK", source)
        self.assertIn("post_idle_input_command()", source)

        stream_command = HARNESS.primary_stream_producer_command(
            repr("/tmp/trigger"),
            repr("/tmp/primary-stream.done"),
            duration_seconds=1,
        )
        self.assertNotIn("RC2_E2E_STREAM_READY", stream_command)
        self.assertNotIn("RC2_E2E_STREAM_DONE", stream_command)
        self.assertIn("_commit_done_sentinel(done)", stream_command)
        self.assertIn("os.replace(", stream_command)
        self.assertNotIn("done.write_text(", stream_command)
        self.assertIn("O_NONBLOCK", stream_command)
        self.assertIn("SIGALRM", stream_command)
        self.assertEqual(
            HARNESS.runtime_marker("RC2_E2E_STREAM_", "DONE"),
            "RC2_E2E_STREAM_DONE",
        )
        self.assertEqual(
            HARNESS.runtime_marker("RC2_E2E_STREAM_", "READY"),
            "RC2_E2E_STREAM_READY",
        )

    def test_aux_done_markers_are_split_in_workload_source(self):
        # WHY: aux READY/DONE waits share the same echo false-positive class as
        # the primary stream marker. Workload source must keep the needle split.
        source = Path(HARNESS.__file__).read_text()
        self.assertNotIn("print('RC2_AUX_{index:02d}_DONE'", source)
        self.assertNotIn("print('RC2_AUX_{index:02d}_READY'", source)
        self.assertIn(
            "python_print_runtime_marker(f\"RC2_AUX_{index:02d}_\", \"DONE\")",
            source,
        )
        self.assertIn(
            "python_print_runtime_marker(f\"RC2_AUX_{index:02d}_\", \"READY\")",
            source,
        )
        # TUI mode concatenates at runtime; typed source must stay split.
        self.assertIn("RC2_AUX_{index:02d}_' + 'DONE", source)
        for index in range(2, 6):
            ready_print = HARNESS.python_print_runtime_marker(
                f"RC2_AUX_{index:02d}_", "READY"
            )
            done_print = HARNESS.python_print_runtime_marker(
                f"RC2_AUX_{index:02d}_", "DONE"
            )
            self.assertNotIn(f"RC2_AUX_{index:02d}_READY", ready_print)
            self.assertNotIn(f"RC2_AUX_{index:02d}_DONE", done_print)
            tui_done = (
                f"sys.stdout.write('\\x1b[?1049l' + 'RC2_AUX_{index:02d}_' + 'DONE\\n')"
            )
            self.assertNotIn(f"RC2_AUX_{index:02d}_DONE", tui_done)
            self.assertEqual(
                HARNESS.runtime_marker(f"RC2_AUX_{index:02d}_", "DONE"),
                f"RC2_AUX_{index:02d}_DONE",
            )

    def test_primary_stream_done_timeout_covers_remaining_workload_only(self):
        # WHY: post-soak done-file wait must cover workload_duration minus already
        # elapsed time after trigger, not an arbitrary fixed multi-second floor.
        self.assertEqual(
            HARNESS.primary_stream_done_timeout_seconds(10, workload_seconds=30),
            25.0,
        )
        self.assertEqual(
            HARNESS.primary_stream_done_timeout_seconds(30, workload_seconds=30),
            5.0,
        )
        self.assertEqual(
            HARNESS.primary_stream_done_timeout_seconds(45, workload_seconds=30),
            5.0,
        )
        source = Path(HARNESS.__file__).read_text()
        self.assertIn("primary_stream_done_timeout_seconds(", source)
        self.assertIn("workload_started_monotonic", source)
        self.assertNotIn(
            "timeout=max(30, WORKLOAD_STABILIZATION_SECONDS + 15)",
            source,
        )

    def _extract_primary_producer_body(self, command):
        return command.split("python3 - <<'PY'\n", 1)[1].rsplit("\nPY\n", 1)[0]

    def _run_primary_producer_under_full_stdout(
        self,
        *,
        duration_seconds,
        prefill_pipe,
        timeout,
        trigger_delay=0.0,
    ):
        """Execute the real generated producer with never-drained stdout.

        WHY: unit tests that leave a 64KiB pipe empty never exercise permanent
        backpressure; live soak PTYs fill. Prefill proves the sentinel path when
        os.write only returns EAGAIN.
        """
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            trigger = tmp_path / "workload-start.trigger"
            done = tmp_path / "primary-stream.done"
            command = HARNESS.primary_stream_producer_command(
                repr(str(trigger)),
                repr(str(done)),
                duration_seconds=duration_seconds,
            )
            body = self._extract_primary_producer_body(command)
            compile(body, "<primary-stream-producer>", "exec")
            read_end, write_end = os.pipe()
            if prefill_pipe:
                os.set_blocking(write_end, False)
                try:
                    while True:
                        os.write(write_end, b"Z" * 4096)
                except BlockingIOError:
                    pass
                os.set_blocking(write_end, True)
            started = time.monotonic()
            proc = subprocess.Popen(
                [sys.executable, "-c", body],
                stdin=subprocess.DEVNULL,
                stdout=write_end,
                stderr=subprocess.PIPE,
                text=True,
            )
            os.close(write_end)
            try:
                if trigger_delay > 0:
                    time.sleep(trigger_delay)
                trigger.write_text("start\n", encoding="utf-8")
                try:
                    _, stderr = proc.communicate(timeout=timeout)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.communicate(timeout=2)
                    self.fail(
                        "producer remained blocked past hard budget under full pipe; "
                        f"done_exists={done.exists()} "
                        f"done_repr={done.read_bytes() if done.exists() else None!r}"
                    )
                elapsed = time.monotonic() - started
                self.assertEqual(proc.returncode, 0, msg=f"stderr={stderr!r}")
                # READY non-blocking attempt may spend up to ~5s when the pipe is
                # already full before the stream budget starts.
                self.assertLessEqual(
                    elapsed,
                    duration_seconds
                    + HARNESS.producer_hard_deadline_grace_seconds()
                    + 5.0
                    + 3.0,
                    f"producer overran budget: elapsed={elapsed:.3f}s",
                )
                self.assertTrue(done.exists(), "done sentinel path missing")
                self.assertEqual(done.read_bytes(), b"done\n")
                self.assertNotEqual(done.stat().st_size, 0, "empty truncated sentinel")
                return elapsed, done
            finally:
                os.close(read_end)

    def test_primary_stream_producer_exits_when_stdout_never_drains(self):
        # WHY: repro6 hung forever when print(flush=True) blocked on a full PTY
        # buffer; wall-clock checks never ran and primary-stream.done was never
        # written. Producer must exit near its budget and write the file sentinel
        # even when the peer never reads stdout. Live canary left a 0-byte done
        # file when Path.write_text truncated then died mid-write.
        self._run_primary_producer_under_full_stdout(
            duration_seconds=0.4,
            prefill_pipe=True,
            timeout=8,
        )

    def test_primary_stream_producer_sigalrm_path_commits_sentinel_under_full_stdout(self):
        # WHY: SIGALRM must force exit when the wall loop cannot; the authoritative
        # file sentinel must still appear before a strict deadline and must not
        # depend on draining stdout. A 0-byte truncated done file is a fail.
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            done = tmp_path / "primary-stream.done"
            helpers = HARNESS.time_bounded_stdout_helpers_python()
            # Long wall end, short alarm: exercises the real signal/deadline path.
            body = (
                helpers
                + f"done=Path({str(done)!r})\n"
                + "fd=_install_stdout_nonblocking()\n"
                + "_write_line_until(fd, 'RC2_E2E_STREAM_' + 'READY', time.monotonic()+2)\n"
                + "end=time.monotonic()+30\n"
                + "_arm_producer_deadline(0.35)\n"
                + "i=0\n"
                + "try:\n"
                + "    while time.monotonic()<end:\n"
                + "        _write_line_until(fd, ('Y'*200)+f'{i:06d}', end)\n"
                + "        i+=1\n"
                + "except _ProducerBudgetExpired:\n"
                + "    pass\n"
                + "finally:\n"
                + "    _commit_done_sentinel(done)\n"
                + "    try:\n"
                + "        _write_line_until(fd, 'RC2_E2E_STREAM_' + 'DONE', time.monotonic()+2)\n"
                + "    except Exception:\n"
                + "        pass\n"
            )
            compile(body, "<primary-stream-sigalrm>", "exec")
            read_end, write_end = os.pipe()
            os.set_blocking(write_end, False)
            try:
                while True:
                    os.write(write_end, b"Z" * 4096)
            except BlockingIOError:
                pass
            os.set_blocking(write_end, True)
            started = time.monotonic()
            proc = subprocess.Popen(
                [sys.executable, "-c", body],
                stdin=subprocess.DEVNULL,
                stdout=write_end,
                stderr=subprocess.PIPE,
                text=True,
            )
            os.close(write_end)
            try:
                try:
                    _, stderr = proc.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.communicate(timeout=2)
                    self.fail("SIGALRM path did not exit under full stdout")
                elapsed = time.monotonic() - started
                self.assertEqual(proc.returncode, 0, msg=f"stderr={stderr!r}")
                # READY best-effort (2s) + alarm (0.35s) + optional DONE write budget.
                self.assertLessEqual(elapsed, 5.0, f"SIGALRM exit too slow: {elapsed:.3f}s")
                self.assertEqual(done.read_bytes(), b"done\n")
            finally:
                os.close(read_end)

    def test_primary_stream_producer_command_is_valid_python_and_quoted(self):
        # WHY: live failures can be silent if the embedded heredoc body is not
        # valid Python or path quoting breaks the done Path constructor.
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            # Spaces and shell metacharacters must survive repr() embedding.
            trigger = tmp_path / "work load trigger.tmp"
            done = tmp_path / "primary stream.done"
            command = HARNESS.primary_stream_producer_command(
                repr(str(trigger)),
                repr(str(done)),
                duration_seconds=0.2,
            )
            self.assertTrue(command.startswith("python3 - <<'PY'\n"))
            self.assertTrue(command.endswith("PY\n"))
            body = self._extract_primary_producer_body(command)
            compile(body, "<primary-stream-producer-quote>", "exec")
            self.assertIn(repr(str(trigger)), body)
            self.assertIn(repr(str(done)), body)
            self.assertIn("_commit_done_sentinel(done)", body)
            # Commit must precede any best-effort PTY DONE marker in finally.
            commit_at = body.index("_commit_done_sentinel(done)")
            done_marker_at = body.index(
                "_write_line_until(fd, 'RC2_E2E_STREAM_' + 'DONE'"
            )
            self.assertLess(commit_at, done_marker_at)
            # READY must not use blocking print under a possibly full PTY.
            pre_stream = body.split("while not trigger.exists():", 1)[0]
            self.assertNotIn("print(", pre_stream)
            # Outer finally must commit the file sentinel even if READY/trigger wait aborts.
            self.assertIn("try:\n", body)
            self.assertLess(
                body.index("while not trigger.exists():"),
                body.index("_commit_done_sentinel(done)"),
            )

    def test_smoke_profile_reduces_post_soak_payloads_without_release_soak(self):
        # WHY: short canaries must reach large-input / TUI / post-close without
        # the 22k-line hidden flood and 256KiB payload that dominate wall time.
        # Release-soak must keep the heavy defaults.
        previous = (
            HARNESS.HIDDEN_LINES,
            HARNESS.LARGE_INPUT_BYTES,
            HARNESS.TUI_SECONDS,
        )
        env_keys = (
            "RC2_E2E_HIDDEN_LINES",
            "RC2_E2E_LARGE_INPUT_BYTES",
            "RC2_E2E_TUI_SECONDS",
        )
        saved_env = {key: os.environ.pop(key, None) for key in env_keys}
        try:
            HARNESS.HIDDEN_LINES = 22000
            HARNESS.LARGE_INPUT_BYTES = 256 * 1024
            HARNESS.TUI_SECONDS = 10
            smoke = HARNESS.parse_args(
                [
                    "--port",
                    "29303",
                    "--duration-seconds",
                    "15",
                    "--terminal-count",
                    "2",
                    "--pre-gate-seconds",
                    "0",
                ]
            )
            HARNESS.configure(smoke)
            self.assertLessEqual(HARNESS.HIDDEN_LINES, 800)
            self.assertLessEqual(HARNESS.LARGE_INPUT_BYTES, 32 * 1024)
            self.assertLessEqual(HARNESS.TUI_SECONDS, 3)

            HARNESS.HIDDEN_LINES = 22000
            HARNESS.LARGE_INPUT_BYTES = 256 * 1024
            HARNESS.TUI_SECONDS = 10
            release = HARNESS.parse_args(
                [
                    "--port",
                    "29303",
                    "--duration-seconds",
                    "40",
                    "--terminal-count",
                    "6",
                    "--release-soak",
                ]
            )
            HARNESS.configure(release)
            self.assertEqual(HARNESS.HIDDEN_LINES, 22000)
            self.assertEqual(HARNESS.LARGE_INPUT_BYTES, 256 * 1024)
            self.assertEqual(HARNESS.TUI_SECONDS, 10)
            self.assertGreaterEqual(release.duration_seconds, 3600)
            self.assertGreaterEqual(release.terminal_count, 12)
        finally:
            HARNESS.HIDDEN_LINES, HARNESS.LARGE_INPUT_BYTES, HARNESS.TUI_SECONDS = (
                previous
            )
            for key, value in saved_env.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value

    def test_authoritative_done_sentinel_not_matchable_from_typed_source(self):
        # WHY: completion must be a host-side file with exact content; typed/echoed
        # command text must not contain the exact file payload pattern as a
        # false-positive substitute for wait_for_exact_file.
        command = HARNESS.primary_stream_producer_command(
            repr("/tmp/trigger"),
            repr("/tmp/primary-stream.done"),
            duration_seconds=1,
        )
        self.assertIn("_commit_done_sentinel(done)", command)
        self.assertNotIn("RC2_E2E_STREAM_DONE", command)
        # File sentinel path appears, but wait needle is host-side exact content.
        self.assertIn("primary-stream.done", command)
        self.assertEqual(
            HARNESS.runtime_marker("RC2_E2E_STREAM_", "DONE"),
            "RC2_E2E_STREAM_DONE",
        )
        # Harness proves completion only via wait_for_exact_file equality to
        # "done\\n", not substring search of terminal snapshots for that token alone.
        source = Path(HARNESS.__file__).read_text()
        self.assertIn('description="primary stream producer completion"', source)
        self.assertIn("wait_for_exact_file(", source)
        self.assertIn("primary_stream_done_path", source)

    def test_aux_stream_and_burst_producers_use_time_bounded_writes(self):
        # WHY: aux stream/burst/tui share the same blocking-print failure class
        # under multi-terminal PTY backpressure; must use the shared helpers.
        source = Path(HARNESS.__file__).read_text()
        self.assertIn("time_bounded_stdout_helpers_python()", source)
        self.assertIn("_install_stdout_nonblocking", source)
        self.assertIn("_write_line_until", source)
        self.assertIn("_arm_producer_deadline", source)
        # Idle may sleep; stream/burst/tui must not use bare print(flush) loops.
        self.assertNotIn(
            "print(f'RC2_E2E_STREAM_{i:06d}', flush=True)",
            source,
        )
        self.assertNotIn(
            "print(f'RC2_AUX_{index:02d}_STREAM_{i:06d}', flush=True)",
            source,
        )

    def test_large_input_mismatch_diagnostics_are_privacy_safe(self):
        # WHY: disposable runs may keep the received artifact for triage, but
        # public evidence may only expose lengths, hashes, and first-diff offset.
        expected = HARNESS.deterministic_large_input_bytes(256)
        actual = bytearray(expected)
        actual[17] ^= 0x01
        path = Path(HARNESS.tempfile.mkdtemp()) / "large-input.txt"
        self.addCleanup(lambda: HARNESS.shutil.rmtree(path.parent, ignore_errors=True))
        path.write_bytes(bytes(actual))

        diagnostics = HARNESS.large_input_mismatch_diagnostics(path, expected)
        self.assertEqual(diagnostics["expected_len"], 256)
        self.assertEqual(diagnostics["actual_len"], 256)
        self.assertEqual(
            diagnostics["expected_sha256"],
            HARNESS.hashlib.sha256(expected).hexdigest(),
        )
        self.assertEqual(
            diagnostics["actual_sha256"],
            HARNESS.hashlib.sha256(bytes(actual)).hexdigest(),
        )
        self.assertEqual(diagnostics["first_diff_offset"], 17)
        self.assertIsNone(diagnostics["read_error"])
        rendered = json.dumps(diagnostics)
        self.assertNotIn(expected.decode("ascii")[:32], rendered)
        self.assertNotIn(str(path), rendered)

    def test_post_soak_waits_for_primary_stream_done_file_before_large_input(self):
        # WHY: large input must not be typed while the soak stream child still
        # owns stdin; the done-file wait must precede post-idle and large input.
        source = Path(HARNESS.__file__).read_text()
        main = source.split("def main():", 1)[1]
        stream_done_file = main.index(
            'description="primary stream producer completion"'
        )
        post_idle = main.index("post_idle_input_command()")
        large_input = main.index("deterministic_large_input_bytes(LARGE_INPUT_BYTES)")
        self.assertLess(stream_done_file, post_idle)
        self.assertLess(post_idle, large_input)

    def test_post_idle_input_command_terminator_and_split_marker(self):
        # WHY: live repro left printf unevaluated because the terminator was
        # literal backslash-n (no Enter). Contiguous RC2_POST_IDLE_INPUT_OK in
        # typed source would also false-match wait_snapshot before execution.
        command = HARNESS.post_idle_input_command()
        self.assertTrue(command.endswith("\n"), "command must end with byte newline (Enter)")
        self.assertFalse(
            command.endswith("\\n"),
            "command must not end with literal backslash+n",
        )
        self.assertNotIn("RC2_POST_IDLE_INPUT_OK", command)
        self.assertIn("RC2_POST_IDLE_INPUT_''OK", command)
        self.assertEqual(
            HARNESS.runtime_marker("RC2_POST_IDLE_INPUT_", "OK"),
            "RC2_POST_IDLE_INPUT_OK",
        )
        completed = subprocess.run(
            ["bash", "-lc", command],
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertEqual(completed.stdout, "RC2_POST_IDLE_INPUT_OK\n")


class TerminalStabilityChildExitGateTests(unittest.TestCase):
    def test_wait_for_process_exited_polls_alive_to_dead(self):
        # WHY: fixed sleep+single sample races intentional HUP/TERM-ignoring
        # background children; gate must poll until the exact exit contract.
        responses = [
            {
                "alive": True,
                "terminal_dead_reason": None,
                "child_pid": 14089,
                "process_alive": True,
            },
            {
                "alive": True,
                "terminal_dead_reason": None,
                "child_pid": 14089,
                "process_alive": True,
            },
            {
                "alive": False,
                "terminal_dead_reason": "process_exited",
                "child_pid": None,
                "process_alive": False,
            },
        ]
        with mock.patch.object(HARNESS, "rpc", side_effect=responses) as rpc:
            with mock.patch.object(HARNESS.time, "sleep", return_value=None):
                dead = HARNESS.wait_for_process_exited("surface-1", timeout=2)
        self.assertIs(dead["alive"], False)
        self.assertEqual(dead["terminal_dead_reason"], "process_exited")
        self.assertEqual(rpc.call_count, 3)
        self.assertEqual(
            rpc.call_args_list[0].args,
            ("surface.health", {"id": "surface-1"}),
        )

    def test_wait_for_process_exited_timeout_rejects_wrong_dead_reason(self):
        # WHY: contract is exact process_exited only; other dead reasons must
        # never satisfy the gate (timeout with last privacy-safe health).
        wrong = {
            "alive": False,
            "terminal_dead_reason": "pty_eof",
            "child_pid": None,
            "process_alive": False,
            "input_accepting": False,
        }
        with mock.patch.object(HARNESS, "rpc", return_value=wrong):
            with mock.patch.object(HARNESS.time, "sleep", return_value=None):
                with mock.patch.object(
                    HARNESS.time,
                    "monotonic",
                    side_effect=[0.0, 0.0, 0.5],
                ):
                    with self.assertRaisesRegex(
                        HARNESS.Failure,
                        r"child exit did not mark dead: .*'terminal_dead_reason': 'pty_eof'",
                    ) as ctx:
                        HARNESS.wait_for_process_exited("surface-1", timeout=0.3)
        message = str(ctx.exception)
        self.assertIn("pty_eof", message)
        self.assertNotIn("process_exited", message)
        # Health object only: no terminal snapshot/content fields.
        self.assertNotIn("snapshot", message)
        self.assertNotIn("ansi", message)

    def test_main_uses_process_exited_wait_not_fixed_sleep(self):
        # WHY: repro3 failed after sleep(1) while shell still alive; main must
        # condition-wait, then still assert send-after-exit process_exited.
        # Builtin exit is rejected: interactive zsh can refuse with jobs present.
        source = Path(HARNESS.__file__).read_text()
        self.assertNotIn(
            'send_text(primary_sid, "exit\\n")\n        time.sleep(1)',
            source,
        )
        self.assertIn("def wait_for_process_exited(", source)
        main = source.split("def main():", 1)[1]
        # Must not fall back to shell-job-control exit (or double exit).
        self.assertNotIn('send_text(primary_sid, "exit\\n")', main)
        self.assertNotIn('send_text(primary_sid, "exit\\nexit\\n")', main)
        exit_send = main.index("send_text(primary_sid, foreground_child_exit_command())")
        wait = main.index("wait_for_process_exited(")
        after_exit = main.index('send_text(primary_sid, "pwd\\n")')
        self.assertLess(exit_send, wait)
        self.assertLess(wait, after_exit)
        after_block = main[after_exit : after_exit + 280]
        self.assertIn('status") != "process_exited"', after_block)
        # Orphan reaping is workspace-close driven; no preemptive group kill.
        recovery = main.index("wait_for_process_tree_cleanup(")
        self.assertLess(after_exit, recovery)
        pre_recovery = main[exit_send:recovery]
        self.assertNotIn("os.killpg", pre_recovery)
        self.assertNotIn("killpg", pre_recovery)
        self.assertNotIn("SIGKILL", pre_recovery)
        self.assertNotIn("time.sleep(", pre_recovery)

    def test_foreground_child_exit_command_is_exec_true(self):
        # WHY: must be deterministic process replacement, not shell builtin exit
        # (zsh job control can refuse exit while HUP/TERM-ignoring bg jobs live).
        command = HARNESS.foreground_child_exit_command()
        self.assertEqual(command, "exec /usr/bin/true\n")
        self.assertTrue(command.endswith("\n"), "must end with real Enter")
        self.assertNotIn("exit", command)
        self.assertNotIn("sleep", command)
        self.assertNotIn("kill", command)

    def test_foreground_child_exit_command_semantics_leave_background(self):
        # WHY: exec replaces the shell (exit 0) while a stubborn background
        # descendant remains for later reaper proof — the harness intent.
        # Bg stdio is redirected so pipe EOF is not held open (PTY harness is
        # unaffected; this is only for the unit subprocess proof).
        import tempfile

        command = HARNESS.foreground_child_exit_command().rstrip("\n")
        self.assertEqual(command, "exec /usr/bin/true")
        with tempfile.TemporaryDirectory() as tmp:
            out_path = Path(tmp) / "bg.txt"
            heartbeat_path = Path(tmp) / "heartbeat"
            # Bg process writes its pid + heartbeat file so we can prove identity
            # without sandboxed `ps` listing.
            shell = subprocess.Popen(
                [
                    "zsh",
                    "-c",
                    (
                        "python3 -c \"import os,signal,time,pathlib; "
                        "signal.signal(signal.SIGHUP, signal.SIG_IGN); "
                        "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
                        f"pathlib.Path({str(heartbeat_path)!r}).write_text(str(os.getpid())); "
                        "time.sleep(60)\" "
                        ">/dev/null 2>&1 &\n"
                        "bg_pid=$!\n"
                        f"printf 'BG:%s\\n' \"$bg_pid\" > {out_path}\n"
                        f"{command}\n"
                    ),
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
            try:
                shell.wait(timeout=5)
                self.assertEqual(shell.returncode, 0)
                bg_line = out_path.read_text().strip()
                self.assertRegex(bg_line, r"^BG:\d+$")
                bg_pid = int(bg_line.split(":", 1)[1])
                # Shell PID must not still be the live process (exec replaced it).
                self.assertNotEqual(shell.pid, bg_pid)
                # Background descendant remains after foreground shell exit.
                os.kill(bg_pid, 0)
                # Heartbeat identity: same pid the bg python recorded.
                for _ in range(20):
                    if heartbeat_path.exists():
                        break
                    time.sleep(0.05)
                self.assertTrue(heartbeat_path.exists(), "bg process did not record heartbeat")
                self.assertEqual(heartbeat_path.read_text().strip(), str(bg_pid))
            finally:
                # Cleanup only after leave-alive assertions; not harness product path.
                try:
                    if out_path.exists():
                        text = out_path.read_text().strip()
                        if text.startswith("BG:"):
                            os.kill(int(text.split(":", 1)[1]), 9)
                except (ProcessLookupError, ValueError, OSError):
                    pass


if __name__ == "__main__":
    unittest.main()
