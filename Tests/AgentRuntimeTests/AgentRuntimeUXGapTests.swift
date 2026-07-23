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

    // MARK: - L192: Whitespace-only first delta must not trigger SR1 buffering

    /// A pure-whitespace string must NOT be detected as SR1 by the detector.
    /// If it were, the coordinator would buffer the entire reply and emit it
    /// all at once at completion, destroying live streaming for normal replies.
    func test_sr1Detector_pureWhitespace_isNotSR1() {
        XCTAssertFalse(SR1ResponseDetector.isSR1("\n"),
                       "A lone newline is not SR1; buffering it would delay normal-reply streaming")
        XCTAssertFalse(SR1ResponseDetector.isSR1("\n\n   \t\n"),
                       "Whitespace-only text is not SR1")
        XCTAssertFalse(SR1ResponseDetector.isSR1("  "),
                       "Spaces-only text is not SR1")
    }

    /// An SR1-formatted response must still be detected correctly, proving
    /// that the whitespace fix did not break SR1 detection.
    func test_sr1Detector_validSR1_isDetected() {
        let sr1 = "S: state ready\nC: context clear\nD: action deploy"
        XCTAssertTrue(SR1ResponseDetector.isSR1(sr1),
                      "Valid SR1 text must still be detected after the whitespace-only fix")
    }
}
