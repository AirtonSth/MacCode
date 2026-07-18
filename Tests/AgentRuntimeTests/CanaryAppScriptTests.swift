import Foundation
import XCTest

final class CanaryAppScriptTests: XCTestCase {
    private struct CommandResult {
        let status: Int32
        let output: String
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var harnessURL: URL {
        repositoryRoot.appendingPathComponent("scripts/canary-app.sh")
    }

    private var terminalStabilityHarnessURL: URL {
        repositoryRoot.appendingPathComponent("scripts/terminal-stability-e2e.py")
    }

    private func temporaryCanaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteCodeAgentCanary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.resolvingSymlinksInPath()
    }

    private func writeFakePackager(under root: URL) throws -> URL {
        let packager = root.appendingPathComponent("fake-package-app.sh")
        let source = #"""
        #!/usr/bin/env bash
        set -euo pipefail
        app="${RC2_PACKAGE_APP_OUTPUT:?}"
        printf '%s\n' "${RC2_REPLACE_RUNNING_APP:-unset}" > "$(dirname "$app")/replace-running-app.txt"
        mkdir -p "$app/Contents/MacOS"
        cat > "$app/Contents/Info.plist" <<PLIST
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
          <key>CFBundleDisplayName</key><string>RemoteCode</string>
          <key>CFBundleExecutable</key><string>RemoteCode</string>
          <key>CFBundleIdentifier</key><string>${RC2_BUNDLE_ID:?}</string>
          <key>CFBundleName</key><string>RemoteCode</string>
          <key>CFBundlePackageType</key><string>APPL</string>
        </dict></plist>
        PLIST
        /usr/bin/xcrun clang -x c -o "$app/Contents/MacOS/RemoteCode" - <<'C'
        #include <signal.h>
        #include <unistd.h>
        static volatile sig_atomic_t running = 1;
        static void stop(int signal) { (void)signal; running = 0; }
        int main(void) {
          signal(SIGTERM, stop);
          signal(SIGINT, stop);
          while (running) pause();
          return 0;
        }
        C
        """#
        try source.write(to: packager, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: packager.path)
        return packager
    }

    @discardableResult
    private func run(_ command: String, root: URL, packager: URL? = nil) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [harnessURL.path, command]
        var environment = ProcessInfo.processInfo.environment
        environment["RC2_CANARY_ROOT"] = root.path
        if let packager {
            environment["RC2_CANARY_PACKAGE_SCRIPT"] = packager.path
        }
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return CommandResult(status: process.terminationStatus, output: output)
    }

    private func runTerminalStabilityHarness(_ arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = terminalStabilityHarnessURL
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        for key in [
            "RC2_PRIMARY_PORT",
            "RC2_E2E_PORT",
            "RC2_E2E_DURATION_SECONDS",
            "RC2_E2E_TERMINAL_COUNT",
            "RC2_E2E_PRE_GATE_SECONDS",
            "RC2_E2E_SAMPLE_INTERVAL_SECONDS",
            "RC2_E2E_CLIENT_WARMUP_SECONDS",
            "RC2_E2E_WORKLOAD_STABILIZATION_SECONDS",
        ] {
            environment.removeValue(forKey: key)
        }
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return CommandResult(status: process.terminationStatus, output: output)
    }

    private func runTerminalStabilityProbe(
        _ source: String,
        arguments: [String] = []
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", source, terminalStabilityHarnessURL.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return CommandResult(status: process.terminationStatus, output: output)
    }

    func testHarnessContractForbidsBroadProcessKills() throws {
        let source = try String(contentsOf: harnessURL, encoding: .utf8)

        XCTAssertFalse(source.contains("pkill"),
                       "the canary harness must never kill stable RemoteCode processes by shared process name")
        for command in ["build", "run", "stop", "status", "reset-state"] {
            XCTAssertTrue(source.contains(command), "the harness must expose the \(command) command")
        }
    }

    func testTerminalStabilityHarnessCannotTargetThePrimaryApp() throws {
        // WHY: terminal stability tests must be runnable while a developer uses
        // RemoteCode. A process-name kill or the production port destroys that
        // isolation before the test can prove anything.
        let source = try String(contentsOf: terminalStabilityHarnessURL, encoding: .utf8)

        XCTAssertFalse(source.contains("pkill"))
        XCTAssertFalse(source.contains("pgrep"))
        XCTAssertFalse(source.contains("/usr/bin/open"))
        XCTAssertFalse(source.contains("RC2_REPLACE_RUNNING_APP"))
        XCTAssertTrue(source.contains("canary-app.sh"))
        XCTAssertTrue(source.contains("RC2_E2E_PORT\", \"28217"))
        XCTAssertTrue(source.contains("if PORT == PRIMARY_PORT"))

        for assignment in [
            "canary_env[\"RC2_ENABLE_GHOSTTY_IN_TESTS\"] = \"1\"",
            "canary_env[\"RC2_SPARKLE_PUBLIC_ED_KEY\"] = \"\"",
            "canary_env[\"HOME\"] = str(isolated_home)",
            "canary_env[\"ZDOTDIR\"] = str(isolated_home)",
            "canary_env[\"HISTFILE\"] = str(isolated_home / \".zsh_history\")",
            "canary_env[\"CODEX_HOME\"] = str(isolated_home / \".codex\")",
        ] {
            XCTAssertTrue(source.contains(assignment), "missing isolated canary assignment: \(assignment)")
        }

        let main = try XCTUnwrap(source.range(of: "def main():")).lowerBound
        let mainSource = source[main...]
        let validation = try XCTUnwrap(mainSource.range(of: "validate_configuration(args)"))
        let validationExit = try XCTUnwrap(mainSource.range(of: "if args.validate_only:"))
        let portGuard = try XCTUnwrap(mainSource.range(of: "refuse_unsafe_target()"))
        let run = try XCTUnwrap(mainSource.range(of: "run_canary(\"run\""))
        let pid = try XCTUnwrap(mainSource.range(of: "pid = app_pid(canary_root)"))
        let listener = try XCTUnwrap(mainSource.range(of: "wait_for_canary_listener(pid, canary_root)"))
        let health = try XCTUnwrap(mainSource.range(of: "wait_for_host()"))
        let firstRPC = try XCTUnwrap(mainSource.range(of: "primary = rpc(\"workspace.create\""))
        XCTAssertLessThan(validation.lowerBound, validationExit.lowerBound)
        XCTAssertLessThan(validationExit.lowerBound, portGuard.lowerBound)
        XCTAssertLessThan(portGuard.lowerBound, run.lowerBound)
        XCTAssertLessThan(run.lowerBound, pid.lowerBound)
        XCTAssertLessThan(pid.lowerBound, listener.lowerBound)
        XCTAssertLessThan(listener.lowerBound, health.lowerBound)
        XCTAssertLessThan(health.lowerBound, firstRPC.lowerBound,
                          "no RPC may run before exact canary PID/listener ownership is proven")
    }

    func testTerminalStabilityHarnessReleaseProfileAndHelpDoNotLaunch() throws {
        // WHY: the long release gate must be discoverable and machine-verifiable
        // without building or opening an app merely to inspect its configuration.
        let help = try runTerminalStabilityHarness(["--help"])
        XCTAssertEqual(help.status, 0, help.output)
        XCTAssertTrue(help.output.contains("--release-soak"))
        XCTAssertTrue(help.output.contains("12 terminals for 60 minutes, a 15-minute pre-gate"))
        XCTAssertTrue(help.output.contains("30-second connected-client warmup"))
        XCTAssertTrue(help.output.contains("does not claim real iOS UI coverage"))

        let release = try runTerminalStabilityHarness(["--release-soak", "--validate-only"])
        XCTAssertEqual(release.status, 0, release.output)
        let data = try XCTUnwrap(release.output.data(using: .utf8))
        let configuration = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(configuration["duration_seconds"] as? Int, 3_600)
        XCTAssertEqual(configuration["terminal_count"] as? Int, 12)
        XCTAssertEqual(configuration["pre_gate_seconds"] as? Int, 900)
        XCTAssertEqual((configuration["client_warmup_seconds"] as? NSNumber)?.doubleValue, 30)
        XCTAssertEqual(
            (configuration["workload_stabilization_seconds"] as? NSNumber)?.doubleValue,
            3
        )
        XCTAssertEqual((configuration["workload_command_seconds"] as? NSNumber)?.doubleValue, 3_603)
        XCTAssertEqual(configuration["require_slow_ws"] as? Bool, true)
        XCTAssertEqual(configuration["ios_ui_coverage"] as? String, "NOT_RUN")
        let diagnosticOnly = Set(configuration["diagnostic_only_metrics"] as? [String] ?? [])
        XCTAssertTrue(diagnosticOnly.contains("max_cpu_percent"))
        XCTAssertTrue(diagnosticOnly.contains("max_health_rpc_latency_ms"))
        XCTAssertTrue(diagnosticOnly.contains("post_idle_output_roundtrip_ms"))
        XCTAssertTrue(help.output.contains("diagnostic_only"))

        let source = try String(contentsOf: terminalStabilityHarnessURL, encoding: .utf8)
        XCTAssertTrue(source.contains("args.require_slow_ws = REQUIRE_SLOW_WS or args.release_soak"))
        XCTAssertTrue(source.contains("stats[\"slow_ws_reconnect_seen\"] = True"))
        XCTAssertTrue(source.contains("stats[\"baseline_converged_after_reconnect\"] = True"))
        XCTAssertTrue(source.contains("workspace baseline did not converge after slow-client reconnect"))
    }

    func testTerminalStabilityHarnessNoBuildGuardStopsBeforeLaunch() throws {
        // WHY: skipping the package step without an explicit identity could run
        // or later stop the wrong canary. The guard must fail before any lifecycle action.
        let result = try runTerminalStabilityHarness(["--no-build", "--validate-only"])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("--no-build requires --canary-root"), result.output)
    }

    func testTerminalStabilityHarnessRequiresAcceptedExactLargeInput() throws {
        // WHY: a queue_full or write_failed response means the requested 256 KiB
        // terminal paste was lost. Reporting that path as an acceptable outcome
        // turns a stability failure into a false pass.
        let probe = #"""
        import importlib.util
        import hashlib
        import json
        import sys

        spec = importlib.util.spec_from_file_location("terminal_stability_e2e", sys.argv[1])
        harness = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(harness)

        def outcome(result):
            try:
                harness.assert_large_input_accepted(result)
                return "PASS"
            except harness.Failure as error:
                return str(error)

        payload = harness.deterministic_large_input_bytes(256 * 1024)

        print(json.dumps({
            "accepted": outcome({"accepted": True, "status": "accepted"}),
            "queue_full": outcome({"accepted": False, "status": "queue_full"}),
            "write_failed": outcome({"accepted": False, "status": "write_failed"}),
            "missing_acceptance": outcome({"status": "accepted"}),
            "payload_size": str(len(payload)),
            "payload_hash": hashlib.sha256(payload).hexdigest(),
            "payload_non_uniform": "PASS" if len(set(payload)) > 16 else "FAIL",
            "payload_newline_terminated": "PASS" if payload.endswith(b"\n") else "FAIL",
        }, sort_keys=True))
        """#
        let result = try runTerminalStabilityProbe(probe)
        XCTAssertEqual(result.status, 0, result.output)
        let data = try XCTUnwrap(result.output.data(using: .utf8))
        let outcomes = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: String]
        )
        XCTAssertEqual(outcomes["accepted"], "PASS")
        XCTAssertTrue(outcomes["queue_full"]?.contains("must be accepted") == true)
        XCTAssertTrue(outcomes["write_failed"]?.contains("must be accepted") == true)
        XCTAssertTrue(outcomes["missing_acceptance"]?.contains("must be accepted") == true)
        XCTAssertEqual(outcomes["payload_size"], "262144")
        XCTAssertEqual(outcomes["payload_non_uniform"], "PASS")
        XCTAssertEqual(outcomes["payload_newline_terminated"], "PASS")
        XCTAssertEqual(
            outcomes["payload_hash"],
            "a06a3d8d6b28c426f282bd6d7c5ae9d53d1395ecab87ae1b9ef8225cf502b167"
        )

        let source = try String(contentsOf: terminalStabilityHarnessURL, encoding: .utf8)
        XCTAssertTrue(source.contains("RC2_LARGE_INPUT_BYTES:{LARGE_INPUT_BYTES}"))
        XCTAssertTrue(source.contains("RC2_LARGE_INPUT_SHA256:{expected_large_input_sha256}"))
        XCTAssertFalse(source.contains("RC2_LARGE_INPUT_BYTES:{LARGE_INPUT_BYTES + 1}"))
    }

    func testTerminalStabilityHarnessSynchronizesWorkloadAndRecoversResources() throws {
        // WHY: the one-hour measurement must start after active workloads settle,
        // and closing every test workspace must return process resources to the
        // warmed pre-workspace baseline before the run can pass.
        let probe = #"""
        import importlib.util
        import json
        import sys

        spec = importlib.util.spec_from_file_location("terminal_stability_e2e", sys.argv[1])
        harness = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(harness)
        harness.RUN_SECONDS = 3600
        harness.WORKLOAD_STABILIZATION_SECONDS = 3

        harness.MAX_POST_CLOSE_RSS_DELTA_KB = 32_768
        snapshots = iter([
            {"rss_kb": 105_000, "fd_count": 12, "child_process_count": 1},
            {"rss_kb": 101_000, "fd_count": 10, "child_process_count": 0},
        ])
        owned_processes = iter([
            [{"pid": 900, "ppid": 1, "pgid": 900, "sid": 500, "args": "orphan"}],
            [],
        ])
        real_owned_terminal_processes = harness.owned_terminal_processes
        harness.process_resource_snapshot = lambda _: next(snapshots)
        harness.owned_terminal_processes = lambda *args: next(owned_processes)
        harness.time.sleep = lambda _: None
        recovered = harness.wait_for_resource_recovery(
            123,
            100_000,
            10,
            0,
            terminal_session_ids={500},
            terminal_process_groups={900},
            terminal_process_marker="RC2_TEST_ORPHAN",
            timeout=1,
        )

        process_records = [
            {"pid": 600, "ppid": 1, "pgid": 600, "sid": 500, "args": "reparented"},
            {"pid": 601, "ppid": 1, "pgid": 700, "sid": 999, "args": "group-owned"},
            {"pid": 602, "ppid": 1, "pgid": 602, "sid": 999, "args": "RC2_TEST_ORPHAN"},
            {"pid": 603, "ppid": 1, "pgid": 603, "sid": 999, "args": "unrelated"},
        ]
        harness.process_table = lambda: process_records
        harness.owned_terminal_processes = real_owned_terminal_processes
        matched_processes = harness.owned_terminal_processes(
            {500}, {700}, "RC2_TEST_ORPHAN"
        )

        def websocket_frame(value):
            payload = json.dumps(value, separators=(",", ":")).encode()
            if len(payload) < 126:
                header = bytes([0x81, len(payload)])
            else:
                header = bytes([0x81, 126]) + len(payload).to_bytes(2, "big")
            return header + payload

        welcome = {"type": "welcome", "currentSequence": 40}
        selected = {
            "type": "event",
            "sequence": 41,
            "kind": "workspace.selected",
            "payload": {"workspace_id": "workspace-run-unique"},
        }
        websocket_buffer = bytearray(websocket_frame(welcome) + websocket_frame(selected))

        class NeverReadSocket:
            def settimeout(self, _): pass
            def recv(self, _): raise AssertionError("complete frames must use buffered handshake bytes")

        websocket_event = harness.wait_for_websocket_json(
            NeverReadSocket(),
            websocket_buffer,
            lambda value: (
                value.get("kind") == "workspace.selected"
                and value.get("payload", {}).get("workspace_id") == "workspace-run-unique"
            ),
        )
        slow_stats = {"dropped_event_count": 0, "slow_ws_disconnect_seen": False}
        harness.recent = lambda max_bytes: {
            "events": [{"kind": "diagnostic.ws_slow_client"}]
        }
        harness.observe_slow_ws_disconnect(slow_stats)
        converged_ids = harness.listed_workspace_ids([
            {"id": {"value": "workspace-a"}},
            {"id": {"value": "workspace-b"}},
        ])

        print(json.dumps({
            "command_seconds": harness.workload_duration_seconds(),
            "recovered_fd": recovered["fd_count"],
            "recovered_children": recovered["child_process_count"],
            "recovered_rss": recovered["rss_kb"],
            "above_fd_rejected": not harness.resource_counts_recovered(11, 2, 10, 2),
            "above_children_rejected": not harness.resource_counts_recovered(10, 3, 10, 2),
            "pre_workspace_child_leak_rejected": not harness.post_close_resources_recovered(
                101_000, 10, 1, 100_000, 10, 0
            ),
            "loaded_baseline_would_hide_child_leak": harness.resource_counts_recovered(
                10, 1, 15, 24
            ),
            "post_close_rss_growth_rejected": not harness.post_close_resources_recovered(
                132_769, 10, 0, 100_000, 10, 0
            ),
            "post_close_orphan_rejected": not harness.post_close_resources_recovered(
                101_000, 10, 0, 100_000, 10, 0, owned_process_count=1
            ),
            "owned_process_ids": sorted(record["pid"] for record in matched_processes),
            "websocket_event_sequence": websocket_event["sequence"],
            "slow_disconnect_observed": slow_stats["slow_ws_disconnect_seen"],
            "reconnect_baseline_ids": sorted(converged_ids),
        }, sort_keys=True))
        """#
        let result = try runTerminalStabilityProbe(probe)
        XCTAssertEqual(result.status, 0, result.output)
        let data = try XCTUnwrap(result.output.data(using: .utf8))
        let evidence = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual((evidence["command_seconds"] as? NSNumber)?.doubleValue, 3_603)
        XCTAssertEqual(evidence["recovered_fd"] as? Int, 10)
        XCTAssertEqual(evidence["recovered_children"] as? Int, 0)
        XCTAssertEqual(evidence["recovered_rss"] as? Int, 101_000)
        XCTAssertEqual(evidence["above_fd_rejected"] as? Bool, true)
        XCTAssertEqual(evidence["above_children_rejected"] as? Bool, true)
        XCTAssertEqual(evidence["pre_workspace_child_leak_rejected"] as? Bool, true)
        XCTAssertEqual(evidence["loaded_baseline_would_hide_child_leak"] as? Bool, true)
        XCTAssertEqual(evidence["post_close_rss_growth_rejected"] as? Bool, true)
        XCTAssertEqual(evidence["post_close_orphan_rejected"] as? Bool, true)
        XCTAssertEqual(evidence["owned_process_ids"] as? [Int], [600, 601, 602])
        XCTAssertEqual(evidence["websocket_event_sequence"] as? Int, 41)
        XCTAssertEqual(evidence["slow_disconnect_observed"] as? Bool, true)
        XCTAssertEqual(
            evidence["reconnect_baseline_ids"] as? [String],
            ["workspace-a", "workspace-b"]
        )

        let source = try String(contentsOf: terminalStabilityHarnessURL, encoding: .utf8)
        let main = try XCTUnwrap(source.range(of: "def main():")).lowerBound
        let mainSource = source[main...]
        let warmup = try XCTUnwrap(mainSource.range(of: "stats[\"client_warmup_completed\"] = True"))
        let preWorkspaceBaseline = try XCTUnwrap(
            mainSource.range(of: "pre_workspace_resources = process_resource_snapshot(pid)")
        )
        let firstWorkspace = try XCTUnwrap(
            mainSource.range(of: "primary = rpc(\"workspace.create\"")
        )
        // WHY: READY is assembled via runtime_marker(prefix, suffix); ordering
        // still requires stream_ready setup before shared trigger/stabilization.
        let ready = try XCTUnwrap(mainSource.range(of: "stream_ready_marker = runtime_marker"))
        let trigger = try XCTUnwrap(mainSource.range(of: "workload_trigger_path.write_text(\"start\\n\")"))
        let stabilized = try XCTUnwrap(
            mainSource.range(of: "stats[\"workload_stabilization_completed\"] = True")
        )
        let measured = try XCTUnwrap(
            mainSource.range(of: "stats[\"soak_started_monotonic\"] = time.monotonic()")
        )
        let close = try XCTUnwrap(mainSource.range(of: "rpc(\"workspace.close\""))
        // WHY: first close hard-gates process-tree cleanup + per-surface FDs;
        // RSS/FD stacking is proven by cycle-to-cycle warmed recovery (not by
        // raising cold pre-workspace 32MiB/FD tolerances).
        let processTreeCleanup = try XCTUnwrap(
            mainSource.range(of: "recovered = wait_for_process_tree_cleanup(")
        )
        let closeCycle = try XCTUnwrap(mainSource.range(of: "run_resource_close_cycle("))
        let warmedRecovery = try XCTUnwrap(
            mainSource.range(of: "wait_for_resource_recovery(")
        )
        let websocketLiveEvent = try XCTUnwrap(
            mainSource.range(of: "stats[\"slow_ws_live_event_seen\"] = True")
        )
        let websocketReconnect = try XCTUnwrap(
            mainSource.range(of: "stats[\"slow_ws_reconnect_seen\"] = True")
        )
        XCTAssertLessThan(warmup.lowerBound, ready.lowerBound)
        XCTAssertLessThan(preWorkspaceBaseline.lowerBound, firstWorkspace.lowerBound)
        XCTAssertLessThan(ready.lowerBound, trigger.lowerBound)
        XCTAssertLessThan(trigger.lowerBound, stabilized.lowerBound)
        XCTAssertLessThan(stabilized.lowerBound, measured.lowerBound)
        XCTAssertLessThan(websocketLiveEvent.lowerBound, websocketReconnect.lowerBound)
        XCTAssertLessThan(close.lowerBound, processTreeCleanup.lowerBound)
        XCTAssertLessThan(processTreeCleanup.lowerBound, closeCycle.lowerBound)
        XCTAssertLessThan(closeCycle.lowerBound, warmedRecovery.lowerBound)
        XCTAssertTrue(
            mainSource.contains("post_close_rss_delta_from_cold_kb"),
            "cold residual must remain a diagnostic field"
        )
        XCTAssertTrue(
            mainSource.contains("warmed_post_close_rss_kb"),
            "warmed baseline required for cycle stacking gate"
        )
    }

    func testTerminalStabilityHarnessEnforcesLeakAndDroppedOutputGates() throws {
        // WHY: collecting leak and output-loss counters is not proof unless a
        // positive final value makes the release harness fail.
        let probe = #"""
        import importlib.util
        import json
        import sys

        spec = importlib.util.spec_from_file_location("terminal_stability_e2e", sys.argv[1])
        harness = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(harness)

        harness.MAX_RSS_TAIL_SLOPE_KB_PER_MINUTE = 256
        harness.MAX_RSS_PLATEAU_DELTA_KB = 8192
        harness.MAX_RSS_TAIL_NET_GROWTH_KB = 8192

        def flat_samples():
            return [
                {
                    "elapsed_seconds": float(index * 60),
                    "rss_kb": 100_000,
                    "fd_count": 10,
                    "child_process_count": 2,
                }
                for index in range(61)
            ]

        def stats(
            samples=None,
            fd_delta=0,
            child_delta=0,
            dropped_bytes=0,
            history_write_failures=0,
        ):
            samples = samples or flat_samples()
            samples = [dict(sample) for sample in samples]
            samples[-1]["fd_count"] += fd_delta
            samples[-1]["child_process_count"] += child_delta
            return {
                "samples": samples,
                "max_observed_dropped_output_bytes": dropped_bytes,
                "max_observed_history_write_failures": history_write_failures,
            }

        def outcome(samples=None, **kwargs):
            try:
                harness.assert_stability_gate(stats(samples=samples, **kwargs), "unit")
                return "PASS"
            except harness.Failure as error:
                return str(error)

        slow_linear_leak = [
            {
                "elapsed_seconds": float(index * 60),
                "rss_kb": 100_000 + index * 1_024,
                "fd_count": 10,
                "child_process_count": 2,
            }
            for index in range(61)
        ]
        bounded_warmup = [
            {
                "elapsed_seconds": float(index * 60),
                "rss_kb": value,
                "fd_count": 10,
                "child_process_count": 2,
            }
            for index, value in enumerate([100_000, 104_000, 108_000] + [108_000] * 58)
        ]

        print(json.dumps({
            "clean": outcome(),
            "fd": outcome(fd_delta=1),
            "child": outcome(child_delta=1),
            "dropped": outcome(dropped_bytes=1),
            "history": outcome(history_write_failures=1),
            "slow_linear_leak": outcome(samples=slow_linear_leak),
            "bounded_warmup": outcome(samples=bounded_warmup),
        }, sort_keys=True))
        """#
        let result = try runTerminalStabilityProbe(probe)
        XCTAssertEqual(result.status, 0, result.output)
        let data = try XCTUnwrap(result.output.data(using: .utf8))
        let outcomes = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: String]
        )
        XCTAssertEqual(outcomes["clean"], "PASS")
        XCTAssertTrue(outcomes["fd"]?.contains("sustained file descriptor growth") == true)
        XCTAssertTrue(outcomes["child"]?.contains("sustained child process growth") == true)
        XCTAssertTrue(outcomes["dropped"]?.contains("terminal output loss") == true)
        XCTAssertTrue(outcomes["history"]?.contains("history persistence failure") == true)
        XCTAssertTrue(outcomes["slow_linear_leak"]?.contains("memory gate failed") == true)
        XCTAssertEqual(outcomes["bounded_warmup"], "PASS")
    }

    func testTerminalStabilityHarnessUsesUniqueContainedRunArtifactsAndCleansThem() throws {
        // WHY: fixed /tmp names let concurrent harnesses overwrite each other
        // and leave terminal input behind after a failed run.
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-harness-path-test-\(UUID().uuidString)")
        let root = parent.appendingPathComponent("RemoteCodeAgentCanary-path ' with spaces")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let probe = #"""
        import importlib.util
        import json
        import shlex
        import sys
        from pathlib import Path

        spec = importlib.util.spec_from_file_location("terminal_stability_e2e", sys.argv[1])
        harness = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(harness)
        root = Path(sys.argv[2])
        state, first, tui, large_input, trigger, hidden_flood_done, primary_stream_done = harness.prepare_run_artifacts(root)
        second_state, second, second_tui, second_large_input, second_trigger, second_hidden_flood_done, second_primary_stream_done = harness.prepare_run_artifacts(root)
        artifacts = (
            tui,
            large_input,
            trigger,
            hidden_flood_done,
            primary_stream_done,
            second_tui,
            second_large_input,
            second_trigger,
            second_hidden_flood_done,
            second_primary_stream_done,
        )
        for artifact in artifacts:
            artifact.write_text("fixture")
        quoted = harness.shell_quote_contained_path(tui, first, "unit artifact")
        contained = (
            first.parent == state
            and second.parent == state
            and tui.parent == first
            and large_input.parent == first
            and trigger.parent == first
            and hidden_flood_done.parent == first
            and primary_stream_done.parent == first
            and second_tui.parent == second
            and second_large_input.parent == second
            and second_trigger.parent == second
            and second_hidden_flood_done.parent == second
            and second_primary_stream_done.parent == second
            and second_state == state
        )
        unique = len(set((first, second) + artifacts)) == 12
        quote_round_trips = shlex.split(quoted) == [str(tui)]
        harness.cleanup_run_artifacts(first, state)
        harness.cleanup_run_artifacts(second, state)
        print(json.dumps({
            "cleaned": (
                not first.exists()
                and not second.exists()
                and all(not artifact.exists() for artifact in artifacts)
                and not any(state.iterdir())
            ),
            "contained": contained,
            "quote_round_trips": quote_round_trips,
            "unique": unique,
        }, sort_keys=True))
        """#
        let result = try runTerminalStabilityProbe(probe, arguments: [root.path])
        XCTAssertEqual(result.status, 0, result.output)
        let data = try XCTUnwrap(result.output.data(using: .utf8))
        let evidence = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Bool]
        )
        XCTAssertEqual(evidence["contained"], true)
        XCTAssertEqual(evidence["unique"], true)
        XCTAssertEqual(evidence["quote_round_trips"], true)
        XCTAssertEqual(evidence["cleaned"], true)

        let source = try String(contentsOf: terminalStabilityHarnessURL, encoding: .utf8)
        XCTAssertFalse(source.contains("/tmp/rc2_workspace_tui.sh"))
        XCTAssertFalse(source.contains("/tmp/rc2_large_input.txt"))
        let cleanup = try XCTUnwrap(source.range(
            of: "cleanup_run_artifacts(run_artifact_root, state_root)",
            options: .backwards
        ))
        XCTAssertNotNil(source[..<cleanup.lowerBound].range(of: "finally:", options: .backwards))
    }

    func testTerminalStabilityHarnessRejectsSymlinkedStateEscape() throws {
        // WHY: placing a unique filename below a state symlink still writes
        // outside the canary boundary and makes cleanup unsafe.
        let root = try temporaryCanaryRoot()
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-harness-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("state"),
            withDestinationURL: outside
        )
        let probe = #"""
        import importlib.util
        import sys
        from pathlib import Path

        spec = importlib.util.spec_from_file_location("terminal_stability_e2e", sys.argv[1])
        harness = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(harness)
        harness.prepare_run_artifacts(Path(sys.argv[2]))
        """#
        let result = try runTerminalStabilityProbe(probe, arguments: [root.path])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("refusing symlinked canary state root"), result.output)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }

    func testTerminalStabilityHarnessRefusesLiveCanaryBeforeFreshStateReset() throws {
        // WHY: an existing canary must never be adopted or stopped, and each
        // accepted run needs a fresh database without deleting its built bundle
        // or any sibling/outside artifact.
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-harness-reset-test-\(UUID().uuidString)")
        let root = parent.appendingPathComponent("RemoteCodeAgentCanary-reset")
        let appSupport = root.appendingPathComponent(
            "state/Application Support/RemoteCodeAgentCanary"
        )
        let buildSentinel = root.appendingPathComponent("app/build-sentinel")
        let stateSibling = root.appendingPathComponent("state/run-sentinel")
        let outsideSentinel = parent.appendingPathComponent("outside-sentinel")
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: buildSentinel.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("db".utf8).write(to: appSupport.appendingPathComponent("RemoteCode.sqlite"))
        try Data("build".utf8).write(to: buildSentinel)
        try Data("state sibling".utf8).write(to: stateSibling)
        try Data("outside".utf8).write(to: outsideSentinel)
        defer { try? FileManager.default.removeItem(at: parent) }

        let probe = #"""
        import importlib.util
        import json
        import sys
        from pathlib import Path

        spec = importlib.util.spec_from_file_location("terminal_stability_e2e", sys.argv[1])
        harness = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(harness)
        root = Path(sys.argv[2])
        outside = Path(sys.argv[3])
        database = root / "state" / "Application Support" / "RemoteCodeAgentCanary" / "RemoteCode.sqlite"

        harness.app_pid = lambda _: 4242
        try:
            harness.refuse_running_canary(root)
            live_refused = False
        except harness.Failure:
            live_refused = True
        database_survived_refusal = database.exists()

        harness.app_pid = lambda _: None
        harness.reset_canary_app_support(root)
        print(json.dumps({
            "live_refused": live_refused,
            "database_survived_refusal": database_survived_refusal,
            "database_removed": not database.exists(),
            "build_preserved": (root / "app" / "build-sentinel").exists(),
            "state_sibling_preserved": (root / "state" / "run-sentinel").exists(),
            "outside_preserved": outside.exists(),
        }, sort_keys=True))
        """#
        let result = try runTerminalStabilityProbe(
            probe,
            arguments: [root.path, outsideSentinel.path]
        )
        XCTAssertEqual(result.status, 0, result.output)
        let data = try XCTUnwrap(result.output.data(using: .utf8))
        let evidence = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Bool]
        )
        XCTAssertEqual(evidence["live_refused"], true)
        XCTAssertEqual(evidence["database_survived_refusal"], true)
        XCTAssertEqual(evidence["database_removed"], true)
        XCTAssertEqual(evidence["build_preserved"], true)
        XCTAssertEqual(evidence["state_sibling_preserved"], true)
        XCTAssertEqual(evidence["outside_preserved"], true)

        let source = try String(contentsOf: terminalStabilityHarnessURL, encoding: .utf8)
        let main = try XCTUnwrap(source.range(of: "def main():")).lowerBound
        let mainSource = source[main...]
        let preflight = try XCTUnwrap(mainSource.range(of: "refuse_running_canary(canary_root)"))
        let artifacts = try XCTUnwrap(mainSource.range(of: "prepare_run_artifacts(canary_root)"))
        let reset = try XCTUnwrap(mainSource.range(of: "reset_canary_app_support(canary_root)"))
        let launch = try XCTUnwrap(mainSource.range(of: "run_canary(\"run\""))
        XCTAssertLessThan(preflight.lowerBound, artifacts.lowerBound)
        XCTAssertLessThan(artifacts.lowerBound, reset.lowerBound)
        XCTAssertLessThan(reset.lowerBound, launch.lowerBound)
    }

    func testBuildRunStatusAndStopUseIsolatedCanaryIdentity() throws {
        let root = try temporaryCanaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packager = try writeFakePackager(under: root)
        defer { try? run("stop", root: root, packager: packager) }

        let build = try run("build", root: root, packager: packager)
        XCTAssertEqual(build.status, 0, build.output)
        let replacementPolicy = try String(
            contentsOf: root.appendingPathComponent("build/replace-running-app.txt"),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(replacementPolicy, "0",
                       "canary packaging must never terminate or replace any running app")

        let app = root.appendingPathComponent("app/RemoteCodeAgentCanary.app")
        let executable = app.appendingPathComponent("Contents/MacOS/RemoteCodeAgentCanary")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path),
                      "the canary must use its own executable name instead of RemoteCode")
        let plistData = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any]
        )
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "io.remotecode.desktop.agent-canary")
        XCTAssertEqual(plist["CFBundleName"] as? String, "RemoteCodeAgentCanary")
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "RemoteCodeAgentCanary")

        let start = try run("run", root: root, packager: packager)
        XCTAssertEqual(start.status, 0, start.output)
        let status = try run("status", root: root, packager: packager)
        XCTAssertEqual(status.status, 0, status.output)
        XCTAssertTrue(status.output.contains(executable.path),
                      "status must identify the exact canary executable, not a shared process name")

        let stop = try run("stop", root: root, packager: packager)
        XCTAssertEqual(stop.status, 0, stop.output)
        XCTAssertNotEqual(try run("status", root: root, packager: packager).status, 0)
    }

    func testResetStateDeletesOnlyValidatedCanaryState() throws {
        let root = try temporaryCanaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("state/Application Support/RemoteCodeAgentCanary")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try Data("keep app outside state".utf8).write(to: root.appendingPathComponent("outside.txt"))
        try Data("delete state".utf8).write(to: state.appendingPathComponent("RemoteCode.sqlite"))

        let reset = try run("reset-state", root: root)
        XCTAssertEqual(reset.status, 0, reset.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("outside.txt").path),
                      "reset-state must not delete siblings outside the validated state directory")

        let unsafeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("unsafe-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: unsafeRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: unsafeRoot) }
        let sentinel = unsafeRoot.appendingPathComponent("sentinel")
        try Data("must survive".utf8).write(to: sentinel)
        let rejected = try run("reset-state", root: unsafeRoot)
        XCTAssertNotEqual(rejected.status, 0, "reset-state must reject roots without the canary identity marker")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
    }
}
