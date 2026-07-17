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


if __name__ == "__main__":
    unittest.main()
