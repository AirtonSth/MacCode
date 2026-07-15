import XCTest
import CoreModel
@testable import AgentRuntime

/// Regression tests for ClaudeRunner's process-exit drain path:
///
/// 1. Stderr tail (audit F43): the terminationHandler drained the stdout tail
///    but never stderr, so a CLI that exits instantly (auth error) could lose
///    its one explanatory stderr line to the handler-teardown race and the run
///    finished .failed with no reason anywhere.
/// 2. Line-race safety (audit F36): the terminationHandler's drain used to run
///    unsynchronized against an in-flight readabilityHandler on the shared,
///    lock-free LineBuffer — concurrent Data mutation and split/reordered final
///    lines. Both readers are now serialized on one lock taken before the fd
///    read, so a burst that straddles process exit arrives complete and in
///    order (under TSan the pre-fix race is flagged directly).
final class ClaudeRunnerTerminationDrainTests: ProviderProcessTestCase {

    // WHY: when the CLI dies immediately, the stderr tail is the ONLY carrier
    // of the failure reason; if the exit path drops it the user sees a bare
    // 'Failed' with no explanation.
    func test_fastExitWithStderrError_surfacesTheReasonBeforeFinishing() async throws {
        let tmp = try makeTempDir(prefix: "rc2-claude-runner-stderr-tail")
        let script = tmp.appendingPathComponent("fake-claude")
        try """
        #!/bin/sh
        echo '{"type":"system","subtype":"init","session_id":"sess-tail"}'
        echo 'Error: Invalid API key - fast exit' 1>&2
        exit 1
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let sink = LockedRunnerEventSink()
        _ = try await ClaudeRunner().startRun(request(cwd: tmp.path, binary: script.path)) { sink.record($0) }

        try await waitUntil("run finished") { sink.finishedStatus() != nil }
        XCTAssertEqual(sink.finishedStatus(), .failed, "exit 1 must finish the run as failed")
        XCTAssertTrue(sink.errorMessages().contains { $0.contains("[claude stderr]") && $0.contains("Invalid API key") },
                      "the stderr failure reason must surface even when the process exits before the async stderr handler delivered it; got: \(sink.errorMessages())")
    }

    // WHY: the exit drain must apply the SAME classifier as the live handler —
    // otherwise benign warnings flushed at exit become fatal error banners.
    func test_fastExitWithOnlyStderrWarnings_staysClean() async throws {
        let tmp = try makeTempDir(prefix: "rc2-claude-runner-stderr-warn")
        let script = tmp.appendingPathComponent("fake-claude")
        try """
        #!/bin/sh
        echo '{"type":"system","subtype":"init","session_id":"sess-warn"}'
        echo '{"type":"result","subtype":"success","is_error":false,"result":"ok","session_id":"sess-warn"}'
        echo 'Warning: something benign at shutdown' 1>&2
        exit 0
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let sink = LockedRunnerEventSink()
        _ = try await ClaudeRunner().startRun(request(cwd: tmp.path, binary: script.path)) { sink.record($0) }

        try await waitUntil("run finished") { sink.finishedStatus() != nil }
        XCTAssertEqual(sink.finishedStatus(), .completed)
        XCTAssertTrue(sink.errorMessages().isEmpty,
                      "warning-only stderr drained at exit must be filtered like live stderr; got: \(sink.errorMessages())")
    }

    // WHY: a fast producer that exits mid-burst exercises the readability/
    // termination race on the shared LineBuffer. Every line must arrive intact
    // and exactly once — a dropped or spliced line here is the 'lost final
    // answer / corrupted result' failure the lock prevents.
    func test_burstThatStraddlesProcessExit_deliversEveryLineIntact() async throws {
        let lineCount = 400
        let tmp = try makeTempDir(prefix: "rc2-claude-runner-line-race")
        let script = tmp.appendingPathComponent("fake-claude")
        try """
        #!/bin/sh
        echo '{"type":"system","subtype":"init","session_id":"sess-burst"}'
        i=0
        while [ $i -lt \(lineCount) ]; do
          echo "{\\"type\\":\\"assistant\\",\\"message\\":{\\"content\\":[{\\"type\\":\\"text\\",\\"text\\":\\"chunk-$i\\"}]}}"
          i=$((i+1))
        done
        echo '{"type":"result","subtype":"success","is_error":false,"result":"done","session_id":"sess-burst"}'
        exit 0
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let sink = LockedRunnerEventSink()
        _ = try await ClaudeRunner().startRun(request(cwd: tmp.path, binary: script.path)) { sink.record($0) }

        try await waitUntil("run finished") { sink.finishedStatus() != nil }
        let bodies = sink.assistantBodies()
        XCTAssertEqual(Set(bodies).count, lineCount,
                       "every streamed line must survive the exit race exactly once (got \(bodies.count) deltas, \(Set(bodies).count) distinct)")
        XCTAssertEqual(sink.finalMessage(), "done",
                       "the terminal result line must not be split or reordered by the exit drain")
    }

    // MARK: - Helpers

    private func request(cwd: String, binary: String) -> AgentRunRequest {
        AgentRunRequest(
            threadId: AgentThreadID(),
            provider: .claude,
            model: "claude-haiku-4-5-20251001",
            cwd: cwd,
            prompt: "go",
            providerBinary: binary
        )
    }

    private func makeTempDir(prefix: String) throws -> URL {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out waiting for \(what)")
    }
}

/// Synchronous locked sink — records on the emitting thread so wait loops see
/// events without Task-scheduling lag.
private final class LockedRunnerEventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AgentRunEvent] = []

    func record(_ event: AgentRunEvent) {
        lock.lock(); events.append(event); lock.unlock()
    }

    private func snapshot() -> [AgentRunEvent] {
        lock.lock(); defer { lock.unlock() }; return events
    }

    func finishedStatus() -> AgentRunStatus? {
        for event in snapshot() {
            if case .finished(let status, _, _) = event { return status }
        }
        return nil
    }

    func finalMessage() -> String? {
        for event in snapshot() {
            if case .finished(_, let final, _) = event { return final }
        }
        return nil
    }

    func errorMessages() -> [String] {
        snapshot().compactMap { event in
            if case .error(let message) = event { return message }
            return nil
        }
    }

    func assistantBodies() -> [String] {
        snapshot().compactMap { event in
            if case .event(.itemDelta(_, let body, _, _)) = event, let body, body.hasPrefix("chunk-") { return body }
            return nil
        }
    }
}
