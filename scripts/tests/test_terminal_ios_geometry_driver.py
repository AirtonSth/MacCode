import contextlib
import hashlib
import importlib.util
import io
import json
import os
import queue
import socket
import sys
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "terminal-ios-geometry-driver.py"
SPEC = importlib.util.spec_from_file_location("terminal_ios_geometry_driver", SCRIPT)
DRIVER = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(DRIVER)


def server_frame(opcode, payload):
    if len(payload) < 126:
        return bytes([0x80 | opcode, len(payload)]) + payload
    return bytes([0x80 | opcode, 126]) + len(payload).to_bytes(2, "big") + payload


class BlockingControlSocket:
    def __init__(self):
        self.received = queue.Queue()
        self.sent = []
        self.closed = False

    def settimeout(self, _timeout):
        pass

    def recv(self, _size):
        try:
            return self.received.get(timeout=1)
        except queue.Empty as exc:
            raise socket.timeout from exc

    def sendall(self, value):
        self.sent.append(value)

    def shutdown(self, _how):
        pass

    def close(self):
        if not self.closed:
            self.closed = True
            self.received.put(b"")


def welcome_frame(connection_id="connection-1", host_id="host-1", boot_epoch=7):
    return server_frame(0x1, json.dumps({
        "protocolVersion": 3,
        "type": "welcome",
        "connectionId": connection_id,
        "hostId": host_id,
        "bootEpoch": boot_epoch,
        "serverTimeEpochMs": 1,
        "heartbeatIntervalMs": 5_000,
        "heartbeatTimeoutMs": 10_000,
        "currentSequence": 0,
        "oldestReplaySequence": 0,
        "capabilities": ["snapshot.v3"],
    }).encode())


def snapshot_result(connection_id="connection-1", host_id="host-1", boot_epoch=7):
    return {
        "protocolVersion": 3,
        "type": "snapshot",
        "connectionId": connection_id,
        "hostId": host_id,
        "bootEpoch": boot_epoch,
        "sequence": 0,
        "snapshotId": "snapshot-1",
        "generatedAtEpochMs": 1,
        "stateVersion": 3,
        "state": {},
    }


def decoded_masked_control_payload(frame):
    payload_length = frame[1] & 0x7F
    mask = frame[2:6]
    payload = frame[6:6 + payload_length]
    return bytes(
        value ^ mask[index % 4]
        for index, value in enumerate(payload)
    )


class TerminalIOSGeometryDriverValidationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        base = Path(self.temporary.name)
        self.sync_dir = base / "sync"
        self.sync_dir.mkdir()
        self.canary_root = base / "RemoteCodeAgentCanary-unit-test"
        self.executable = (
            self.canary_root
            / "app"
            / "RemoteCodeAgentCanary.app"
            / "Contents"
            / "MacOS"
            / "RemoteCodeAgentCanary"
        )
        self.executable.parent.mkdir(parents=True)
        self.executable.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        self.executable.chmod(0o755)
        pid_directory = self.canary_root / "run"
        pid_directory.mkdir()
        self.pid = 91_337
        (pid_directory / "RemoteCodeAgentCanary.pid").write_text(
            f"{self.pid}\n",
            encoding="utf-8",
        )

    def test_mirror_values_bind_identity_without_wrapping_output_marker(self):
        # WHY: the iOS proof must observe the real rendered line. A long output
        # marker wraps into multiple AX text nodes and creates a false timeout;
        # request/path metadata separately binds the full nonce.
        nonce = "A" * 32
        output = DRIVER.expected_mirror_value(nonce, "output", 7)
        title = DRIVER.expected_mirror_value(nonce, "title", 7) + ("B" * 32)

        self.assertEqual(output, "RC2O_AAAAAAAAAAAAAAAA_007")
        self.assertEqual(len(output), 25)
        self.assertTrue(DRIVER.mirror_value_matches(nonce, "output", 7, output))
        self.assertFalse(DRIVER.mirror_value_matches(nonce, "output", 8, output))
        self.assertTrue(DRIVER.mirror_value_matches(nonce, "title", 7, title))
        self.assertFalse(DRIVER.mirror_value_matches(nonce, "title", 7, title[:-1]))

    def argv(self, port):
        return [
            str(SCRIPT),
            "--sync-dir",
            str(self.sync_dir),
            "--host",
            "127.0.0.1",
            "--port",
            str(port),
            "--run-id",
            "unit-run",
            "--profile",
            "unit-profile",
            "--canary-root",
            str(self.canary_root),
            "--canary-pid",
            str(self.pid),
            "--workspace-id",
            "11111111-1111-4111-8111-111111111111",
            "--surface-id",
            "22222222-2222-4222-8222-222222222222",
            "--split-id",
            "33333333-3333-4333-8333-333333333333",
            "--renderer-mode",
            "fixed_grid",
            "--validate-only",
        ]

    def run_main(self, port, listener_pids=None, environment=None):
        output = io.StringIO()
        loaded = [str(self.executable.resolve()), "/usr/lib/dyld"]
        with mock.patch.object(sys, "argv", self.argv(port)), \
             mock.patch.dict(
                 os.environ,
                 environment or {"RC2_PRIMARY_PORT": "18217"},
                 clear=False,
             ), \
             mock.patch.object(DRIVER, "loaded_executable_paths", return_value=loaded), \
             mock.patch.object(
                 DRIVER,
                 "listener_pids",
                 return_value={self.pid} if listener_pids is None else listener_pids,
             ), \
             mock.patch.object(DRIVER, "rpc") as mutating_rpc, \
             contextlib.redirect_stdout(output):
            DRIVER.main()
        return output.getvalue(), mutating_rpc

    def matches_identity_with_canary_root(self, canary_root):
        args = SimpleNamespace(
            run_id="unit-run",
            host="127.0.0.1",
            port=28_217,
            profile="unit-profile",
            canary_root=self.canary_root.resolve(strict=True),
            canary_pid=self.pid,
            workspace_id="11111111-1111-4111-8111-111111111111",
            surface_id="22222222-2222-4222-8222-222222222222",
            split_id="33333333-3333-4333-8333-333333333333",
        )
        value = {
            "mode": DRIVER.GEOMETRY_MODE,
            "runID": args.run_id,
            "host": args.host,
            "port": args.port,
            "profile": args.profile,
            "canaryRoot": canary_root,
            "canaryPID": args.canary_pid,
            "workspaceID": args.workspace_id,
            "surfaceID": args.surface_id,
            "splitID": args.split_id,
        }
        return DRIVER.matching_identity(args, value, DRIVER.GEOMETRY_MODE)

    def test_validate_only_accepts_exact_pid_executable_and_listener_without_rpc(self):
        output, mutating_rpc = self.run_main(28_217)

        payload = json.loads(output)
        self.assertEqual(payload["canary_pid"], self.pid)
        self.assertEqual(payload["renderer_mode"], "fixed_grid")
        self.assertEqual(payload["expected_output_ax_role"], "StaticText")
        self.assertTrue(payload["listener_owner_verified"])
        mutating_rpc.assert_not_called()

    def test_identity_accepts_existing_canary_root_through_ancestor_symlink_alias(self):
        alias_parent = Path(self.temporary.name) / "canary-root-alias"
        alias_parent.symlink_to(self.canary_root.parent, target_is_directory=True)

        self.assertTrue(
            self.matches_identity_with_canary_root(
                str(alias_parent / self.canary_root.name)
            )
        )

    def test_identity_rejects_different_missing_and_relative_canary_roots(self):
        different = Path(self.temporary.name) / "RemoteCodeAgentCanary-different"
        different.mkdir()
        candidates = [
            str(different),
            str(Path(self.temporary.name) / "RemoteCodeAgentCanary-missing"),
            self.canary_root.name,
        ]

        for candidate in candidates:
            with self.subTest(candidate=candidate):
                self.assertFalse(self.matches_identity_with_canary_root(candidate))

    def test_validate_only_rejects_default_and_environment_primary_ports_without_rpc(self):
        cases = [
            (18_217, {"RC2_PRIMARY_PORT": "18217"}),
            (28_217, {"RC2_PRIMARY_PORT": "28217"}),
        ]
        for port, environment in cases:
            with self.subTest(port=port, environment=environment):
                with mock.patch.object(sys, "argv", self.argv(port)), \
                     mock.patch.dict(os.environ, environment, clear=False), \
                     mock.patch.object(DRIVER, "rpc") as mutating_rpc:
                    with self.assertRaisesRegex(
                        DRIVER.Failure,
                        "refusing primary/default RemoteCode port",
                    ):
                        DRIVER.main()
                mutating_rpc.assert_not_called()

    def test_validate_only_rejects_wrong_listener_owner_without_rpc(self):
        loaded = [str(self.executable.resolve()), "/usr/lib/dyld"]
        with mock.patch.object(sys, "argv", self.argv(28_217)), \
             mock.patch.dict(os.environ, {"RC2_PRIMARY_PORT": "18217"}, clear=False), \
             mock.patch.object(DRIVER, "loaded_executable_paths", return_value=loaded), \
             mock.patch.object(DRIVER, "listener_pids", return_value={self.pid + 1}), \
             mock.patch.object(DRIVER, "rpc") as mutating_rpc:
            with self.assertRaisesRegex(
                DRIVER.Failure,
                "configured port listener owner is not exactly the canary PID",
            ):
                DRIVER.main()
        mutating_rpc.assert_not_called()

    def test_validate_only_rejects_wrong_primary_executable_without_rpc(self):
        loaded = [
            "/Applications/MacCode.app/Contents/MacOS/RemoteCode",
            str(self.executable.resolve()),
            "/usr/lib/dyld",
        ]
        with mock.patch.object(sys, "argv", self.argv(28_217)), \
             mock.patch.dict(os.environ, {"RC2_PRIMARY_PORT": "18217"}, clear=False), \
             mock.patch.object(DRIVER, "loaded_executable_paths", return_value=loaded), \
             mock.patch.object(DRIVER, "listener_pids", return_value={self.pid}), \
             mock.patch.object(DRIVER, "rpc") as mutating_rpc:
            with self.assertRaisesRegex(
                DRIVER.Failure,
                "canary PID primary executable is not the exact canary executable",
            ):
                DRIVER.main()
        mutating_rpc.assert_not_called()

    def test_validate_only_rejects_pid_not_derived_from_canary_pidfile_without_rpc(self):
        (self.canary_root / "run" / "RemoteCodeAgentCanary.pid").write_text(
            f"{self.pid + 1}\n",
            encoding="utf-8",
        )
        with mock.patch.object(sys, "argv", self.argv(28_217)), \
             mock.patch.dict(os.environ, {"RC2_PRIMARY_PORT": "18217"}, clear=False), \
             mock.patch.object(DRIVER, "rpc") as mutating_rpc:
            with self.assertRaisesRegex(
                DRIVER.Failure,
                "canary pidfile does not match --canary-pid",
            ):
                DRIVER.main()
        mutating_rpc.assert_not_called()

    def test_atomic_protocol_write_never_overwrites_existing_evidence(self):
        target = self.sync_dir / "geometry-stale.result.json"
        DRIVER.atomic_write_json(target, {"generation": 1})

        with self.assertRaisesRegex(
            DRIVER.Failure,
            "refusing to overwrite protocol file",
        ):
            DRIVER.atomic_write_json(target, {"generation": 2})

        self.assertEqual(json.loads(target.read_text(encoding="utf-8")), {"generation": 1})

    def test_active_display_preflight_accepts_one_active_display(self):
        DRIVER.require_active_display(lambda: 1)

    def test_screen_lock_preflight_accepts_real_unlocked_ioreg_shape(self):
        # WHY: macOS omits CGSSessionScreenIsLocked for an unlocked console.
        # Treating that valid shape as unreadable blocks the real iOS mirror
        # proof precisely when the user has made the display available.
        unlocked_ioreg = (
            '"IOConsoleUsers" = ({'
            '"kCGSSessionOnConsoleKey"=Yes,'
            '"kCGSessionLoginDoneKey"=Yes,'
            '"kCGSSessionUserNameKey"="test"'
            '})'
        )
        completed = SimpleNamespace(returncode=0, stdout=unlocked_ioreg)

        with mock.patch.object(DRIVER.subprocess, "run", return_value=completed):
            self.assertFalse(DRIVER.screen_is_locked())

    def test_screen_lock_preflight_fails_loud_when_console_state_is_unreadable(self):
        completed = SimpleNamespace(returncode=0, stdout='"IOConsoleUsers" = ()')

        with mock.patch.object(DRIVER.subprocess, "run", return_value=completed):
            with self.assertRaisesRegex(
                DRIVER.Failure,
                "could not query macOS screen-lock state",
            ):
                DRIVER.screen_is_locked()

    def test_active_display_preflight_rejects_zero_before_any_host_call(self):
        args = SimpleNamespace()
        with mock.patch.object(DRIVER, "screen_is_locked", return_value=False), \
             mock.patch.object(DRIVER, "active_display_count", return_value=0), \
             mock.patch.object(DRIVER, "pane_split") as pane_split, \
             mock.patch.object(DRIVER, "terminal_geometry") as terminal_geometry, \
             mock.patch.object(DRIVER, "RemoteMutationController") as controller:
            with self.assertRaisesRegex(
                DRIVER.Failure,
                "active macOS display is required before terminal geometry proof",
            ):
                DRIVER.run_protocol(args)

        pane_split.assert_not_called()
        terminal_geometry.assert_not_called()
        controller.assert_not_called()

    def test_screen_lock_preflight_rejects_locked_with_active_display_before_host_call(self):
        args = SimpleNamespace()
        with mock.patch.object(DRIVER, "screen_is_locked", return_value=True), \
             mock.patch.object(DRIVER, "active_display_count", return_value=1), \
             mock.patch.object(DRIVER, "pane_split") as pane_split, \
             mock.patch.object(DRIVER, "terminal_geometry") as terminal_geometry, \
             mock.patch.object(DRIVER, "RemoteMutationController") as controller:
            with self.assertRaisesRegex(
                DRIVER.Failure,
                "unlocked macOS screen is required before terminal geometry proof",
            ):
                DRIVER.run_protocol(args)

        pane_split.assert_not_called()
        terminal_geometry.assert_not_called()
        controller.assert_not_called()


