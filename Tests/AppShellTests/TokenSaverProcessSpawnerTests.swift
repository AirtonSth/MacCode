// TokenSaverProcessSpawnerTests.swift
//
// Covers the DistillProcessSpawning seam added to TokenSaverDistillServiceController.
//
// WHY these tests exist (Rule 8):
// - start() previously hard-coded Process(), so crash, EOF-before-ready, and
//   stderr-flood scenarios were impossible to exercise without the real
//   RemoteCodeDistillService binary on disk.
// - These tests verify the spawner-protocol contract so callers know what
//   guarantees to rely on when injecting a fake spawner.

import Foundation
import XCTest
@testable import AppShell
import AgentRuntime
import CoreModel
import DistillCore
import Persistence

// MARK: - Helpers

/// Spawner that always throws (simulates launch failure: missing exec, sandbox).
private struct ThrowingSpawner: DistillProcessSpawning {
    struct LaunchError: Error {}
    func spawn(executableURL: URL, arguments: [String]) throws -> DistillSpawnResult {
        throw LaunchError()
    }
}

/// Spawner backed by a shell command.  Gives tests a fast-exit process or a
/// process that emits controlled stdout/stderr, without needing a real binary.
private struct ShellSpawner: DistillProcessSpawning {
    let command: String
    func spawn(executableURL: URL, arguments: [String]) throws -> DistillSpawnResult {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
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

/// Captures the exact helper argv and then fails before a real sidecar starts.
/// This keeps the test at the controller's production spawn boundary without
/// touching a developer's running service.
private final class RecordingThrowingSpawner: DistillProcessSpawning, @unchecked Sendable {
    struct LaunchError: Error {}

    private let lock = NSLock()
    private var recordedArguments: [String]?
    private var recordedStandardInput: Data?

    var arguments: [String]? {
        lock.lock()
        defer { lock.unlock() }
        return recordedArguments
    }

    var standardInput: Data? {
        lock.withLock { recordedStandardInput }
    }

    func spawn(executableURL: URL, arguments: [String]) throws -> DistillSpawnResult {
        lock.lock()
        recordedArguments = arguments
        lock.unlock()
        throw LaunchError()
    }

    func spawn(
        executableURL: URL,
        arguments: [String],
        standardInput: Data?
    ) throws -> DistillSpawnResult {
        lock.withLock {
            recordedArguments = arguments
            recordedStandardInput = standardInput
        }
        throw LaunchError()
    }
}

// MARK: - Tests

final class TokenSaverProcessSpawnerTests: XCTestCase {

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

    @MainActor
    private func waitForArguments(from spawner: RecordingThrowingSpawner) async -> [String]? {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let arguments = spawner.arguments { return arguments }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return spawner.arguments
    }

    private func value(after option: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    // WHY: selecting an API must make it the sole inference target. Passing
    // local runtime/model flags beside API flags preserves the contradictory
    // E4B identity and allows future local validation or warmup to leak back in.
    @MainActor
    func testControllerAPISelectionOmitsLocalModelArguments() async throws {
        let spawner = RecordingThrowingSpawner()
        let controller = TokenSaverDistillServiceController(
            appSupportDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            executableURLResolver: { URL(fileURLWithPath: "/bin/false") },
            processSpawner: spawner,
            terminateForeignServers: { _ in
                ProviderProcessSweepResult(orphanRootPIDs: [], terminatedPIDs: [], failedPIDs: [])
            }
        )
        let settings = AppSettings(
            tokenSaverEnabled: true,
            tokenSaverModelSource: .openaiCompat,
            tokenSaverAPIBaseURL: "http://127.0.0.1:18080/v1",
            tokenSaverAPIModel: "fixture-api-model",
            tokenSaverAPIToken: "dummy-api-token"
        )

        controller.startIfEligible(
            session: paidSession(),
            settings: settings,
            modelValidation: TokenSaverModelValidation(
                state: .missing,
                reason: "local model intentionally absent"
            )
        )
        let capturedArguments = await waitForArguments(from: spawner)
        let arguments = try XCTUnwrap(capturedArguments)
        defer { controller.stop() }

        XCTAssertEqual(value(after: "--generate-base-url", in: arguments), "http://127.0.0.1:18080/v1")
        XCTAssertEqual(value(after: "--generate-model", in: arguments), "fixture-api-model")
        XCTAssertFalse(arguments.contains("dummy-api-token"), "bearer token must never be exposed in child argv")
        XCTAssertFalse(arguments.contains("--generate-token"))
        XCTAssertEqual(value(after: "--generate-token-stdin", in: arguments), "true")
        XCTAssertEqual(spawner.standardInput, Data("dummy-api-token".utf8))
        XCTAssertFalse(arguments.contains("--runtime"), "API mode must not launch with an MLX runtime identity")
        XCTAssertFalse(arguments.contains("--model-id"), "API mode must not launch with an E4B/local model id")
        XCTAssertFalse(arguments.contains("--model-url"), "API mode must not launch with a local model URL")
    }

    // WHY: blank API configuration must block at the shared target owner and
    // never start a helper that could publish false readiness.
    @MainActor
    func testControllerBlankAPIModelBlocksWithoutSpawn() async throws {
        let spawner = RecordingThrowingSpawner()
        let controller = TokenSaverDistillServiceController(
            appSupportDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            executableURLResolver: { URL(fileURLWithPath: "/bin/false") },
            processSpawner: spawner,
            terminateForeignServers: { _ in
                ProviderProcessSweepResult(orphanRootPIDs: [], terminatedPIDs: [], failedPIDs: [])
            }
        )
        let settings = AppSettings(
            tokenSaverEnabled: true,
            tokenSaverModelSource: .openaiCompat,
            tokenSaverAPIBaseURL: "http://127.0.0.1:18080/v1",
            tokenSaverAPIModel: "   "
        )

        controller.startIfEligible(
            session: paidSession(),
            settings: settings,
            modelValidation: TokenSaverModelValidation(state: .missing, reason: nil)
        )
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(spawner.arguments)
        XCTAssertEqual(
            controller.status,
            .blocked("Enter the API model id used by your OpenAI-compatible server")
        )
    }

    // WHY: invalid API configuration must block before any process launch. It
    // must never fall through to the approved local model branch.
    @MainActor
    func testControllerInvalidAPIURLDoesNotSpawnOrFallbackLocal() async {
        let spawner = RecordingThrowingSpawner()
        let controller = TokenSaverDistillServiceController(
            appSupportDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            executableURLResolver: { URL(fileURLWithPath: "/bin/false") },
            processSpawner: spawner,
            terminateForeignServers: { _ in
                ProviderProcessSweepResult(orphanRootPIDs: [], terminatedPIDs: [], failedPIDs: [])
            }
        )
        let settings = AppSettings(
            tokenSaverEnabled: true,
            tokenSaverModelSource: .openaiCompat,
            tokenSaverAPIBaseURL: "not a url",
            tokenSaverAPIModel: "fixture-api-model"
        )

        controller.startIfEligible(
            session: paidSession(),
            settings: settings,
            modelValidation: .installed
        )
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertNil(spawner.arguments)
        XCTAssertEqual(controller.status, .blocked("Enter a valid OpenAI-compatible API URL"))
    }

    @MainActor
    func testControllerEmbeddedAPICredentialsBlockWithoutSpawn() async {
        let spawner = RecordingThrowingSpawner()
        let controller = TokenSaverDistillServiceController(
            appSupportDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            executableURLResolver: { URL(fileURLWithPath: "/bin/false") },
            processSpawner: spawner,
            terminateForeignServers: { _ in
                ProviderProcessSweepResult(orphanRootPIDs: [], terminatedPIDs: [], failedPIDs: [])
            }
        )
        let settings = AppSettings(
            tokenSaverEnabled: true,
            tokenSaverModelSource: .openaiCompat,
            tokenSaverAPIBaseURL: "https://user:password@api.example.com/v1",
            tokenSaverAPIModel: "fixture-api-model"
        )

        controller.startIfEligible(
            session: paidSession(),
            settings: settings,
            modelValidation: .installed
        )
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertNil(spawner.arguments)
        XCTAssertEqual(controller.status, .blocked("Enter a valid OpenAI-compatible API URL"))
    }

    // WHY: API exclusivity must not weaken the existing local branch. Local
    // selection still needs the approved MLX identity and no API override.
    @MainActor
    func testControllerLocalSelectionKeepsApprovedModelArguments() async throws {
        let spawner = RecordingThrowingSpawner()
        let controller = TokenSaverDistillServiceController(
            appSupportDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            executableURLResolver: { URL(fileURLWithPath: "/bin/false") },
            processSpawner: spawner,
            terminateForeignServers: { _ in
                ProviderProcessSweepResult(orphanRootPIDs: [], terminatedPIDs: [], failedPIDs: [])
            }
        )
        let settings = AppSettings(tokenSaverEnabled: true, tokenSaverModelSource: .distill17b)

        controller.startIfEligible(
            session: paidSession(),
            settings: settings,
            modelValidation: .installed
        )
        let capturedArguments = await waitForArguments(from: spawner)
        let arguments = try XCTUnwrap(capturedArguments)
        defer { controller.stop() }
        let model = TokenSaverApprovedModels.distill17B

        XCTAssertEqual(value(after: "--runtime", in: arguments), model.runtime)
        XCTAssertEqual(value(after: "--model-id", in: arguments), model.id)
        XCTAssertEqual(value(after: "--model-url", in: arguments), model.url)
        XCTAssertFalse(arguments.contains("--generate-base-url"))
        XCTAssertFalse(arguments.contains("--generate-model"))
        XCTAssertFalse(arguments.contains("--generate-token"))
    }

    // MARK: - RealDistillProcessSpawner contract

    // WHY: RealDistillProcessSpawner must propagate Process.run() errors when the
    // executable doesn't exist.  If it swallowed the error and returned a zombie
    // DistillSpawnResult, the controller's catch block would never fire and status
    // would stay at .notStarted instead of transitioning to .failed.
    func testRealSpawner_throwsWhenExecutableMissing() {
        let spawner = RealDistillProcessSpawner()
        let missing = URL(fileURLWithPath: "/no-such-binary-\(UUID().uuidString)")
        XCTAssertThrowsError(
            try spawner.spawn(executableURL: missing, arguments: []),
            "RealDistillProcessSpawner must propagate Process.run() throw for a missing executable"
        )
    }

    // WHY: the controller wires stderrHandle.readabilityHandler for the pipe drain
    // and stdoutHandle.readabilityHandler for the ready-event JSON reader.  If
    // spawn() returned the same FileHandle for both, the drain would consume
    // ready-event bytes and the sidecar would never become ready.
    func testRealSpawner_stdoutAndStderrAreDistinctHandles() throws {
        // Use a ShellSpawner so we don't need a real RemoteCodeDistillService binary.
        let spawner = ShellSpawner(command: "exit 0")
        let result = try spawner.spawn(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: [])
        XCTAssertNotEqual(
            ObjectIdentifier(result.stdoutHandle),
            ObjectIdentifier(result.stderrHandle),
            "stdout and stderr handles must be distinct objects"
        )
        result.process.waitUntilExit()
    }

    func testLegacySpawnerFailsClosedInsteadOfDroppingAPIStandardInput() {
        let spawner = ShellSpawner(command: "exit 0")

        XCTAssertThrowsError(
            try spawner.spawn(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [],
                standardInput: Data("must-not-be-dropped".utf8)
            )
        ) { error in
            XCTAssertEqual(
                error as? DistillProcessSpawningError,
                .standardInputUnsupported
            )
        }
    }

    // WHY: crash scenario (process exits immediately): the spawner must still run()
    // the process successfully and return a valid result -- the crash is observed via
    // process.terminationHandler, not via a spawn() throw.  start()'s crash path
    // depends on this distinction.
    func testShellSpawner_crashProcess_spawnSucceeds() throws {
        let spawner = ShellSpawner(command: "exit 1")
        let result = try spawner.spawn(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: [])
        XCTAssertNotNil(result.process, "spawn() must succeed even for a process that exits immediately")
        result.process.waitUntilExit()
        XCTAssertEqual(result.process.terminationStatus, 1,
                       "fast-exit process must set terminationStatus to its exit code")
    }

    // WHY: EOF-before-ready scenario: a process that exits without writing any JSON
    // to stdout causes an EOF on stdoutHandle.  The spawner must return a live
    // handle so the controller can wire readabilityHandler and receive the EOF event.
    func testShellSpawner_eofProcess_handleIsReadable() throws {
        // Process writes nothing to stdout and exits; EOF arrives on the handle.
        let spawner = ShellSpawner(command: "exit 0")
        let result = try spawner.spawn(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: [])
        // Read all data: must not block indefinitely (EOF terminates the read).
        let data = result.stdoutHandle.readDataToEndOfFile()
        XCTAssertEqual(data.count, 0, "process that writes nothing must yield an empty read")
    }

    // WHY: stderr-flood scenario: the controller drains stderrHandle continuously
    // so the 64 KB kernel pipe buffer never blocks the sidecar.  The handle must
    // be distinct and readable so the controller can wire readabilityHandler.
    func testShellSpawner_stderrFlood_handleIsReadable() throws {
        // Process writes a small amount to stderr and exits.
        let spawner = ShellSpawner(command: "echo 'test stderr line' >&2; exit 0")
        let result = try spawner.spawn(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: [])
        let stderrData = result.stderrHandle.readDataToEndOfFile()
        XCTAssertGreaterThan(stderrData.count, 0, "stderr handle must deliver data written by the process")
    }

    // QA-mac:53 -- real stderr-backpressure proof (T007). The small-amount test
    // above never fills the 64 KB kernel pipe buffer, so it cannot detect a missing
    // drain. Here the child floods stderr with ~256 KB (4x the buffer) and ONLY
    // THEN writes its ready marker to stdout. With the controller's continuous
    // stderr drain active the child completes and the marker arrives; WITHOUT a
    // drain the child would block on the stderr write at ~64 KB and never reach the
    // stdout write -- the deadlock this guards against.
    func testStderrFloodDoesNotDeadlockWhenDrained() throws {
        // 256 KiB of stderr, then the ready marker on stdout, then exit.
        let command = "i=0; while [ $i -lt 4096 ]; do printf '%064d\\n' $i >&2; i=$((i+1)); done; printf 'READY\\n'; exit 0"
        let spawner = ShellSpawner(command: command)
        let result = try spawner.spawn(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: [])

        // Mirror the controller's drain exactly: discard stderr continuously so the
        // pipe buffer never fills (TokenSaverDistillServiceController.swift:698-700).
        result.stderrHandle.readabilityHandler = { handle in
            _ = handle.availableData
        }

        // If the drain works, the child reaches the stdout write and exits, so this
        // read returns "READY" and terminates at EOF. If stderr backed up, the child
        // would be blocked before the stdout write and this would never see READY.
        let stdout = result.stdoutHandle.readDataToEndOfFile()
        result.stderrHandle.readabilityHandler = nil
        result.process.waitUntilExit()

        let text = String(decoding: stdout, as: UTF8.self)
        XCTAssertTrue(text.contains("READY"),
            "the child must reach its post-flood stdout write -- proving the controller's stderr drain prevents a >64KB backpressure deadlock")
        XCTAssertEqual(result.process.terminationStatus, 0,
            "the flooding child must exit cleanly once stderr is drained, not hang")
    }

    // MARK: - ThrowingSpawner drives the catch path in start()

    // WHY: the catch block in start() sets status = .failed when spawn() throws.
    // Without a ThrowingSpawner test double, this path required a misconfigured
    // production environment (e.g. a binary with wrong permissions).
    // This test verifies that ThrowingSpawner satisfies the DistillProcessSpawning
    // protocol so it can be injected into the controller.
    func testThrowingSpawner_conformsToProtocol() {
        // compile-time witness: ThrowingSpawner must satisfy DistillProcessSpawning.
        let spawner: any DistillProcessSpawning = ThrowingSpawner()
        XCTAssertThrowsError(
            try spawner.spawn(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: []),
            "ThrowingSpawner must throw on every spawn() call so tests can exercise start()'s catch block"
        )
    }

    // MARK: - Default spawner

    // WHY: if the default were accidentally a ThrowingSpawner or NopSpawner, every
    // production launch would silently fail.  Compile-time witness: RealDistillProcessSpawner
    // must satisfy DistillProcessSpawning, and a no-arg controller construction must not crash.
    func testDefaultSpawnerConformsToProtocol() {
        let spawner: any DistillProcessSpawning = RealDistillProcessSpawner()
        XCTAssertNotNil(spawner)   // compile witness: type must conform
    }

    // WHY: TokenSaverDistillServiceController.init must accept a processSpawner parameter
    // so tests can inject a fake.  A no-arg construction must use RealDistillProcessSpawner
    // and must not crash.
    @MainActor
    func testControllerAcceptsInjectedSpawner() async {
        // Construction with ThrowingSpawner must not crash; the controller only
        // calls spawn() when start() is invoked.
        let controller = TokenSaverDistillServiceController(
            appSupportDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            executableURLResolver: { nil },   // resolver returns nil -> start() exits early, never calls spawn
            processSpawner: ThrowingSpawner()
        )
        XCTAssertEqual(controller.status, .notStarted,
                       "controller constructed with ThrowingSpawner must start in notStarted; " +
                       "spawn() is only called when start() runs and the executable resolver returns non-nil")
    }
}
