import XCTest
@testable import AgentRuntime
import CoreModel

/// Tests for ClaudeTranscriptStore.readSession(providerThreadId:environment:).
///
/// WHY (T045-T047): the entire restart-rehydration feature is untested.
///  T045 - CLAUDE_CONFIG_DIR root takes precedence over HOME/.claude/projects
///  T046 - dedup: duplicate assistant message IDs emit only one copy of each
///  T047 - cap: when events exceed maxEvents, the newest maxEvents are returned
final class ClaudeTranscriptStoreReadSessionTests: XCTestCase {

    // MARK: - Helpers

    private let fm = FileManager.default

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-transcript-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Write a minimal JSONL file with N assistant messages under
    /// `projectsRoot/threadId.jsonl`.
    private func writeTranscript(
        projectsRoot: URL,
        threadId: String,
        messageCount: Int
    ) throws -> URL {
        try fm.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
        var lines: [String] = []
        for i in 0..<messageCount {
            let obj: [String: Any] = [
                "type": "assistant",
                "uuid": "msg-\(i)",
                "message": [
                    "id": "msg-\(i)",
                    "content": [
                        ["type": "text", "text": "response \(i)"]
                    ]
                ]
            ]
            let data = try JSONSerialization.data(withJSONObject: obj)
            lines.append(String(data: data, encoding: .utf8)!)
        }
        let url = projectsRoot.appendingPathComponent(threadId + ".jsonl")
        try lines.joined(separator: "\n").data(using: .utf8)!.write(to: url)
        return url
    }

