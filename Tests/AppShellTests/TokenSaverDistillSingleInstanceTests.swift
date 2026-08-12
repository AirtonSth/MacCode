import Foundation
import XCTest
import CoreModel
import DistillCore
import Persistence
@testable import AppShell
@testable import AgentRuntime

/// Single Distill MLX server + always-stop-on-quit contracts.
@MainActor
final class TokenSaverDistillSingleInstanceTests: XCTestCase {

    func test_sidecarNamespaceReapingIsScopedToAppSupportDirectory() {
        let stable = URL(fileURLWithPath: "/Users/test/Library/Application Support/RemoteCode")
        let canary = URL(fileURLWithPath: "/tmp/RemoteCodeAgentCanary/state")
        let stableCommand = "/Applications/RemoteCode.app/Contents/MacOS/RemoteCodeDistillService --auth-token token --app-support-dir \(stable.path) --host 127.0.0.1 --port 0"
        let canaryCommand = "/tmp/RemoteCodeAgentCanary.app/Contents/MacOS/RemoteCodeDistillService --auth-token token --app-support-dir \(canary.path) --host 127.0.0.1 --port 0"

        XCTAssertTrue(
            TokenSaverDistillServiceController.sidecarCommand(
                stableCommand,
                belongsToNamespace: TokenSaverDistillServiceController.sidecarNamespace(for: stable)
            ),
            "the stable controller must recognize its historical RemoteCode namespace"
        )
        XCTAssertFalse(
            TokenSaverDistillServiceController.sidecarCommand(
                canaryCommand,
                belongsToNamespace: TokenSaverDistillServiceController.sidecarNamespace(for: stable)
            ),
            "a canary sidecar must not be reaped by the stable controller"
        )
        XCTAssertTrue(
            TokenSaverDistillServiceController.sidecarCommand(
                canaryCommand,
                belongsToNamespace: TokenSaverDistillServiceController.sidecarNamespace(for: canary)
            ),
            "the canary controller must still enforce singleton ownership within canary"
        )
    }

    func test_sidecarNamespaceParserPreservesSpacesAndNeverAdmitsMCPOrUnknownNamespace() {
        let namespace = URL(fileURLWithPath: "/Users/test/Library/Application Support/RemoteCode")
        let server = "/tmp/RemoteCodeDistillService --auth-token token --app-support-dir \(namespace.path) --host 127.0.0.1 --port 0"
        let mcp = "/tmp/RemoteCodeDistillService mcp"
        let malformed = "/tmp/RemoteCodeDistillService --auth-token token --host 127.0.0.1 --port 0"

        XCTAssertEqual(
            TokenSaverDistillServiceController.sidecarNamespace(from: server),
            TokenSaverDistillServiceController.sidecarNamespace(for: namespace)
        )
        XCTAssertFalse(
            TokenSaverDistillServiceController.sidecarCommand(
                mcp,
                belongsToNamespace: TokenSaverDistillServiceController.sidecarNamespace(for: namespace)
            ),
            "the multi-instance mcp helper must never enter sidecar singleton reaping"
        )
        XCTAssertFalse(
            TokenSaverDistillServiceController.sidecarCommand(
                malformed,
                belongsToNamespace: TokenSaverDistillServiceController.sidecarNamespace(for: namespace)
            ),
            "a sidecar without an explicit namespace must be left alive fail-open"
        )
    }

