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

    func test_stop_reapsAllServersAfterReleasingOwnedProcess() {
        // WHY: app quit calls stop(); leftover foreign/orphan servers must die
        // so RemoteCode never leaves a multi-GB Distill resident.
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

        XCTAssertEqual(keepArgs, [nil],
                       "stop must reap all Distill MLX servers (keepPID nil)")
        if case .notStarted = controller.status {
            // ok
        } else {
            XCTFail("stop must reset status to notStarted, got \(controller.status)")
        }
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
}