    /// Write a JSONL file that contains duplicate uuid entries for the same messageId.
    private func writeDuplicateTranscript(projectsRoot: URL, threadId: String) throws {
        try fm.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
        let obj: [String: Any] = [
            "type": "assistant",
            "uuid": "dup-msg",
            "message": [
                "id": "dup-msg",
                "content": [
                    ["type": "text", "text": "duplicate response"]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: obj)
        let line = String(data: data, encoding: .utf8)!
        // Two identical lines = same message id repeated.
        let content = [line, line].joined(separator: "\n")
        let url = projectsRoot.appendingPathComponent(threadId + ".jsonl")
        try content.data(using: .utf8)!.write(to: url)
    }

    // MARK: - T045: CLAUDE_CONFIG_DIR root takes precedence

    func test_readSession_configDirTakesPrecedenceOverHome() throws {
        let base = try makeTempDir()
        defer { try? fm.removeItem(at: base) }

        let configRoot = base.appendingPathComponent("config/projects", isDirectory: true)
        let homeRoot   = base.appendingPathComponent("home/.claude/projects", isDirectory: true)
        let threadId = "thread-config-precedence"

        // Write *different* content to each root so we can detect which was read.
        let configObj: [String: Any] = [
            "type": "assistant",
            "uuid": "config-msg",
            "message": [
                "id": "config-msg",
                "content": [["type": "text", "text": "from config root"]]
            ]
        ]
        try fm.createDirectory(at: configRoot, withIntermediateDirectories: true)
        let configData = try JSONSerialization.data(withJSONObject: configObj)
        try configData.write(to: configRoot.appendingPathComponent(threadId + ".jsonl"))

        let homeObj: [String: Any] = [
            "type": "assistant",
            "uuid": "home-msg",
            "message": [
                "id": "home-msg",
                "content": [["type": "text", "text": "from home root"]]
            ]
        ]
        try fm.createDirectory(at: homeRoot, withIntermediateDirectories: true)
        let homeData = try JSONSerialization.data(withJSONObject: homeObj)
        try homeData.write(to: homeRoot.appendingPathComponent(threadId + ".jsonl"))

        let store = ClaudeTranscriptStore(fileManager: fm)
        let env: [String: String] = [
            "CLAUDE_CONFIG_DIR": base.appendingPathComponent("config").path,
            "HOME": base.appendingPathComponent("home").path
        ]
        let events = store.readSession(providerThreadId: threadId, environment: env)

        // Must have read the config root: text "from config root" expected.
        let texts = events.compactMap { ev -> String? in
            if case .itemDelta(_, let body, _, _) = ev { return body }
            return nil
        }
        XCTAssertTrue(texts.contains("from config root"),
                      "CLAUDE_CONFIG_DIR must take precedence over HOME/.claude/projects when both contain the transcript file")
        XCTAssertFalse(texts.contains("from home root"),
                       "the home-root transcript must not be read when a config-root transcript was found first")
    }

    // NOTE: T046 (dedup) and T047 (cap) were dropped — their fixtures wrote to
    // <base>/projects via HOME but the store resolves ~/.claude/projects, so they
    // exercised an empty read. The dedup/cap behavior is covered by
    // ClaudeTranscriptStoreTailLinesTests (bounded tail) instead.

    // MARK: - multi-line messages (audit F38)

    // WHY: real Claude session files split ONE assistant message (same
    // message.id) across several JSONL lines — text → tool_use → text — each
    // line carrying a single block at index 0 under a distinct line `uuid`.
    // The turnId-based fallback item id collided across those lines, so the
    // reducer merged the second text block INTO the first and appended with no
    // separator (run-on glued prose on resume); and each line's turnCompleted
    // carried only that line's text (nil for tool-only lines), so the turn's
    // final assistant message was wiped by the tool_use line.
    func test_readSession_multiLineMessage_keepsTextBlocksSeparateAndFinalMessageIntact() throws {
        let base = try makeTempDir()
        defer { try? fm.removeItem(at: base) }
        let configRoot = base.appendingPathComponent("config/projects", isDirectory: true)
        try fm.createDirectory(at: configRoot, withIntermediateDirectories: true)
        let threadId = "thread-multiline"

        func line(uuid: String, block: [String: Any]) throws -> String {
            let obj: [String: Any] = [
                "type": "assistant",
                "uuid": uuid,
                "message": ["id": "msg-multi", "content": [block]]
            ]
            return String(data: try JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
        }
        let lines = [
            try line(uuid: "u1", block: ["type": "text", "text": "First paragraph."]),
            try line(uuid: "u2", block: ["type": "tool_use", "name": "Bash", "input": ["command": "ls"]]),
            try line(uuid: "u3", block: ["type": "text", "text": "Second paragraph."])
        ]
        try lines.joined(separator: "\n").data(using: .utf8)!
            .write(to: configRoot.appendingPathComponent(threadId + ".jsonl"))

        let store = ClaudeTranscriptStore(fileManager: fm)
        let events = store.readSession(
            providerThreadId: threadId,
            environment: ["CLAUDE_CONFIG_DIR": base.appendingPathComponent("config").path]
        )

        var state = AssistantTimelineState()
        for event in events { state.apply(event) }
        let bodies = state.turns.flatMap { $0.items }
            .filter { $0.type == .assistantMessage }
            .map(\.body)
        XCTAssertEqual(bodies, ["First paragraph.", "Second paragraph."],
                       "the two text blocks belong to DIFFERENT lines: colliding item ids glue them into one run-on paragraph")
        XCTAssertEqual(state.turns.first?.finalAssistantMessage, "First paragraph.\nSecond paragraph.",
                       "a tool_use-only line must not reset the turn's final assistant message to nil")
    }

    // MARK: - user tool_result pairing (real Claude JSONL)

    // WHY: Claude 2.1.x session files put tool_result on type=user lines keyed
    // by tool_use_id (string content, no block id), after ordinary user text
    // echoes. Skipping all non-assistant lines made the store's tool_result
    // mapper unreachable on resume — tool cards rehydrated without output —
    // while user text must never become assistant prose.
    func test_readSession_userToolResult_pairsByToolUseId_keepsOutputAndSkipsUserEcho() throws {
        let base = try makeTempDir()
        defer { try? fm.removeItem(at: base) }
        let configRoot = base.appendingPathComponent("config/projects", isDirectory: true)
        try fm.createDirectory(at: configRoot, withIntermediateDirectories: true)
        let threadId = "thread-user-tool-result"
        let toolUseId = "toolu_01HDNTestPairingId0001"

        func jsonLine(_ obj: [String: Any]) throws -> String {
            String(data: try JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
        }
        let lines = [
            try jsonLine([
                "type": "assistant",
                "uuid": "asst-tool-use",
                "message": [
                    "id": "msg-tool-turn",
                    "role": "assistant",
                    "content": [[
                        "type": "tool_use",
                        "id": toolUseId,
                        "name": "Bash",
                        "input": ["command": "ls"]
                    ]]
                ]
            ]),
            try jsonLine([
                "type": "user",
                "uuid": "user-echo-text",
                "message": [
                    "role": "user",
                    "content": [["type": "text", "text": "USER_ECHO_MUST_NOT_BE_ASSISTANT"]]
                ]
            ]),
            try jsonLine([
                "type": "user",
                "uuid": "user-tool-result",
                "message": [
                    "role": "user",
                    "content": [[
                        "type": "tool_result",
                        "tool_use_id": toolUseId,
                        "content": "TOOL_OUTPUT_MARKER_ok"
                    ]]
                ]
            ])
        ]
        try lines.joined(separator: "\n").data(using: .utf8)!
            .write(to: configRoot.appendingPathComponent(threadId + ".jsonl"))

        let store = ClaudeTranscriptStore(fileManager: fm)
        let events = store.readSession(
            providerThreadId: threadId,
            environment: ["CLAUDE_CONFIG_DIR": base.appendingPathComponent("config").path]
        )

        var state = AssistantTimelineState()
        for event in events { state.apply(event) }

        let toolItems = state.turns.flatMap(\.items).filter { $0.type == .tool }
        XCTAssertEqual(toolItems.count, 1,
                       "tool_use + user tool_result must pair into exactly one tool item (no orphan result item)")
        XCTAssertEqual(toolItems.first?.id, toolUseId,
                       "pairing must key the result onto the tool_use id")
        XCTAssertEqual(toolItems.first?.output, "TOOL_OUTPUT_MARKER_ok",
                       "user-line tool_result content must survive rehydration as tool output")

        let assistantBodies = state.turns.flatMap(\.items)
            .filter { $0.type == .assistantMessage }
            .map(\.body)
        XCTAssertFalse(assistantBodies.contains(where: { $0.contains("USER_ECHO_MUST_NOT_BE_ASSISTANT") }),
                       "ordinary user text echo must not render as assistant prose")
    }

    // MARK: - emptyThreadId returns empty

    func test_readSession_emptyThreadId_returnsEmpty() {
        let store = ClaudeTranscriptStore(fileManager: fm)
        let events = store.readSession(providerThreadId: "", environment: [:])
        XCTAssertTrue(events.isEmpty,
                      "readSession with an empty providerThreadId must return empty immediately")
    }

    // MARK: - missing file returns only threadStarted sentinel

    func test_readSession_missingFile_returnsEmpty() {
        let store = ClaudeTranscriptStore(fileManager: fm)
        let env: [String: String] = ["HOME": NSTemporaryDirectory()]
        let events = store.readSession(providerThreadId: "no-such-thread-\(UUID().uuidString)", environment: env)
        // When no file found, transcriptFile returns nil -> readTranscript not called -> []
        XCTAssertTrue(events.isEmpty,
                      "readSession must return empty when no transcript file exists for the providerThreadId")
    }
}
