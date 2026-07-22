// TokenSaverResidentSidecarTests.swift
//
// WHY these tests exist (Rule 8):
// The controller used to kill the sidecar process after `idleTimeoutMS` of no
// APP-routed activity. Terminal `cmd | distill` talks straight to the sidecar
// socket and cannot autostart it, so once the sidecar was idle-killed every
// `| distill` failed open with zero recorded savings — the "saved stuck at 36k"
// symptom. The fix keeps the sidecar resident while Token Saver is enabled and
// delegates model-RAM reclaim to the SERVER (which already frees GPU memory when
// its request queue drains). These tests pin that contract:
//   (a) start() forwards the configured idle-timeout to the sidecar so the
//       server, not the controller, manages model RAM.
//   (b) a savings_recorded event still refreshes the Token Saver UI.

import Foundation
import XCTest
import CoreModel
import DistillCore
import Persistence
@testable import AppShell

@MainActor
final class TokenSaverResidentSidecarTests: XCTestCase {

    /// Captures the argv start() passes to the spawner so the idle-timeout
    /// wiring is asserted without a real RemoteCodeDistillService binary.
    private final class CapturingSpawner: DistillProcessSpawning, @unchecked Sendable {
        var capturedArguments: [String] = []
        func spawn(executableURL: URL, arguments: [String]) throws -> DistillSpawnResult {
            capturedArguments = arguments
            // A short-lived real process so the handles are valid; it never emits
            // a ready event, which is irrelevant to capturing the launch argv.
            let process = Process()
            let stdout = Pipe(), stderr = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "sleep 3"]
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

    func test_start_forwardsConfiguredIdleTimeoutToSidecar_soServerReclaimsModelRAM() {
        let spawner = CapturingSpawner()
        let controller = TokenSaverDistillServiceController(
            appSupportDirectory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            executableURLResolver: { URL(fileURLWithPath: "/bin/sh") },
            idleTimeoutMS: 123_000,
            processSpawner: spawner
        )

        controller.startIfEligible(
            session: paidSession(),
            settings: AppSettings(tokenSaverEnabled: true),
            modelValidation: .installed
        )
        defer { controller.stop() }

        let args = spawner.capturedArguments
        let idx = args.firstIndex(of: "--idle-timeout-ms")
        let value = idx.flatMap { args.indices.contains(args.index(after: $0)) ? args[args.index(after: $0)] : nil }
        XCTAssertEqual(value, "123000",
            "the controller must forward its configured idle-timeout to the sidecar: the SERVER reclaims model RAM on queue-drain while the controller keeps the process resident so terminal | distill always reaches a live server")
    }

    func test_lowMemoryProfileBoundsSidecarConcurrencyAndQueue() {
        let spawner = CapturingSpawner()
        let controller = TokenSaverDistillServiceController(
            appSupportDirectory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            executableURLResolver: { URL(fileURLWithPath: "/bin/sh") },
            processSpawner: spawner,
            memoryProfileProvider: {
                ManagedProcessMemoryProfile.resolve(
                    physicalMemoryBytes: UInt64(8) * 1_024 * 1_024 * 1_024
                )
            }
        )

        controller.startIfEligible(
            session: paidSession(),
            settings: AppSettings(tokenSaverEnabled: true),
            modelValidation: .installed
        )
        defer { controller.stop() }

        let args = spawner.capturedArguments
        let requestIndex = args.firstIndex(of: "--max-concurrent-requests")
        let queueIndex = args.firstIndex(of: "--max-queue-depth")
        XCTAssertEqual(requestIndex.map { args[$0 + 1] }, "1")
        XCTAssertEqual(queueIndex.map { args[$0 + 1] }, "4")
    }

    func test_savingsRecordedEvent_refreshesTokenSaverUI() {
        let controller = TokenSaverDistillServiceController(
            appSupportDirectory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            executableURLResolver: { nil }
        )
        var fired = false
        let observer = NotificationCenter.default.addObserver(
            forName: .rc2TokenSaverUsageChanged, object: nil, queue: nil
        ) { _ in fired = true }
        defer { NotificationCenter.default.removeObserver(observer) }

        let line = Data(#"{"event":"savings_recorded","provider":"unknown","mode":"command-output (model)","input_tokens":30,"output_tokens":6,"saved_tokens":24}"#.utf8)
        controller.handleRunningOutputLine(line)
        XCTAssertTrue(fired, "a savings_recorded event must refresh the Token Saver card so the saved total updates live")
    }

    func test_unrelatedSidecarOutput_doesNotRefreshUI() {
        let controller = TokenSaverDistillServiceController(
            appSupportDirectory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            executableURLResolver: { nil }
        )
        var fired = false
        let observer = NotificationCenter.default.addObserver(
            forName: .rc2TokenSaverUsageChanged, object: nil, queue: nil
        ) { _ in fired = true }
        defer { NotificationCenter.default.removeObserver(observer) }

        controller.handleRunningOutputLine(Data(#"{"event":"heartbeat"}"#.utf8))
        controller.handleRunningOutputLine(Data("not json".utf8))
        XCTAssertFalse(fired, "non-savings sidecar output must not trigger a Token Saver UI refresh")
    }
}
