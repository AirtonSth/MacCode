import XCTest
import CoreModel
@testable import AgentRuntime

final class ClaudeStreamingCLIAdapterConcurrencyTests: XCTestCase {
    func test_streamEventsAndSessionQueriesStayRaceFreeDuringStreamingTurn() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-claude-streaming-concurrency-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let script = tmp.appendingPathComponent("fake-claude")
        try """
        #!/usr/bin/env python3
        import json, sys, time
        session = "claude-stream-concurrency-session"
        print(json.dumps({"type":"system","subtype":"init","session_id":session}), flush=True)
        for line in sys.stdin:
            if not line.strip():
                continue
            for i in range(120):
                print(json.dumps({"type":"assistant","message":{"content":[{"type":"text","text":"CONCURRENCY_CHUNK_%03d" % i}]},"session_id":session}), flush=True)
                time.sleep(0.001)
            print(json.dumps({"type":"result","subtype":"success","is_error":False,"result":"CONCURRENCY_DONE","session_id":session}), flush=True)
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let adapter = ClaudeStreamingCLIAdapter(binaryNameOverride: script.path, maxReadableEvents: 1_000)
        let threadId = AgentThreadID()
        let sink = ConcurrentEventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "claude-haiku-4-5-20251001",
            cwd: tmp.path,
            prompt: "stress"
        )) { event in
            Task { await sink.record(event) }
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    for iteration in 0..<80 {
                        try adapter.streamEvents(threadId: threadId) { event in
                            Task { await sink.record(event) }
                        }
                        _ = adapter.listSessions()
                        _ = try? await adapter.readThread(threadId: threadId)
                        if (worker + iteration) % 8 == 0 {
                            try await Task.sleep(nanoseconds: 1_000_000)
                        }
                    }
                }
            }
            try await group.waitForAll()
        }

        try await waitUntilCompleted(adapter: adapter, threadId: threadId)
        let readable = try await adapter.readThread(threadId: threadId)
        XCTAssertTrue(readable.contains {
            if case .turnCompleted(_, let finalMessage) = $0 {
                return finalMessage?.contains("CONCURRENCY_DONE") == true
            }
            return false
        }, "the streaming turn must still complete while streamEvents and session queries race the stdout handler")
        try adapter.stopSession(threadId: threadId)
    }

    private func waitUntilCompleted(adapter: ClaudeStreamingCLIAdapter, threadId: AgentThreadID) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let events = try await adapter.readThread(threadId: threadId)
            if events.contains(where: {
                if case .turnCompleted = $0 { return true }
                return false
            }) {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out waiting for streaming concurrency turn completion")
    }
}

private actor ConcurrentEventSink {
    private var events: [AgentRunEvent] = []
    func record(_ event: AgentRunEvent) { events.append(event) }
}
