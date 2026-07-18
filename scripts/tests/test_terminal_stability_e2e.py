import importlib.util
import json
import socket
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
        # Post-close recovery stays absolute vs pre-workspace baseline.
        source = Path(HARNESS.__file__).read_text()
        main = source.split("def main():", 1)[1]
        post_soak = main.index('assert_stability_gate(stats, "post-soak")')
        freeze = main.index('stats["soak_sample_count"] = len(stats["samples"])')
        hidden_drain = main.index('stats["hidden_output_drained"] = True')
        transition_sample = main.index("sample_post_soak_transition(")
        transition = main.index("assert_post_soak_transition(stats)")
        pre_exit = main.index('assert_stability_gate(stats, "pre-exit")')
        recovery = main.index("wait_for_resource_recovery(")
        self.assertLess(post_soak, freeze)
        self.assertLess(freeze, hidden_drain)
        self.assertLess(hidden_drain, transition_sample)
        self.assertLess(transition_sample, transition)
        self.assertLess(transition, pre_exit)
        self.assertLess(pre_exit, recovery)
        # No invented transition-delta product gate/env.
        self.assertNotIn("max_post_soak_transition_rss_delta_kb", main)
        self.assertNotIn("MAX_POST_SOAK_TRANSITION_RSS_DELTA_KB", source)
        self.assertNotIn("RC2_E2E_MAX_POST_SOAK_TRANSITION_RSS_DELTA_KB", source)
        self.assertNotIn("_PROCESS_RSS_BYTES_PER_PAYLOAD_BYTE", source)
        recovery_block = main[recovery : recovery + 400]
        self.assertIn('pre_workspace_resources["rss_kb"]', recovery_block)
        self.assertIn('pre_workspace_resources["fd_count"]', recovery_block)
        self.assertNotIn("wait_for_fd_settle(", main)
        self.assertNotIn(
            "sample(pid, stats, all_surface_ids)\n        assert_post_soak_transition",
            main,
        )

    def test_soak_gate_ignores_post_transition_sample_for_tail_net(self):
        # WHY: a single post-soak materialization sample must not rewrite
        # rss_tail_net_growth or fd_count_delta for the steady soak gate.
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


if __name__ == "__main__":
    unittest.main()
