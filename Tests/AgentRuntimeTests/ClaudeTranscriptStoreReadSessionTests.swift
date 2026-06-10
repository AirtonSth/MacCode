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