    private final class CapturingSpawner: DistillProcessSpawning, @unchecked Sendable {
        var spawnCount = 0
        func spawn(executableURL: URL, arguments: [String]) throws -> DistillSpawnResult {
            spawnCount += 1
            let process = Process()
            let stdout = Pipe(), stderr = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "sleep 5"]
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            return DistillSpawnResult(
                process: process,
                stdoutHandle: stdout.fileHandleForReading,
                stderrHandle: stderr.fileHandleForReading
            )
        }
    }

    private final class OverlapTrackingSpawner: DistillProcessSpawning, @unchecked Sendable {
        var processes: [Process] = []
        var spawnedWhilePreviousProcessWasLive = false

        func spawn(executableURL: URL, arguments: [String]) throws -> DistillSpawnResult {
            if processes.contains(where: \.isRunning) {
                spawnedWhilePreviousProcessWasLive = true
            }
            let process = Process()
            let stdout = Pipe(), stderr = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "trap '' TERM; while :; do sleep 1; done"]
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            processes.append(process)
            return DistillSpawnResult(
                process: process,
                stdoutHandle: stdout.fileHandleForReading,
                stderrHandle: stderr.fileHandleForReading
            )
        }
    }

    /// The foreign-server terminator now runs off the main actor (start() sweeps
    /// on a detached task before spawning), so a `@Sendable` recorder replaces the
    /// captured `var` the old synchronous test doubles used.
    private final class KeepArgsRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Int32?] = []
        func record(_ value: Int32?) { lock.lock(); storage.append(value); lock.unlock() }
        func removeAll() { lock.lock(); storage.removeAll(); lock.unlock() }
        var values: [Int32?] { lock.lock(); defer { lock.unlock() }; return storage }
    }

    private func paidSession() -> PrivateAccountSession {
        PrivateAccountSession(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            user: PrivateAccountUser(
                daysRemaing: nil,
                daysRemaining: 30,
                email: "paid@example.com",
                id: "paid-user",
                subscribed: true
            )
        )
    }

    func test_start_reapsForeignServersBeforeSpawn() async {
        // WHY: two multi-GB MLX Distill servers freeze the machine; start must
        // clear foreign servers before launching the singleton. The sweep now
        // runs off the main actor (so it can't block the UI), then spawns — so
        // the test awaits the deferred spawn instead of asserting synchronously.
        let keepArgs = KeepArgsRecorder()
        let spawner = CapturingSpawner()
        let controller = TokenSaverDistillServiceController(
            appSupportDirectory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            executableURLResolver: { URL(fileURLWithPath: "/bin/sh") },
            processSpawner: spawner,
            terminateForeignServers: { keep in
                keepArgs.record(keep)
                return ProviderProcessSweepResult(orphanRootPIDs: [1], terminatedPIDs: [1], failedPIDs: [])
            }
        )

        controller.startIfEligible(
            session: paidSession(),
            settings: AppSettings(tokenSaverEnabled: true),
            modelValidation: .installed
        )
        defer { controller.stop() }

        let spawned = await waitUntil(timeout: 2) { spawner.spawnCount == 1 }
        XCTAssertTrue(spawned, "eligible start must spawn exactly one sidecar")
        // The sweep completes before the spawn, so its record is present once spawned.
        XCTAssertFalse(keepArgs.values.isEmpty, "start must invoke the foreign-server terminator")
        XCTAssertEqual(keepArgs.values.first!, nil as Int32?,
                       "pre-spawn singleton gate keeps no prior server")
    }

    func test_failedSameNamespaceSweepBlocksSecondSidecarSpawn() async {
        // WHY: a failed TERM/KILL handoff means the same-namespace MLX server
        // may still hold the model. Spawning anyway recreates the memory
        // contention and UI hang that the singleton gate is meant to prevent.
        let spawner = CapturingSpawner()
        let controller = TokenSaverDistillServiceController(
            appSupportDirectory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            executableURLResolver: { URL(fileURLWithPath: "/bin/sh") },
            processSpawner: spawner,
            terminateForeignServers: { _ in
                ProviderProcessSweepResult(orphanRootPIDs: [42], terminatedPIDs: [], failedPIDs: [42])
            }
        )
        defer { controller.stop() }

        controller.startIfEligible(
            session: paidSession(),
            settings: AppSettings(tokenSaverEnabled: true),
            modelValidation: .installed
        )

        let failed = await waitUntil(timeout: 2) {
            if case .failed = controller.status { return true }
            return false
        }
        XCTAssertTrue(failed, "a failed namespace handoff must surface a failed status")
        XCTAssertEqual(spawner.spawnCount, 0, "a failed handoff must never launch a second sidecar")
    }

    func test_stopTerminatesOnlyControllerOwnedProcess() async {
        // WHY: stop has an exact Process handle and must not broaden ownership by
        // scanning command text; crash leftovers are handled by the identity ledger.
        let keepArgs = KeepArgsRecorder()
        let spawner = CapturingSpawner()
        let controller = TokenSaverDistillServiceController(
            appSupportDirectory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            executableURLResolver: { URL(fileURLWithPath: "/bin/sh") },
            processSpawner: spawner,
            terminateForeignServers: { keep in
                keepArgs.record(keep)
                return ProviderProcessSweepResult(orphanRootPIDs: [], terminatedPIDs: [], failedPIDs: [])
            }
        )
        controller.startIfEligible(
            session: paidSession(),
            settings: AppSettings(tokenSaverEnabled: true),
            modelValidation: .installed
        )
        // Let start()'s off-main sweep + spawn finish, then clear so the assertion
        // measures only what stop() itself invokes (which must be no sweep).
        _ = await waitUntil(timeout: 2) { spawner.spawnCount == 1 }
        keepArgs.removeAll()
        controller.stop()

        XCTAssertTrue(keepArgs.values.isEmpty,
                      "stop must not invoke a command/PPID-based foreign-process sweep")
        if case .notStarted = controller.status {
            // ok
        } else {
            XCTFail("stop must reset status to notStarted, got \(controller.status)")
        }
    }

    func test_rapidStopStartWaitsForExactPreviousProcessExitBeforeRespawn() async throws {
        // WHY: clearing the Process handle immediately after SIGTERM allowed a
        // second multi-GB sidecar to spawn while a TERM-resistant first instance
        // was still alive. The handoff must serialize on exact lifetime exit.
        let spawner = OverlapTrackingSpawner()
        let controller = TokenSaverDistillServiceController(
            appSupportDirectory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            executableURLResolver: { URL(fileURLWithPath: "/bin/sh") },
            processSpawner: spawner,
            terminateForeignServers: { _ in
                ProviderProcessSweepResult(orphanRootPIDs: [], terminatedPIDs: [], failedPIDs: [])
            },
            ownedProcessTerminationTimeout: 1
        )

        controller.startIfEligible(
            session: paidSession(),
            settings: AppSettings(tokenSaverEnabled: true),
            modelValidation: .installed
        )
        // start() now sweeps off-main before spawning, so await the first spawn.
        let firstSpawned = await waitUntil(timeout: 2) { spawner.processes.count == 1 }
        XCTAssertTrue(firstSpawned, "first eligible start must spawn one sidecar")
        let first = try XCTUnwrap(spawner.processes.first)
        controller.stop()
        controller.startIfEligible(
            session: paidSession(),
            settings: AppSettings(tokenSaverEnabled: true),
            modelValidation: .installed
        )
        XCTAssertEqual(spawner.processes.count, 1,
                       "rapid restart must queue while the previous exact lifetime is terminating")

        let respawned = await waitUntil(timeout: 3) { spawner.processes.count == 2 }
        XCTAssertTrue(respawned, "the queued restart must proceed after bounded termination")
        XCTAssertFalse(first.isRunning)
        XCTAssertFalse(spawner.spawnedWhilePreviousProcessWasLive,
                       "there must never be two controller-owned sidecar processes alive at spawn")

        controller.stop()
        let stopped = await waitUntil(timeout: 2) {
            spawner.processes.allSatisfy { !$0.isRunning }
        }
        XCTAssertTrue(stopped, "the real subprocess fixture must leave no live sidecar")
    }

    func test_willTerminateDistillPolicy_alwaysStopsServer() {
        // Pure documentation of the quit contract used by AppDelegate:
        // skills may retain, Distill MLX server must always stop.
        XCTAssertTrue(
            AppDelegate.shouldStopDistillServerOnTerminate(tokenSaverEnabled: true),
            "Token Saver enabled must still stop the Distill server on quit"
        )
        XCTAssertTrue(
            AppDelegate.shouldStopDistillServerOnTerminate(tokenSaverEnabled: false),
            "Token Saver disabled must still stop the Distill server on quit"
        )
    }

    private func waitUntil(
        timeout: TimeInterval,
        condition: @escaping () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }
}
