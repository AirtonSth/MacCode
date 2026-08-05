import Foundation
import CoreModel

/// Pure in-memory cache: providerThreadId -> transcript file URL.
/// Not thread-safe by itself. `ClaudeTranscriptStore` serializes get/set with
/// `pathIndexLock` so concurrent `readSession` cannot race Dictionary mutation.
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
    /// Exclusive access for `pathIndex` only — never hold across FS enumeration.
    private let pathIndexLock = NSLock()

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

    private func cachedTranscriptPath(forProviderThreadId providerThreadId: String) -> URL? {
        pathIndexLock.lock()
        defer { pathIndexLock.unlock() }
        return pathIndex.path(forProviderThreadId: providerThreadId)
    }

    private func rememberTranscriptPath(_ url: URL, forProviderThreadId providerThreadId: String) {
        pathIndexLock.lock()
        pathIndex.setPath(url, forProviderThreadId: providerThreadId)
        pathIndexLock.unlock()
    }

    private func transcriptFile(providerThreadId: String, environment: [String: String]) -> URL? {
        if let cached = cachedTranscriptPath(forProviderThreadId: providerThreadId) {
            if fileManager.fileExists(atPath: cached.path) {
                return cached
            }
            // Cached path no longer valid — fall through to re-enumerate.
        }
        for projectsRoot in projectsRoots(environment: environment) {
            let direct = projectsRoot.appendingPathComponent(providerThreadId + ".jsonl")
            if fileManager.fileExists(atPath: direct.path) {
                rememberTranscriptPath(direct, forProviderThreadId: providerThreadId)
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
                rememberTranscriptPath(url, forProviderThreadId: providerThreadId)
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

    // MARK: - Bounded tail reader

    /// Returns the last `maxEvents` non-empty lines from `data` without
    /// materialising the entire file as a String.
    /// Exposed as `internal` so tests can reach it without @testable gymnastics.
    static func tailLines(from data: Data, maxEvents: Int) -> [String] {
        guard maxEvents > 0, !data.isEmpty else { return [] }
        // Scan backwards through raw UTF-8 bytes, collecting newline-terminated
        // slices.  Stop once we have maxEvents lines (plus one partial leading
        // line that we may discard).
        let newline = UInt8(ascii: "\n")
        var lines: [String] = []
        var end = data.endIndex

        while end > data.startIndex && lines.count < maxEvents {
            // Find the preceding newline (or the start of the buffer).
            var start = data.index(before: end)
            // Step back past the newline that ended the *previous* line.
            if start > data.startIndex && data[start] == newline {
                start = data.index(before: start)
            }
            while start > data.startIndex && data[data.index(before: start)] != newline {
                start = data.index(before: start)
            }
            let slice = data[start..<end]
            // Trim the trailing newline before decoding.
            let trimmed = slice.last == newline ? slice.dropLast() : slice
            if !trimmed.isEmpty, let s = String(bytes: trimmed, encoding: .utf8), !s.isEmpty {
                lines.append(s)
            }
            end = start
        }

        lines.reverse()
        return lines
    }

    private func readTranscript(file: URL, providerThreadId: String) -> [AssistantEvent] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }

        // Read only the tail portion we need.  Each JSONL line for a full
        // assistant turn is typically a few KB; we over-read by 2x to make
        // sure we collect enough lines even for large events, then trim.
        let chunkSize = maxEvents * 4_096
        let fileSize: Int
        if #available(macOS 10.15.4, *) {
            fileSize = Int((try? handle.seekToEnd()) ?? 0)
        } else {
            handle.seekToEndOfFile()
            fileSize = Int(handle.offsetInFile)
        }
        let readSize = min(fileSize, chunkSize)
        let offset = fileSize - readSize
        let rawData: Data
        if #available(macOS 10.15.4, *) {
            do {
                try handle.seek(toOffset: UInt64(offset))
                rawData = (try handle.read(upToCount: readSize)) ?? Data()
            } catch {
                return []
            }
        } else {
            handle.seek(toFileOffset: UInt64(offset))
            rawData = handle.readData(ofLength: readSize)
        }

        // If we did not start at the file beginning, the first slice may be a
        // partial line; drop it.
        let candidateLines: [String]
        if offset > 0 {
            let allLines = Self.tailLines(from: rawData, maxEvents: maxEvents + 1)
            candidateLines = allLines.count > 1 ? Array(allLines.dropFirst()) : []
        } else {
            candidateLines = Self.tailLines(from: rawData, maxEvents: maxEvents)
        }

        var events: [AssistantEvent] = [.threadStarted(threadId: providerThreadId, providerThreadId: providerThreadId)]
        var emittedMessageIds = Set<String>()
        // One assistant message (same message.id / turnId) spans multiple JSONL
        // lines (text → tool_use → text). Accumulate the turn's assistant text
        // across lines so a later tool-only line's turnCompleted never resets
        // the turn's finalAssistantMessage back to nil in the reducer.
        var finalMessagesByTurn: [String: String] = [:]

        for line in candidateLines {
            guard let object = Self.jsonObject(from: line),
                  let lineType = object["type"] as? String,
                  let message = object["message"] as? [String: Any] else {
                continue
            }
            let messageId = Self.string(object["uuid"]) ?? Self.string(message["id"]) ?? Self.string(object["requestId"]) ?? UUID().uuidString
            guard emittedMessageIds.insert(messageId).inserted else { continue }

            let timestampMs = Self.timestampMs(object["timestamp"] as? String) ?? Int64(Date().timeIntervalSince1970 * 1000)
            let blocks = message["content"] as? [[String: Any]] ?? []

            // Real Claude session JSONL puts tool_result on type=user lines keyed
            // by tool_use_id (string content, often no block id). Accept those
            // lines only for tool_result and pair onto the existing tool item —
            // never start a user turn or render user text/thinking as assistant.
            if lineType == "user" {
                for (index, block) in blocks.enumerated() {
                    guard (Self.string(block["type"]) ?? "") == "tool_result" else { continue }
                    let toolUseId = Self.string(block["tool_use_id"])
                        ?? Self.string(block["id"])
                        ?? "\(messageId)-\(index)"
                    let output = Self.string(block["content"]) ?? Self.jsonString(block["content"]) ?? ""
                    events.append(.itemDelta(itemId: toolUseId, bodyAppend: nil, outputAppend: output, summary: nil))
                    events.append(.itemCompleted(itemId: toolUseId, finalState: .completed))
                }
                continue
            }

            guard lineType == "assistant" else { continue }

            let turnId = Self.string(message["id"]) ?? messageId
            let mapped = Self.events(for: blocks, turnId: turnId, lineId: messageId, timestampMs: timestampMs)
            guard !mapped.events.isEmpty else { continue }
            if let final = mapped.finalMessage {
                finalMessagesByTurn[turnId] = finalMessagesByTurn[turnId].map { $0 + "\n" + final } ?? final
            }
            events.append(.turnStarted(turnId: turnId))
            events.append(contentsOf: mapped.events)
            events.append(.turnCompleted(turnId: turnId, finalMessage: finalMessagesByTurn[turnId]))
        }

        guard events.count > maxEvents else { return events }
        return Array(events.suffix(maxEvents))
    }

    private static func events(for blocks: [[String: Any]], turnId: String, lineId: String, timestampMs: Int64) -> (events: [AssistantEvent], finalMessage: String?) {
        var events: [AssistantEvent] = []
        var assistantTexts: [String] = []
        for (index, block) in blocks.enumerated() {
            let type = string(block["type"]) ?? "text"
            // Fallback id keyed on the LINE (uuid), not the turn: multiple
            // lines of one message each carry a block at index 0, and a
            // turnId-based id collided across lines — the reducer merged the
            // duplicate itemStarted and appended the second text block onto
            // the first with no separator (run-on glued prose on resume).
            let itemId = string(block["id"]) ?? "\(lineId)-\(index)"
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
                // Prefer tool_use_id so a result block merges onto the tool_use item.
                let toolUseId = string(block["tool_use_id"]) ?? itemId
                let output = string(block["content"]) ?? jsonString(block["content"]) ?? ""
                events.append(.itemStarted(item: AssistantItem(id: toolUseId, turnId: turnId, type: .tool, state: .completed, summary: "result", output: output, startedAtMs: timestampMs, finishedAtMs: timestampMs)))
                events.append(.itemCompleted(itemId: toolUseId, finalState: .completed))
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
