import XCTest
import CoreModel
@testable import AgentRuntime

final class ProviderCorpusFixtureTests: XCTestCase {
    func test_claudePrintStreamJsonCorpus_replaysThroughParser() throws {
        let lines = try fixtureLines("claude-print-stream-json.jsonl")
        XCTAssertEqual(lines.count, 4, "provider corpus must stay a compact real CLI transcript")

        let topLevelTypes = try lines.map { try decodeJSONObject($0)["type"] as? String }
        XCTAssertEqual(topLevelTypes, ["system", "rate_limit_event", "assistant", "result"],
                       "fixture must preserve the real Claude CLI event sequence, not a hand-built parser-only shape")

        let parser = ClaudeParser()
        var state = AssistantTimelineState()
        var allEvents: [AssistantEvent] = []
        for line in lines {
            let events = parser.parseLine(line)
            allEvents.append(contentsOf: events)
            for event in events { state.apply(event) }
        }
        let tail = parser.finalize()
        allEvents.append(contentsOf: tail)
        for event in tail { state.apply(event) }

        XCTAssertEqual(state.providerThreadId, "claude-session-0001")
        XCTAssertEqual(state.latestAssistantMessage, "RC2_PROVIDER_CORPUS_OK",
                       "real Claude assistant/result events must still render and finalize the turn")
        XCTAssertEqual(state.tokenUsage?.inputTokens, 31_358)
        XCTAssertEqual(state.tokenUsage?.outputTokens, 27)
        XCTAssertEqual(state.tokenUsage?.uncachedInputTokens, 516)
        XCTAssertEqual(state.tokenUsage?.cacheCreationInputTokens, 30_842,
                       "real modelUsage cache buckets must feed Token Saver instead of being flattened or dropped")
        XCTAssertTrue(allEvents.contains {
            if case .itemStarted(let item) = $0 {
                return item.type == .tool && item.summary == "Claude rate limit"
            }
            return false
        }, "real rate_limit_event lines must remain visible runtime activity")
    }

    func test_codexAppServerCorpus_replaysThroughClientParser() async throws {
        let fixture = fixtureURL("codex-app-server-session.jsonl")
        let script = try makeCodexAppServerReplayPeer(fixture: fixture)
        let notifications = LockedStrings()

        let client = try CodexAppServerClient(
            binary: script,
            arguments: [fixture.path],
            cwd: FileManager.default.temporaryDirectory.path,
            notificationHandler: { method, _ in notifications.append(method) }
        )
        defer { client.stop() }

        let initialized = try await client.initialize(
            clientName: "remotecode-corpus",
            clientTitle: "RemoteCode Corpus",
            clientVersion: "0.0.0"
        )
        XCTAssertEqual(initialized.codexHome, "<CODEX_HOME>")
        XCTAssertTrue(initialized.userAgent.contains("Codex Desktop/"),
                      "real app-server initialize response must keep the userAgent field RemoteCode displays")

        let models = try await client.listModels()
        let primary = try XCTUnwrap(models.first { $0.id == "gpt-5.5" })
        XCTAssertEqual(primary.supportedReasoningEfforts, [.low, .medium, .high, .xhigh])
        XCTAssertTrue(primary.supportsServiceTier,
                      "real model/list additionalSpeedTiers must continue to drive the Fast control")

        let opened = try await client.openThread(for: AgentRunRequest(
            threadId: AgentThreadID(),
            provider: .codex,
            model: "gpt-5.3-codex",
            cwd: "<WORKSPACE>",
            prompt: "fixture",
            permissionMode: .fullAccess
        ))
        XCTAssertEqual(opened.providerThreadId, "codex-thread-0001")
        let thread = try XCTUnwrap(opened.response["thread"] as? [String: Any])
        let status = try XCTUnwrap(thread["status"] as? [String: Any])
        XCTAssertEqual(status["type"] as? String, "idle",
                       "real thread/start response uses status.type, not the older fake status.state shape")
        XCTAssertNil(status["state"] as? String)

        do {
            _ = try await client.readThread(providerThreadId: opened.providerThreadId)
            XCTFail("fixture thread/read must replay the real app-server not-materialized error")
        } catch CodexAppServerError.rpcError(let code, let message) {
            XCTAssertEqual(code, -32600)
            XCTAssertTrue(message.contains("not materialized yet"),
                          "real app-server error text must remain loud enough to classify stale read failures")
        }

        let methods = notifications.values()
        XCTAssertTrue(methods.contains("remoteControl/status/changed"))
        XCTAssertTrue(methods.contains("thread/started"))
        XCTAssertTrue(methods.contains("mcpServer/startupStatus/updated"),
                      "notifications interleaved before RPC responses must be consumed, not treated as response corruption")
    }

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ProviderCorpus")
            .appendingPathComponent(name)
    }

    private func fixtureLines(_ name: String) throws -> [String] {
        try String(contentsOf: fixtureURL(name), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private func decodeJSONObject(_ line: String) throws -> [String: Any] {
        let value = try JSONSerialization.jsonObject(with: Data(line.utf8))
        return try XCTUnwrap(value as? [String: Any])
    }

    private func makeCodexAppServerReplayPeer(fixture: URL) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("remotecode-provider-corpus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("codex-app-server-replay.py")
        let source = """
        #!/usr/bin/env python3
        import json
        import sys

        with open(sys.argv[1]) as handle:
            transcript = [json.loads(line) for line in handle if line.strip()]

        cursor = 0

        def emit_until(request_id):
            global cursor
            while cursor < len(transcript):
                item = transcript[cursor]
                cursor += 1
                if item.get("direction") == "client":
                    continue
                message = item["message"]
                print(json.dumps(message, separators=(",", ":")), flush=True)
                if message.get("id") == request_id and "method" not in message:
                    return

        for line in sys.stdin:
            message = json.loads(line)
            if "id" not in message:
                continue
            emit_until(message["id"])
        """
        try source.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script.path
    }
}

private final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    func values() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
