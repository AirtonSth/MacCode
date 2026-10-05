import Foundation

/// Tracks which thread currently owns each bot's VM so runs on one VM never overlap.
public final class BotVMRunRegistry: @unchecked Sendable {
    public static let shared = BotVMRunRegistry()

    public struct Entry: Equatable, Sendable {
        public let threadID: AgentThreadID
        public let runID: AgentRunID
        public let title: String
        public let workspace: String

        public init(threadID: AgentThreadID, runID: AgentRunID, title: String, workspace: String) {
            self.threadID = threadID
            self.runID = runID
            self.title = title
            self.workspace = workspace
        }
    }

    private let lock = NSLock()
    private var entries: [BotID: Entry] = [:]

    public init() {}

    public func begin(botID: BotID, entry: Entry) {
        lock.withLock { entries[botID] = entry }
    }

    /// Clears only when `runID` still owns the bot, so a stale finish cannot drop a newer run.
    public func end(botID: BotID, runID: AgentRunID) {
        lock.withLock {
            if entries[botID]?.runID == runID { entries[botID] = nil }
        }
    }

    public func endRun(runID: AgentRunID) {
        lock.withLock {
            for (botID, entry) in entries where entry.runID == runID { entries[botID] = nil }
        }
    }

    public func active(botID: BotID) -> Entry? {
        lock.withLock { entries[botID] }
    }

    public func busyMessage(botID: BotID, threadID: AgentThreadID) -> String? {
        guard let entry = active(botID: botID), entry.threadID != threadID else { return nil }
        return "bot ocupado em \(entry.title)"
    }
}
