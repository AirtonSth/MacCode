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

    func test_start_reapsForeignServersBeforeSpawn() {
        // WHY: two multi-GB MLX Distill servers freeze the machine; start must
        // clear foreign servers before launching the singleton.
        var keepArgs: [Int32?] = []
        let spawner = CapturingSpawner()
        let controller = TokenSaverDistillServiceController(
            appSupportDirectory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            executableURLResolver: { URL(fileURLWithPath: "/bin/sh") },
            processSpawner: spawner,
            terminateForeignServers: { keep in
                keepArgs.append(keep)
                return ProviderProcessSweepResult(orphanRootPIDs: [1], terminatedPIDs: [1], failedPIDs: [])
            }
        )

        controller.startIfEligible(
            session: paidSession(),
            settings: AppSettings(tokenSaverEnabled: true),
            modelValidation: .installed
        )
        defer { controller.stop() }

        XCTAssertEqual(spawner.spawnCount, 1, "eligible start must spawn exactly one sidecar")
        XCTAssertFalse(keepArgs.isEmpty, "start must invoke the foreign-server terminator")
        XCTAssertEqual(keepArgs.first!, nil as Int32?,
                       "pre-spawn singleton gate keeps no prior server")
    }

    func test_stopTerminatesOnlyControllerOwnedProcess() {
        // WHY: stop has an exact Process handle and must not broaden ownership by
        // scanning command text; crash leftovers are handled by the identity ledger.
        var keepArgs: [Int32?] = []
        let spawner = CapturingSpawner()
        let controller = TokenSaverDistillServiceController(
            appSupportDirectory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            executableURLResolver: { URL(fileURLWithPath: "/bin/sh") },
            processSpawner: spawner,
            terminateForeignServers: { keep in
                keepArgs.append(keep)
                return ProviderProcessSweepResult(orphanRootPIDs: [], terminatedPIDs: [], failedPIDs: [])
            }
        )
        controller.startIfEligible(
            session: paidSession(),
            settings: AppSettings(tokenSaverEnabled: true),
            modelValidation: .installed
        )
        keepArgs.removeAll()
        controller.stop()

        XCTAssertTrue(keepArgs.isEmpty,
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
        let first = try XCTUnwrap(spawner.processes.first)
        controller.stop()
        controller.startIfEligible(
            session: paidSession(),
            settings: AppSettings(tokenSaverEnabled: true),
            modelValidation: .installed
        )
        XCTAssertEqual(spawner.processes.count, 1,
                       "rapid restart must queue while the previous exact lifetime is terminating")

        let respawned = await waitUntil(timeout: 2) { spawner.processes.count == 2 }
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
