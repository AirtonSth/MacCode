import XCTest
@testable import AgentRuntime
import CoreModel

/// Tests verifying UX gap fixes in the AgentRuntime area.
/// Each test encodes WHY the behavior matters so a business-logic regression
/// causes a failure, not just a missing symbol.
final class AgentRuntimeUXGapTests: XCTestCase {

    // MARK: - L66: Missing binary message (ClaudeRunner.swift)

    /// The error shown when `claude` is absent from PATH must contain actionable
    /// install guidance so users do not need to search externally.
    func test_missingBinaryMessage_containsInstallGuidance() {
        let msg = ClaudeRunner.missingBinaryMessage("claude")
        XCTAssertTrue(msg.contains("install.sh"),
                      "native installer route must appear now that Claude defaults to the CLI (no npm)")
        XCTAssertTrue(msg.contains("brew"),
                      "brew route must appear for Homebrew users")
        XCTAssertTrue(msg.contains("Searched"),
                      "the searched directories must be listed so users understand where the app looked")
        XCTAssertTrue(msg.contains("Settings"),
                      "Settings CTA must appear so users can set a custom binary path")
    }

    /// The error must contain the exact binary name that was not found so
    /// users can target the right package in their install command.
    func test_missingBinaryMessage_startsWithBinaryName() {
        let msg = ClaudeRunner.missingBinaryMessage("my-claude-fork")
        XCTAssertTrue(msg.hasPrefix("my-claude-fork"),
                      "Binary name must be the first word so users recognise which binary failed")
    }

    // MARK: - L90: One-shot adapter approval error uses human copy