class TerminalIOSGeometryDriverMutationIdentityTests(unittest.TestCase):
    def args(self):
        return SimpleNamespace(host="127.0.0.1", port=28_217)

    def test_remote_mutation_uses_snapshot_bound_live_identity(self):
        control_socket = BlockingControlSocket()
        calls = []

        def rpc(_args, method, params=None):
            calls.append((method, params))
            if method == "sync.snapshot":
                return snapshot_result()
            return {"accepted": True, "status": "accepted"}

        with mock.patch.object(
            DRIVER,
            "open_control_websocket",
            return_value=(control_socket, bytearray(welcome_frame())),
        ), mock.patch.object(DRIVER, "rpc", side_effect=rpc):
            controller = DRIVER.RemoteMutationController(self.args())
            try:
                result = controller.mutate(
                    "pane.resize",
                    {"workspace_id": "workspace-1", "split_id": "split-1", "ratios": [1.0]},
                )
                control_socket.received.put(server_frame(0x9, b"ping-nonce"))
                deadline = time.monotonic() + 1
                while not control_socket.sent and time.monotonic() < deadline:
                    time.sleep(0.001)
            finally:
                controller.close()

        self.assertTrue(result["accepted"])
        self.assertEqual(calls[0], (
            "sync.snapshot",
            {
                "connectionId": "connection-1",
                "expectedHostId": "host-1",
                "expectedBootEpoch": 7,
                "supportedStateVersion": 3,
            },
        ))
        mutation_method, mutation_params = calls[1]
        self.assertEqual(mutation_method, "pane.resize")
        self.assertEqual(mutation_params["connection_id"], "connection-1")
        self.assertEqual(mutation_params["expected_host_id"], "host-1")
        self.assertEqual(mutation_params["expected_boot_epoch"], 7)
        self.assertRegex(
            mutation_params["client_request_id"],
            r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
        )
        self.assertEqual(mutation_params["workspace_id"], "workspace-1")
        self.assertEqual(control_socket.sent[0][0], 0x8A)
        self.assertTrue(control_socket.sent[0][1] & 0x80)
        self.assertEqual(
            decoded_masked_control_payload(control_socket.sent[0]),
            b"ping-nonce",
        )
        self.assertTrue(control_socket.closed)

    def test_disconnect_forces_new_welcome_and_snapshot_before_next_mutation(self):
        first_socket = BlockingControlSocket()
        second_socket = BlockingControlSocket()
        calls = []

        def rpc(_args, method, params=None):
            calls.append((method, dict(params or {})))
            if method == "sync.snapshot":
                return snapshot_result(
                    connection_id=params["connectionId"],
                    host_id=params["expectedHostId"],
                    boot_epoch=params["expectedBootEpoch"],
                )
            return {"accepted": True}

        connections = [
            (first_socket, bytearray(welcome_frame("connection-1"))),
            (second_socket, bytearray(welcome_frame("connection-2"))),
        ]
        with mock.patch.object(
            DRIVER,
            "open_control_websocket",
            side_effect=connections,
        ), mock.patch.object(DRIVER, "rpc", side_effect=rpc):
            controller = DRIVER.RemoteMutationController(self.args())
            try:
                controller.mutate("surface.send_text", {"id": "surface-1", "text": "one"})
                first_socket.received.put(b"")
                deadline = time.monotonic() + 1
                while controller.identity is not None and time.monotonic() < deadline:
                    time.sleep(0.001)
                controller.mutate("surface.send_text", {"id": "surface-1", "text": "two"})
            finally:
                controller.close()

        snapshots = [params for method, params in calls if method == "sync.snapshot"]
        mutations = [params for method, params in calls if method == "surface.send_text"]
        self.assertEqual([value["connectionId"] for value in snapshots], [
            "connection-1", "connection-2",
        ])
        self.assertEqual([value["connection_id"] for value in mutations], [
            "connection-1", "connection-2",
        ])
        self.assertNotEqual(
            mutations[0]["client_request_id"],
            mutations[1]["client_request_id"],
        )

    def test_masked_pong_preserves_exact_ping_payload(self):
        with mock.patch.object(DRIVER.os, "urandom", return_value=b"\x01\x02\x03\x04"):
            frame = DRIVER.masked_client_frame(0xA, b"ping-nonce")

        self.assertEqual(frame[0], 0x8A)
        self.assertTrue(frame[1] & 0x80)
        payload_length = frame[1] & 0x7F
        self.assertEqual(payload_length, len(b"ping-nonce"))
        mask = frame[2:6]
        decoded = bytes(
            value ^ mask[index % 4]
            for index, value in enumerate(frame[6:])
        )
        self.assertEqual(decoded, b"ping-nonce")

    def test_validate_only_never_constructs_remote_mutation_controller(self):
        validation = TerminalIOSGeometryDriverValidationTests("runTest")
        validation.setUp()
        self.addCleanup(validation.doCleanups)
        loaded = [str(validation.executable.resolve()), "/usr/lib/dyld"]
        output = io.StringIO()
        with mock.patch.object(sys, "argv", validation.argv(28_217)), \
             mock.patch.dict(os.environ, {"RC2_PRIMARY_PORT": "18217"}, clear=False), \
             mock.patch.object(DRIVER, "loaded_executable_paths", return_value=loaded), \
             mock.patch.object(DRIVER, "listener_pids", return_value={validation.pid}), \
             mock.patch.object(DRIVER, "RemoteMutationController") as controller, \
             mock.patch.object(DRIVER, "rpc") as rpc, \
             contextlib.redirect_stdout(output):
            DRIVER.main()

        controller.assert_not_called()
        rpc.assert_not_called()
        self.assertEqual(
            json.loads(output.getvalue())["mutation_control"],
            "remote_ws_snapshot_v3",
        )


class TerminalIOSGeometryDriverProofContractTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        # matching_identity canonicalizes canary roots; fixtures must too.
        self.sync_dir = Path(self.temporary.name).resolve(strict=True)
        self.args = SimpleNamespace(
            host="127.0.0.1",
            port=28_217,
            run_id="proof-run",
            profile="proof-profile",
            canary_root=self.sync_dir,
            canary_pid=91_337,
            workspace_id="11111111-1111-4111-8111-111111111111",
            surface_id="22222222-2222-4222-8222-222222222222",
            split_id="33333333-3333-4333-8333-333333333333",
            sync_dir=self.sync_dir,
            ratio_delta=0.04,
            renderer_mode="fixed_grid",
        )

    def pane_rows(self):
        return [
            {
                "kind": "pane",
                "id": "pane-1",
                "surface_ids": [self.args.surface_id],
                "selected_surface_id": self.args.surface_id,
            },
            {
                "kind": "pane",
                "id": "pane-2",
                "surface_ids": ["44444444-4444-4444-8444-444444444444"],
                "selected_surface_id": "44444444-4444-4444-8444-444444444444",
            },
            {
                "kind": "split",
                "id": self.args.split_id,
                "orientation": "horizontal",
                "ratios": [0.5, 0.5],
            },
        ]

    def test_pane_layout_requires_one_configured_split_and_selected_target(self):
        with mock.patch.object(DRIVER, "rpc", return_value=self.pane_rows()):
            layout = DRIVER.pane_layout(self.args)

        self.assertEqual(layout, {
            "orientation": "horizontal",
            "ratios": [0.5, 0.5],
            "target_pane_id": "pane-1",
        })

        invalid_cases = []
        multiple = self.pane_rows()
        multiple.append({
            "kind": "split",
            "id": "55555555-5555-4555-8555-555555555555",
            "orientation": "vertical",
            "ratios": [0.5, 0.5],
        })
        invalid_cases.append((multiple, "exactly the configured split"))
        unselected = self.pane_rows()
        unselected[0] = dict(unselected[0], selected_surface_id=None)
        invalid_cases.append((unselected, "must be selected"))
        for rows, message in invalid_cases:
            with self.subTest(message=message), \
                 mock.patch.object(DRIVER, "rpc", return_value=rows):
                with self.assertRaisesRegex(DRIVER.Failure, message):
                    DRIVER.pane_layout(self.args)

    def test_geometry_transition_is_orientation_specific(self):
        self.assertTrue(DRIVER.geometry_transition_matches((40, 120), (40, 126), "horizontal"))
        self.assertFalse(DRIVER.geometry_transition_matches((40, 120), (42, 120), "horizontal"))
        self.assertTrue(DRIVER.geometry_transition_matches((40, 120), (42, 120), "vertical"))
        self.assertFalse(DRIVER.geometry_transition_matches((40, 120), (40, 126), "vertical"))

    def test_output_command_keeps_real_marker_visible_without_literal_echo(self):
        # WHY: the presentation receipt must bind the newest rendered line,
        # while terminal input echo alone must never contain the marker.
        marker = "RC2O_0123456789ABCDEF_000"
        command = DRIVER.mirror_command("output", marker)

        self.assertNotIn(marker, command)
        self.assertIn(marker.encode("ascii").hex(), command)
        self.assertIn("sleep 0.6", command)
        self.assertTrue(command.endswith("\n"))

    def test_renderer_modes_bind_exact_ax_roles(self):
        # WHY: a latency run is not formal evidence unless it proves which
        # renderer produced every observed output sample.
        self.assertEqual(DRIVER.expected_renderer_ax_role("fixed_grid"), "StaticText")
        self.assertEqual(DRIVER.expected_renderer_ax_role("flow"), "Other")
        with self.assertRaisesRegex(DRIVER.Failure, "fixed_grid or flow"):
            DRIVER.expected_renderer_ax_role("automatic")

    def test_cli_requires_exact_renderer_mode(self):
        # WHY: missing or invented modes would let the iOS side measure a
        # different renderer than the macOS driver prepared.
        base = [
            str(SCRIPT),
            "--sync-dir",
            str(self.sync_dir),
            "--host",
            "127.0.0.1",
            "--port",
            "28217",
            "--run-id",
            "unit-run",
            "--profile",
            "unit-profile",
            "--canary-root",
            str(self.sync_dir),
            "--canary-pid",
            "91337",
            "--workspace-id",
            "11111111-1111-4111-8111-111111111111",
            "--surface-id",
            "22222222-2222-4222-8222-222222222222",
            "--split-id",
            "33333333-3333-4333-8333-333333333333",
            "--validate-only",
        ]
        with mock.patch.object(sys, "argv", base), self.assertRaises(SystemExit):
            DRIVER.parse_args()
        with mock.patch.object(
            sys,
            "argv",
            base + ["--renderer-mode", "automatic"],
        ), self.assertRaises(SystemExit):
            DRIVER.parse_args()
        with mock.patch.object(
            sys,
            "argv",
            base + ["--renderer-mode", "fixed_grid"],
        ):
            parsed = DRIVER.parse_args()
        self.assertEqual(parsed.renderer_mode, "fixed_grid")

    def _output_request(self, *, renderer_mode, ax_role_before, nonce="A" * 32):
        value = DRIVER.expected_mirror_value(nonce, "output", 0)
        return {
            "mode": DRIVER.HOST_MIRROR_MODE,
            "runID": self.args.run_id,
            "nonce": nonce,
            "host": self.args.host,
            "port": self.args.port,
            "profile": self.args.profile,
            "canaryRoot": str(self.args.canary_root),
            "canaryPID": self.args.canary_pid,
            "workspaceID": self.args.workspace_id,
            "surfaceID": self.args.surface_id,
            "splitID": self.args.split_id,
            "index": 0,
            "kind": "output",
            "value": value,
            "rows": 40,
            "cols": 120,
            "rendererMode": renderer_mode,
            "axRoleBefore": ax_role_before,
            "createdAtEpochMs": DRIVER.epoch_milliseconds(),
            "deadlineEpochMs": DRIVER.epoch_milliseconds() + 1_000,
        }

    def test_output_request_rejects_ax_role_from_another_renderer(self):
        # WHY: auto-detecting a convenient AX node could silently run the
        # fixed-grid proof while claiming flow, or vice versa.
        self.args.startup_timeout_seconds = 0.1
        nonce = "A" * 32
        request = self._output_request(
            renderer_mode="fixed_grid",
            ax_role_before="Other",
            nonce=nonce,
        )
        DRIVER.atomic_write_json(
            DRIVER.mirror_protocol_path(
                self.sync_dir, nonce, "output", 0, "request"
            ),
            request,
        )

        with self.assertRaisesRegex(DRIVER.Failure, "AX role"):
            DRIVER.wait_for_mirror_request(self.args, nonce, "output", 0)

    def test_output_request_rejects_cross_mode_renderer_artifact(self):
        # WHY: a flow-prepared host must not accept fixed_grid request files.
        self.args.startup_timeout_seconds = 0.1
        self.args.renderer_mode = "flow"
        nonce = "B" * 32
        request = self._output_request(
            renderer_mode="fixed_grid",
            ax_role_before="StaticText",
            nonce=nonce,
        )
        DRIVER.atomic_write_json(
            DRIVER.mirror_protocol_path(
                self.sync_dir, nonce, "output", 0, "request"
            ),
            request,
        )

        with self.assertRaisesRegex(DRIVER.Failure, "renderer mode"):
            DRIVER.wait_for_mirror_request(self.args, nonce, "output", 0)

    def test_flow_cleanup_runs_after_protocol_failure(self):
        # WHY: nested-shell flow setup must not leave the canary dirty when the
        # formal sample loop fails after setup succeeds.
        controller = mock.Mock()
        controller.ensure_ready.return_value = {
            "connection_id": "connection-1",
            "host_id": "host-1",
            "boot_epoch": 7,
        }
        layout = {
            "orientation": "horizontal",
            "ratios": [0.5, 0.5],
            "target_pane_id": "pane-1",
        }
        calibration = {
            "orientation": "horizontal",
            "targetPaneID": "pane-1",
            "originalRatios": [0.5, 0.5],
            "calibrationRatios": [0.54, 0.46],
            "restoredRatios": [0.5, 0.5],
            "originalRows": 40,
            "originalCols": 120,
            "calibratedRows": 40,
            "calibratedCols": 126,
            "restoredRows": 40,
            "restoredCols": 120,
            "ratioDelta": 0.04,
        }
        self.args.renderer_mode = "flow"
        with mock.patch.object(DRIVER, "require_terminal_geometry_environment"), \
             mock.patch.object(DRIVER, "verify_canary_identity"), \
             mock.patch.object(
                 DRIVER,
                 "prepare_flow_renderer",
                 return_value={
                     "flow_setup_applied": True,
                     "flow_setup_rpc_completed_at_epoch_ms": 1,
                     "flow_setup_verified_at_epoch_ms": 2,
                 },
             ) as prepare_flow, \
             mock.patch.object(
                 DRIVER,
                 "cleanup_flow_renderer",
                 return_value={
                     "flow_cleanup_verified": True,
                     "flow_cleanup_rpc_completed_at_epoch_ms": 3,
                     "flow_cleanup_verified_at_epoch_ms": 4,
                 },
             ) as cleanup_flow, \
             mock.patch.object(DRIVER, "RemoteMutationController", return_value=controller), \
             mock.patch.object(DRIVER, "pane_layout", return_value=layout), \
             mock.patch.object(DRIVER, "terminal_geometry", return_value=(40, 120)), \
             mock.patch.object(DRIVER, "calibrate_and_restore_layout", return_value=calibration), \
             mock.patch.object(
                 DRIVER,
                 "run_protocol_with_controller",
                 side_effect=DRIVER.Failure("sample loop failed"),
             ):
            with self.assertRaisesRegex(DRIVER.Failure, "sample loop failed"):
                DRIVER.run_protocol(self.args)

        prepare_flow.assert_called_once()
        cleanup_flow.assert_called_once_with(self.args, controller)
        controller.close.assert_called_once()

    def test_flow_setup_and_cleanup_use_exact_nested_shell_contract(self):
        # WHY: flow must be intentional and reversible; fixed-grid proof data
        # must never come from opportunistic renderer auto-detection.
        controller = mock.Mock()
        mutations = [
            (1, 2, {"accepted": True, "status": "accepted"}),
            (3, 4, {"accepted": True, "status": "accepted"}),
        ]
        with mock.patch.object(
            DRIVER,
            "timed_mutating_rpc",
            side_effect=mutations,
        ) as mutate, mock.patch.object(
            DRIVER,
            "wait_for_flow_setup",
            return_value=5,
        ), mock.patch.object(
            DRIVER,
            "wait_for_flow_cleanup",
            return_value=6,
        ):
            setup = DRIVER.prepare_flow_renderer(self.args, controller)
            cleanup = DRIVER.cleanup_flow_renderer(self.args, controller)

        self.assertTrue(setup["flow_setup_applied"])
        self.assertTrue(cleanup["flow_cleanup_verified"])
        self.assertEqual(
            mutate.call_args_list[0].args[3],
            {"id": self.args.surface_id, "text": DRIVER.FLOW_SETUP_COMMAND},
        )
        self.assertEqual(
            DRIVER.FLOW_SETUP_COMMAND,
            "printf '\\033]0;terminal\\007\\033[2J\\033[HRC2_FLOW_READY\\n'; "
            "env PS1='RC2_FLOW> ' HISTFILE=/dev/null "
            "/bin/bash --noprofile --norc --noediting -i\n",
        )
        self.assertEqual(
            mutate.call_args_list[1].args[3],
            {"id": self.args.surface_id, "text": DRIVER.FLOW_CLEANUP_COMMAND},
        )
        self.assertTrue(DRIVER.FLOW_CLEANUP_COMMAND.startswith("exit\n"))

    def test_latency_contract_accepts_only_one_bounded_outlier_in_one_hundred(self):
        # WHY: 100 independent trials with at most one bounded miss provide a
        # materially stronger long-run claim than a descriptive 30-sample p95.
        metrics = DRIVER.validate_latency_samples(
            ([100.0] * 94) + ([250.0] * 5) + [500.0],
            latency_limit_ms=250,
            label="geometry",
        )

        self.assertEqual(
            metrics,
            {"p95_ms": 250.0, "max_ms": 500.0, "over_limit_count": 1},
        )

    def test_latency_contract_rejects_p95_and_hard_max_violations(self):
        # WHY: the formal run permits at most one sample above the target, while
        # the independent hard maximum still bounds that outlier to 2x target.
        with self.assertRaisesRegex(DRIVER.Failure, "exactly 100"):
            DRIVER.validate_latency_samples(
                [100.0] * 99,
                latency_limit_ms=250,
                label="geometry",
            )
        with self.assertRaisesRegex(DRIVER.Failure, "more than 1 of 100"):
            DRIVER.validate_latency_samples(
                ([100.0] * 98) + [251.0, 300.0],
                latency_limit_ms=250,
                label="output",
            )
        with self.assertRaisesRegex(DRIVER.Failure, "hard maximum"):
            DRIVER.validate_latency_samples(
                ([100.0] * 99) + [500.01],
                latency_limit_ms=250,
                label="title",
            )

    def test_ack_readers_defer_bounded_outlier_to_aggregate_p95(self):
        # WHY: rejecting a 300 ms ACK before all 100 samples arrive silently
        # changes the distribution contract back into max <= 250.
        args = SimpleNamespace(
            sync_dir=self.sync_dir,
            latency_limit_ms=250,
            renderer_mode="fixed_grid",
        )
        now = DRIVER.epoch_milliseconds()
        path = mock.Mock()
        path.exists.return_value = True

        geometry_request = {
            "nonce": "n",
            "index": 0,
            "restore": False,
            "deadlineEpochMs": now + 1_000,
        }
        geometry_result = {
            "rows": 40,
            "cols": 120,
            "driverStartedAtEpochMs": now - 300,
        }
        geometry_ack = dict(
            geometry_request,
            rows=40,
            cols=120,
            iosAXObservedAtEpochMs=now,
            latencyMilliseconds=300,
        )
        with mock.patch.object(DRIVER, "geometry_protocol_path", return_value=path), \
             mock.patch.object(DRIVER, "read_json", return_value=geometry_ack), \
             mock.patch.object(DRIVER, "matching_identity", return_value=True), \
             mock.patch.object(DRIVER, "raise_if_cleanup_requested"):
            self.assertEqual(
                DRIVER.wait_for_geometry_ack(args, geometry_request, geometry_result),
                geometry_ack,
            )

        mirror_request = {
            "nonce": "n",
            "kind": "output",
            "index": 0,
            "value": "marker",
            "rows": 40,
            "cols": 120,
            "rendererMode": "fixed_grid",
            "axRoleBefore": "StaticText",
            "deadlineEpochMs": now + 1_000,
        }
        mirror_result = {
            "driverStartedAtEpochMs": now - 300,
            "rendererMode": "fixed_grid",
            "axRoleBefore": "StaticText",
        }
        mirror_ack = dict(
            mirror_request,
            axRoleAfter="StaticText",
            presentationRequestID="n-output-000",
            presentationRenderRevision=7,
            presentationLastLineSHA256=hashlib.sha256(b"marker").hexdigest(),
            presentationDisplayCyclesObserved=2,
            presentationBoundary="second_display_refresh",
            presentationDisplayTimestamp=42.0,
            presentationSnapshotScope="visible_line_rect",
            presentationSnapshotAfterScreenUpdates=False,
            presentationSnapshotDurationMilliseconds=1,
            iosPresentedAtEpochMs=now,
            iosAXObservedAtEpochMs=now,
            latencyMilliseconds=300,
            axLatencyMilliseconds=300,
        )
        with mock.patch.object(DRIVER, "mirror_protocol_path", return_value=path), \
             mock.patch.object(DRIVER, "read_json", return_value=mirror_ack), \
             mock.patch.object(DRIVER, "matching_identity", return_value=True), \
             mock.patch.object(DRIVER, "raise_if_cleanup_requested"):
            self.assertEqual(
                DRIVER.wait_for_mirror_ack(args, mirror_request, mirror_result),
                mirror_ack,
            )

    def test_timed_mutation_rejects_insufficient_budget_before_controller_call(self):
        controller = mock.Mock()
        with mock.patch.object(DRIVER, "verify_canary_identity"):
            with self.assertRaisesRegex(DRIVER.Failure, "insufficient request budget"):
                DRIVER.timed_mutating_rpc(
                    self.args,
                    controller,
                    "pane.resize",
                    {},
                    DRIVER.epoch_milliseconds() + DRIVER.MIN_MUTATION_BUDGET_MS - 1,
                )
        controller.ensure_ready.assert_not_called()
        controller.mutate.assert_not_called()

    def test_controller_bounds_snapshot_and_mutation_to_request_deadline(self):
        control_socket = BlockingControlSocket()
        timeouts = []

        def rpc(_args, method, params=None, timeout_seconds=5):
            timeouts.append((method, timeout_seconds))
            if method == "sync.snapshot":
                return snapshot_result()
            return {"accepted": True}

        with mock.patch.object(
            DRIVER,
            "open_control_websocket",
            return_value=(control_socket, bytearray(welcome_frame())),
        ), mock.patch.object(DRIVER, "rpc", side_effect=rpc):
            controller = DRIVER.RemoteMutationController(self.args)
            try:
                deadline = DRIVER.epoch_milliseconds() + 1_000
                controller.mutate("pane.resize", {"ratios": [0.5, 0.5]}, deadline)
            finally:
                controller.close()

        self.assertEqual([method for method, _ in timeouts], ["sync.snapshot", "pane.resize"])
        self.assertTrue(all(0 < timeout <= 1 for _, timeout in timeouts))

    def test_run_protocol_publishes_identity_bound_ready_before_request_zero(self):
        controller = mock.Mock()
        controller.ensure_ready.return_value = {
            "connection_id": "connection-1",
            "host_id": "host-1",
            "boot_epoch": 7,
        }
        layout = {
            "orientation": "horizontal",
            "ratios": [0.5, 0.5],
            "target_pane_id": "pane-1",
        }
        calibration = {
            "orientation": "horizontal",
            "targetPaneID": "pane-1",
            "originalRatios": [0.5, 0.5],
            "calibrationRatios": [0.54, 0.46],
            "restoredRatios": [0.5, 0.5],
            "originalRows": 40,
            "originalCols": 120,
            "calibratedRows": 40,
            "calibratedCols": 126,
            "restoredRows": 40,
            "restoredCols": 120,
            "ratioDelta": 0.04,
        }

        def assert_ready_before_protocol(*_args):
            value = json.loads(
                DRIVER.driver_ready_path(self.sync_dir).read_text(encoding="utf-8")
            )
            self.assertEqual(value["mode"], DRIVER.DRIVER_READY_MODE)
            self.assertEqual(value["runID"], self.args.run_id)
            self.assertEqual(value["surfaceID"], self.args.surface_id)
            self.assertEqual(value["rendererMode"], "fixed_grid")
            self.assertEqual(value["expectedOutputAXRole"], "StaticText")
            self.assertEqual(value["controlConnectionID"], "connection-1")
            self.assertEqual(value["hostID"], "host-1")
            self.assertEqual(value["bootEpoch"], 7)
            self.assertEqual(value["restoredRatios"], [0.5, 0.5])
            return {"status": "PASS"}

        with mock.patch.object(DRIVER, "require_terminal_geometry_environment"), \
             mock.patch.object(DRIVER, "verify_canary_identity"), \
             mock.patch.object(DRIVER, "prepare_flow_renderer") as prepare_flow, \
             mock.patch.object(DRIVER, "cleanup_flow_renderer") as cleanup_flow, \
             mock.patch.object(DRIVER, "RemoteMutationController", return_value=controller), \
             mock.patch.object(DRIVER, "pane_layout", return_value=layout), \
             mock.patch.object(DRIVER, "terminal_geometry", return_value=(40, 120)), \
             mock.patch.object(DRIVER, "calibrate_and_restore_layout", return_value=calibration), \
             mock.patch.object(
                 DRIVER,
                 "run_protocol_with_controller",
                 side_effect=assert_ready_before_protocol,
             ):
            proof = DRIVER.run_protocol(self.args)

        self.assertEqual(proof["status"], "PASS")
        self.assertFalse(proof["flow_setup_applied"])
        self.assertTrue(proof["flow_cleanup_verified"])
        prepare_flow.assert_not_called()
        cleanup_flow.assert_not_called()
        controller.close.assert_called_once()


if __name__ == "__main__":
    unittest.main()
