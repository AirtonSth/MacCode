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


if __name__ == "__main__":
    unittest.main()