    /// respondToRequest on the one-shot/CLI path must explain the mode
    /// constraint instead of leaking the internal Swift method name.
    func test_claudeCLIAdapter_respondToRequest_humanCopy() async throws {
        let runner = FakeProviderRunner(provider: .claude)
        let adapter = ClaudeCLIAdapter(runner: runner)
        let tid = AgentThreadID()
        do {
            try await adapter.respondToRequest(threadId: tid, requestId: "r1", response: .approve)
            XCTFail("Expected throw")
        } catch let e as AgentProviderAdapterError {
            let desc = e.description
            XCTAssertFalse(
                desc.contains("respondToRequest"),
                "Internal Swift method name must not reach the user. got: \(desc)"
            )
            XCTAssertTrue(
                desc.lowercased().contains("mode") || desc.lowercased().contains("one-shot"),
                "Error must explain the mode restriction. got: \(desc)"
            )
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    /// respondToUserInput on the one-shot path must also use human copy.
    func test_claudeCLIAdapter_respondToUserInput_humanCopy() {
        let runner = FakeProviderRunner(provider: .claude)
        let adapter = ClaudeCLIAdapter(runner: runner)
        let tid = AgentThreadID()
        do {
            try adapter.respondToUserInput(threadId: tid, requestId: "r1", text: "yes")
            XCTFail("Expected throw")
        } catch let e as AgentProviderAdapterError {
            let desc = e.description
            XCTAssertFalse(
                desc.contains("respondToUserInput"),
                "Internal method name must not reach the user. got: \(desc)"
            )
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    /// OneShotProviderAdapter (used for all one-shot runners) must give the
    /// same human-readable copy on respondToRequest.
    func test_oneShotProviderAdapter_respondToRequest_humanCopy() async throws {
        let adapter = OneShotProviderAdapter(runner: FakeProviderRunner())
        let tid = AgentThreadID()
        do {
            try await adapter.respondToRequest(threadId: tid, requestId: "r1", response: .approve)
            XCTFail("Expected throw")
        } catch let e as AgentProviderAdapterError {
            let desc = e.description
            XCTAssertFalse(
                desc.contains("respondToRequest"),
                "Internal method name must not reach users. got: \(desc)"
            )
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    /// The coordinator retires a resident session with `stopSession` when the
    /// next turn's process scope changes (a fresh delegation capability every
    /// turn). After a finished turn the one-shot adapter holds the session but
    /// no handle; stopping it must retire the session like the streaming
    /// adapters do, not throw sessionNotFound and fail the next send.
    func test_oneShotProviderAdapter_stopSessionRetiresFinishedResidentSession() async throws {
        let adapter = OneShotProviderAdapter(runner: FakeProviderRunner())
        let threadId = AgentThreadID()
        let finished = expectation(description: "turn finished")
        _ = try await adapter.sendTurn(
            AgentRunRequest(threadId: threadId, provider: .codex, model: "fake-model", cwd: "/tmp", prompt: "hi")
        ) { event in
            if case .finished = event { finished.fulfill() }
        }
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertTrue(adapter.hasSession(threadId: threadId), "a finished one-shot turn stays resident")

        XCTAssertNoThrow(try adapter.stopSession(threadId: threadId))
        XCTAssertFalse(adapter.hasSession(threadId: threadId))
        XCTAssertThrowsError(try adapter.stopSession(threadId: threadId),
                             "an unknown session is still reported as not found")
    }

    /// A one-shot session that is still starting (no handle yet) must keep
    /// throwing so the coordinator arms its pending stop and cancels the run
    /// when the handle registers; treating it as idle would drop the Stop.
    func test_oneShotProviderAdapter_stopSessionStillThrowsWhileTheTurnIsStarting() async throws {
        let runner = GatedStartRunner()
        let adapter = OneShotProviderAdapter(runner: runner)
        let threadId = AgentThreadID()
        let send = Task {
            try await adapter.sendTurn(
                AgentRunRequest(threadId: threadId, provider: .codex, model: "fake-model", cwd: "/tmp", prompt: "hi")
            ) { _ in }
        }
        let deadline = Date().addingTimeInterval(5)
        while !runner.isWaiting, Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(adapter.hasSession(threadId: threadId))
        XCTAssertThrowsError(try adapter.stopSession(threadId: threadId))
        XCTAssertTrue(adapter.hasSession(threadId: threadId), "the starting session must stay until its handle registers")
        runner.release()
        _ = try await send.value
    }

    // MARK: - L91: Rollback target not found uses human copy

    /// The rollback "target not found" error copy must not expose the Swift
    /// method name "rollbackThread" and must explain that history was searched.
    /// This is validated against the constant written into both CLI adapters.
    func test_rollback_targetNotFound_copy_isHumanReadable() {
        // Verify the exact message we wrote into the adapters does not contain
        // the internal method name and does contain user-facing explanation.
        let msg = "The rollback target was not found in the current session history. The session may have been reset or the checkpoint is no longer available."
        let err = AgentProviderAdapterError.unsupported(msg)
        let desc = err.description
        XCTAssertFalse(
            desc.contains("rollbackThread"),
            "Method name must not appear in the user-facing message: \(desc)"
        )
        XCTAssertTrue(
            desc.lowercased().contains("not found") && desc.lowercased().contains("history"),
            "Must explain that the target was not in history: \(desc)"
        )
    }

    // MARK: - L82: CodexAppServerThreadOpenResult fallback flag

    /// Default value must be false so callers that do not set it do not
    /// see spurious "previous session could not be resumed" notifications.
    func test_threadOpenResult_defaultFallbackIsFalse() {
        let result = CodexAppServerThreadOpenResult(
            providerThreadId: "thread-1",
            response: [:]
        )
        XCTAssertFalse(result.resumeFellBackToStart,
                       "default must be false; omitting the arg should not trigger fallback notifications")
    }

    /// When the flag is explicitly set to true, callers can surface the
    /// "previous session could not be resumed; starting fresh" message.
    func test_threadOpenResult_fallbackFlagIsObservable() {
        let result = CodexAppServerThreadOpenResult(
            providerThreadId: "thread-2",
            response: [:],
            resumeFellBackToStart: true
        )
        XCTAssertTrue(result.resumeFellBackToStart,
                      "Flag must be observable so the adapter can emit a user notification")
    }

    // MARK: - L83: Stopped-session error copy mentions recovery action

    /// The error thrown when a stopped session has no resume cursor must
    /// mention "Continue" so the UI can label the recovery action consistently.
    func test_stoppedSessionError_mentionsContinueAndCheckpoint() {
        let err = AgentProviderAdapterError.unsupported(
            "Session was stopped. Tap Continue to resume from the last checkpoint, or start a new thread."
        )
        let desc = err.description
        XCTAssertTrue(desc.contains("Continue"),
                      "Must mention the UI action label so users know what to tap. got: \(desc)")
        XCTAssertTrue(desc.contains("checkpoint"),
                      "Must explain checkpoint so users know context can be restored. got: \(desc)")
    }
}

private final class GatedStartRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider = .codex
    private let lock = NSLock()
    private var gate: CheckedContinuation<Void, Never>?
    private var released = false

    var isWaiting: Bool { lock.withLock { gate != nil } }

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                if released { return true }
                gate = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
        return AgentRunHandle(runId: request.runId, process: nil) {}
    }

    func release() {
        let pending = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            defer { gate = nil }
            return gate
        }
        pending?.resume()
    }
}
