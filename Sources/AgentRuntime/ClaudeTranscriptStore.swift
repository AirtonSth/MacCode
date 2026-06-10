import Foundation
import CoreModel

/// Pure in-memory cache: providerThreadId -> transcript file URL.
/// Thread-safety is the caller's responsibility (ClaudeTranscriptStore is
/// @unchecked Sendable and guards access itself).
public struct TranscriptPathIndex {
    private var storage: [String: URL] = [:]

    public init() {}

    /// Returns the cached path for `providerThreadId`, or nil on a miss.
    public func path(forProviderThreadId id: String) -> URL? {
        guard !id.isEmpty else { return nil }
        return storage[id]
    }

    /// Stores or replaces the path for `providerThreadId`.
    /// Silently ignores empty ids to match ClaudeTranscriptStore's guard.
    public mutating func setPath(_ url: URL, forProviderThreadId id: String) {
        guard !id.isEmpty else { return }
        storage[id] = url
    }
}

public final class ClaudeTranscriptStore: @unchecked Sendable {
    private let fileManager: FileManager
    private let maxEvents: Int
    private var pathIndex = TranscriptPathIndex()

    public init(fileManager: FileManager = .default, maxEvents: Int = 5_000) {
        self.fileManager = fileManager
        self.maxEvents = max(1, maxEvents)
    }

    public func readSession(providerThreadId: String, environment: [String: String]) -> [AssistantEvent] {
        guard !providerThreadId.isEmpty,
              let file = transcriptFile(providerThreadId: providerThreadId, environment: environment) else {
            return []
        }
        return readTranscript(file: file, providerThreadId: providerThreadId)
    }

    private func transcriptFile(providerThreadId: String, environment: [String: String]) -> URL? {
        if let cached = pathIndex.path(forProviderThreadId: providerThreadId) {
            if fileManager.fileExists(atPath: cached.path) {
                return cached
            }
            // Cached path no longer valid — fall through to re-enumerate.
        }
        for projectsRoot in projectsRoots(environment: environment) {
            let direct = projectsRoot.appendingPathComponent(providerThreadId + ".jsonl")
            if fileManager.fileExists(atPath: direct.path) {
                pathIndex.setPath(direct, forProviderThreadId: providerThreadId)
                return direct
            }
            guard let enumerator = fileManager.enumerator(
                at: projectsRoot,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }
            for case let url as URL in enumerator {
                guard url.lastPathComponent == providerThreadId + ".jsonl" else { continue }
                pathIndex.setPath(url, forProviderThreadId: providerThreadId)
                return url
            }
        }
        return nil
    }

    private func projectsRoots(environment: [String: String]) -> [URL] {
        var roots: [URL] = []
        if let configDir = environment["CLAUDE_CONFIG_DIR"], !configDir.isEmpty {
            roots.append(URL(fileURLWithPath: configDir).appendingPathComponent("projects", isDirectory: true))
        }
        if let home = environment["HOME"], !home.isEmpty {
            roots.append(URL(fileURLWithPath: home).appendingPathComponent(".claude/projects", isDirectory: true))
        }
        roots.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true))
        var seen = Set<String>()
        return roots.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private func readTranscript(file: URL, providerThreadId: String) -> [AssistantEvent] {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        var events: [AssistantEvent] = [.threadStarted(threadId: providerThreadId, providerThreadId: providerThreadId)]
        var emittedMessageIds = Set<String>()

        for line in content.split(whereSeparator: \.isNewline).map(String.init) {
            guard let object = Self.jsonObject(from: line),
                  (object["type"] as? String) == "assistant",
                  let message = object["message"] as? [String: Any] else {
                continue
            }
            let messageId = Self.string(object["uuid"]) ?? Self.string(message["id"]) ?? Self.string(object["requestId"]) ?? UUID().uuidString
            guard emittedMessageIds.insert(messageId).inserted else { continue }

            let turnId = Self.string(message["id"]) ?? messageId
            let timestampMs = Self.timestampMs(object["timestamp"] as? String) ?? Int64(Date().timeIntervalSince1970 * 1000)
            let blocks = message["content"] as? [[String: Any]] ?? []
            let mapped = Self.events(for: blocks, turnId: turnId, timestampMs: timestampMs)
            guard !mapped.events.isEmpty else { continue }
            events.append(.turnStarted(turnId: turnId))
            events.append(contentsOf: mapped.events)
            events.append(.turnCompleted(turnId: turnId, finalMessage: mapped.finalMessage))
        }

        guard events.count > maxEvents else { return events }
        return Array(events.suffix(maxEvents))
    }

    private static func events(for blocks: [[String: Any]], turnId: String, timestampMs: Int64) -> (events: [AssistantEvent], finalMessage: String?) {
        var events: [AssistantEvent] = []
        var assistantTexts: [String] = []
        for (index, block) in blocks.enumerated() {
            let type = string(block["type"]) ?? "text"
            let itemId = string(block["id"]) ?? "\(turnId)-\(index)"
            switch type {
            case "text":
                let text = string(block["text"]) ?? ""
                guard !text.isEmpty else { continue }
                assistantTexts.append(text)
                events.append(.itemStarted(item: AssistantItem(id: itemId, turnId: turnId, type: .assistantMessage, state: .streaming, body: "", startedAtMs: timestampMs)))
                events.append(.itemDelta(itemId: itemId, bodyAppend: text, outputAppend: nil, summary: nil))
                events.append(.itemCompleted(itemId: itemId, finalState: .completed))
            case "thinking":
                let text = string(block["thinking"]) ?? ""
                guard !text.isEmpty else { continue }
                events.append(.itemStarted(item: AssistantItem(id: itemId, turnId: turnId, type: .reasoning, state: .streaming, body: "", startedAtMs: timestampMs)))
                events.append(.itemDelta(itemId: itemId, bodyAppend: text, outputAppend: nil, summary: nil))
                events.append(.itemCompleted(itemId: itemId, finalState: .completed))
            case "tool_use":
                let name = string(block["name"])
                let input = jsonString(block["input"])
                events.append(.itemStarted(item: AssistantItem(id: itemId, turnId: turnId, type: .tool, state: .streaming, summary: name, body: input ?? "", startedAtMs: timestampMs)))
                events.append(.itemCompleted(itemId: itemId, finalState: .completed))
            case "tool_result":
                let output = string(block["content"]) ?? jsonString(block["content"]) ?? ""
                events.append(.itemStarted(item: AssistantItem(id: itemId, turnId: turnId, type: .tool, state: .completed, summary: "result", output: output, startedAtMs: timestampMs, finishedAtMs: timestampMs)))
                events.append(.itemCompleted(itemId: itemId, finalState: .completed))
            default:
                continue
            }
        }
        return (events, assistantTexts.joined(separator: "\n").nilIfEmpty)
    }

    private static func jsonObject(from line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func jsonString(_ value: Any?) -> String? {
        guard let value,
              JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func string(_ value: Any?) -> String? {
        if let string = value as? String, !string.isEmpty { return string }
        return nil
    }

    private static func timestampMs(_ value: String?) -> Int64? {
        guard let value else {
            return nil
        }
        let date = ISO8601DateFormatter.internetDateTimeWithFraction.date(from: value)
            ?? ISO8601DateFormatter.internetDateTime.date(from: value)
        guard let date else { return nil }
        return Int64(date.timeIntervalSince1970 * 1000)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension ISO8601DateFormatter {
    static let internetDateTimeWithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let internetDateTime: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
