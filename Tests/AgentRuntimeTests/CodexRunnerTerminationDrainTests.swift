import XCTest
import CoreModel
@testable import AgentRuntime

/// Provider parity with ClaudeRunner/GrokRunner: Codex exec stdout drain must
/// serialize readabilityHandler against terminationHandler so LineBuffer and
/// CodexParser cannot race Dictionary/Data mutation on process exit — the same
/// class that SIGABRTed ClaudeTranscriptStore under concurrent recovery.
final class CodexRunnerTerminationDrainTests: ProviderProcessTestCase {

    // WHY: a fast producer that exits mid-burst exercises the readability/
    // termination race on the shared LineBuffer. Every line must arrive intact
    // — without stdoutReadLock this is the same concurrent mutation class as
    // the Claude path-index crash.
    func test_burstThatStraddlesProcessExit_deliversEveryLineIntact() async throws {
        let lineCount = 400
        let tmp = try makeTempDir(prefix: "rc2-codex-runner-line-race")
        let script = tmp.appendingPathComponent("fake-codex")
        try """
        #!/bin/sh
        echo '{"type":"thread.started","thread_id":"codex-burst"}'
        echo '{"type":"turn.started","turn_id":"turn-burst"}'
        i=0
        while [ $i -lt \(lineCount) ]; do
          echo "{\\"type\\":\\"item.delta\\",\\"item_id\\":\\"m1\\",\\"body_delta\\":\\"chunk-$i\\"}"
          i=$((i+1))
        done
        echo '{"type":"turn.completed","final_message":"done"}'
        exit 0
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let sink = CodexLockedRunnerEventSink()
        _ = try await CodexRunner().startRun(request(cwd: tmp.path, binary: script.path)) { sink.record($0) }

        try await waitUntil("run finished") { sink.finishedStatus() != nil }
        let bodies = sink.assistantBodies()
        XCTAssertEqual(Set(bodies).count, lineCount,
                       "every streamed line must survive the exit race exactly once (got \(bodies.count) deltas, \(Set(bodies).count) distinct)")
        XCTAssertEqual(sink.finalMessage(), "done",
                       "the terminal result line must not be split or reordered by the exit drain")
    }

    /// WHY: source-level provider parity — Claude/Codex/Grok exec runners and the
    /// Claude stream/SDK adapters must all serialize stdout drain. Codex/Grok ACP
    /// clients confine lineBuffer to a serial parseQueue instead of a named lock.
    func test_providerStdoutDrainSerialization_isPresentInShippedSources() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/AgentRuntimeTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
        let lockFiles = [
            "Sources/AgentRuntime/ClaudeRunner.swift",
            "Sources/AgentRuntime/CodexRunner.swift",
            "Sources/AgentRuntime/GrokRunner.swift",
            "Sources/AgentRuntime/ClaudeStreamingCLIAdapter.swift",
            "Sources/AgentRuntime/ClaudeAgentSDKBridgeAdapter.swift",
        ]
        for rel in lockFiles {
            let src = try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
            XCTAssertTrue(src.contains("stdoutReadLock"),
                          "\(rel) must serialize stdout drain with stdoutReadLock (same race class across providers)")
        }
        let queueFiles = [
            "Sources/AgentRuntime/CodexAppServerClient.swift",
            "Sources/AgentRuntime/GrokACPClient.swift",
        ]
        for rel in queueFiles {
            let src = try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
            XCTAssertTrue(src.contains("parseQueue"),
                          "\(rel) must confine lineBuffer to a serial parseQueue")
            XCTAssertTrue(src.contains("LineBuffer") || src.contains("lineBuffer"),
                          "\(rel) is expected to own a LineBuffer under parseQueue")
        }
        let transcript = try String(
            contentsOf: root.appendingPathComponent("Sources/AgentRuntime/ClaudeTranscriptStore.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(transcript.contains("pathIndexLock"),
                      "Claude transcript path cache must stay locked for concurrent recoverSession")
    }

    private func request(cwd: String, binary: String) -> AgentRunRequest {
        AgentRunRequest(
            threadId: AgentThreadID(),
            provider: .codex,
            model: "gpt-5.4",
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

private final class CodexLockedRunnerEventSink: @unchecked Sendable {
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

    func assistantBodies() -> [String] {
        snapshot().compactMap { event in
            if case .event(.itemDelta(_, let body, _, _)) = event, let body, body.hasPrefix("chunk-") {
                return body
            }
            return nil
        }
    }
}
