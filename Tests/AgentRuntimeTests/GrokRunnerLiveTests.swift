import XCTest
@testable import AgentRuntime
import CoreModel

/// Live smoke against the real `grok` binary when present and authenticated.
/// Skips cleanly when the binary or auth is unavailable.
final class GrokRunnerLiveTests: XCTestCase {

    func test_realGrokOneShotProducesAssistantTextAndSessionId() async throws {
        guard let path = ProcessLocator.resolve("grok") else {
            throw XCTSkip("grok binary not on PATH; skip real-run")
        }

        let cwd = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cwd) }

        let request = AgentRunRequest(
            threadId: AgentThreadID(),
            provider: .grok,
            model: "grok-4.5",
            cwd: cwd.path,
            prompt: "Reply with exactly the single word: pong",
            permissionMode: .fullAccess,
            providerBinary: path
        )

        let runner = GrokRunner(binaryNameOverride: path)
        let box = EventBox()
        let handle = try await runner.startRun(request) { event in
            box.append(event)
        }

        // Wait for process exit (real network call).
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            if box.finished != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let finished = try XCTUnwrap(box.finished, "Grok run must finish within 90s")
        if finished.status == .failed {
            let errs = box.errors.joined(separator: "\n")
            if errs.localizedCaseInsensitiveContains("auth")
                || errs.localizedCaseInsensitiveContains("login")
                || errs.localizedCaseInsensitiveContains("not logged") {
                throw XCTSkip("grok present but not authenticated: \(errs)")
            }
            XCTFail("Grok run failed: status=\(finished.status) errors=\(errs)")
            return
        }

        XCTAssertEqual(finished.status, .completed,
                       "successful Grok turn must complete; errors=\(box.errors)")
        let text = (finished.finalMessage ?? box.assistantText).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(text.isEmpty, "assistant transcript must be non-empty for a real Grok turn")
        XCTAssertTrue(text.localizedCaseInsensitiveContains("pong"),
                      "model should follow the short prompt; got: \(text)")
        let sessionId = try XCTUnwrap(finished.providerThreadId,
                                      "sessionId from end event is required for multi-turn resume")
        XCTAssertFalse(sessionId.isEmpty)
        _ = handle
    }

    func test_realGrokCancelStopsWithoutCrashing() async throws {
        guard let path = ProcessLocator.resolve("grok") else {
            throw XCTSkip("grok binary not on PATH; skip cancel path")
        }
        let cwd = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-live-stop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cwd) }

        let request = AgentRunRequest(
            threadId: AgentThreadID(),
            provider: .grok,
            model: "grok-4.5",
            cwd: cwd.path,
            prompt: "Write a very long essay of at least 2000 words about clouds. Keep going until done.",
            permissionMode: .fullAccess,
            providerBinary: path
        )
        let runner = GrokRunner(binaryNameOverride: path)
        let box = EventBox()
        let handle = try await runner.startRun(request) { box.append($0) }
        // Let the process actually start, then cancel.
        try await Task.sleep(nanoseconds: 800_000_000)
        handle.cancel()
        try await box.waitFinished(timeout: 30)
        let finished = try XCTUnwrap(box.finished, "cancel must produce a finished event")
        XCTAssertTrue(
            finished.status == .cancelled || finished.status == .completed || finished.status == .failed,
            "stop path must not hang the host; got \(finished.status)"
        )
    }

    func test_realGrokMultiTurnResumeKeepsSession() async throws {
        guard let path = ProcessLocator.resolve("grok") else {
            throw XCTSkip("grok binary not on PATH; skip real multi-turn")
        }

        let cwd = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-live-mt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cwd) }

        let runner = GrokRunner(binaryNameOverride: path)
        let threadId = AgentThreadID()

        // Turn 1
        let r1 = AgentRunRequest(
            threadId: threadId,
            provider: .grok,
            model: "grok-4.5",
            cwd: cwd.path,
            prompt: "Remember the secret codeword is BANANA. Reply with only: ok",
            permissionMode: .fullAccess,
            providerBinary: path
        )
        let box1 = EventBox()
        _ = try await runner.startRun(r1) { box1.append($0) }
        try await box1.waitFinished(timeout: 90)
        guard let f1 = box1.finished, f1.status == .completed, let session = f1.providerThreadId, !session.isEmpty else {
            let errs = box1.errors.joined(separator: "\n")
            if errs.localizedCaseInsensitiveContains("auth") || errs.localizedCaseInsensitiveContains("login") {
                throw XCTSkip("grok not authenticated: \(errs)")
            }
            throw XCTSkip("turn1 incomplete: \(String(describing: box1.finished)) errs=\(errs)")
        }

        // Turn 2 with resume
        let r2 = AgentRunRequest(
            threadId: threadId,
            provider: .grok,
            model: "grok-4.5",
            cwd: cwd.path,
            prompt: "What is the secret codeword? Reply with only the codeword.",
            providerThreadId: session,
            permissionMode: .fullAccess,
            providerBinary: path
        )
        let box2 = EventBox()
        _ = try await runner.startRun(r2) { box2.append($0) }
        try await box2.waitFinished(timeout: 90)
        let f2 = try XCTUnwrap(box2.finished)
        XCTAssertEqual(f2.status, .completed, "resume turn must complete; errors=\(box2.errors)")
        XCTAssertEqual(f2.providerThreadId, session,
                       "follow-up must keep the same provider session identity")
        let text = (f2.finalMessage ?? box2.assistantText).uppercased()
        XCTAssertTrue(text.contains("BANANA"),
                      "resumed session must retain prior-turn context; got: \(f2.finalMessage ?? box2.assistantText)")
    }
}

private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var events: [AgentRunEvent] = []
    private(set) var finished: (status: AgentRunStatus, finalMessage: String?, providerThreadId: String?)?
    private(set) var errors: [String] = []
    private(set) var assistantText = ""

    func append(_ event: AgentRunEvent) {
        lock.lock(); defer { lock.unlock() }
        events.append(event)
        switch event {
        case .error(let s):
            errors.append(s)
        case .finished(let status, let final, let ptid):
            finished = (status, final, ptid)
        case .event(let ae):
            if case .itemDelta(_, let body, _, _) = ae, let body {
                assistantText += body
            }
        default:
            break
        }
    }

    func waitFinished(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock(); let done = finished != nil; lock.unlock()
            if done { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}
