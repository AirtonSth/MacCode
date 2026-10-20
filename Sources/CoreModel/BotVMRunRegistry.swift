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
    /// Every live claim of the thread holding each bot, oldest first. Two starts
    /// on one thread (router + tab, iOS + Mac) both claim; the VM is freed only
    /// when the last of them is released, so the unstarted one's release cannot
    /// free the VM under the run that did start.
    private var claims: [BotID: [Entry]] = [:]

    private struct Waiter {
        let botID: BotID
        let threadID: AgentThreadID
    }
    private var waiting: [BotID: [Waiter]] = [:]
    public init() {}

    /// Claims the bot for `entry.threadID`; returns the other thread's entry when it holds the bot.
    public func tryBegin(botID: BotID, entry: Entry, resourceID: BotID? = nil) -> Entry? {
        let botID = resourceID ?? botID
        return lock.withLock {
            guard let held = claims[botID], let holder = held.first else {
                claims[botID] = [entry]
                return nil
            }
            if holder.threadID != entry.threadID { return holder }
            if let index = held.firstIndex(where: { $0.runID == entry.runID }) {
                claims[botID]?[index] = entry
            } else {
                claims[botID]?.append(entry)
            }
            return nil
        }
    }
    public func addWaiting(botID: BotID, threadID: AgentThreadID, resourceID: BotID? = nil) {
        lock.withLock {
            let key = resourceID ?? botID
            if waiting[key]?.contains(where: { $0.threadID == threadID }) != true {
                waiting[key, default: []].append(Waiter(botID: botID, threadID: threadID))
            }
        }
    }
    public func waitingThreads(botID: BotID, resourceID: BotID? = nil) -> [AgentThreadID] {
        lock.withLock { waiting[resourceID ?? botID]?.map(\.threadID) ?? [] }
    }
    /// The bot `threadID` waits for and the other thread's run holding it; nil
    /// when the thread is not waiting or the bot is free.
    public func waitingHolder(threadID: AgentThreadID) -> (botID: BotID, holder: Entry)? {
        lock.withLock {
            for (key, queue) in waiting {
                if let waiter = queue.first(where: { $0.threadID == threadID }),
                   let holder = claims[key]?.first, holder.threadID != threadID { return (waiter.botID, holder) }
            }
            return nil
        }
    }
    /// Pops the first thread queued for a free bot (nil while a run holds it):
    /// a hand-off whose thread did not take the VM passes it on.
    public func popWaitingIfFree(botID: BotID, resourceID: BotID? = nil) -> AgentThreadID? {
        let botID = resourceID ?? botID
        return lock.withLock {
            guard claims[botID] == nil, var queue = waiting[botID], !queue.isEmpty else { return nil }
            let next = queue.removeFirst()
            waiting[botID] = queue.isEmpty ? nil : queue
            return next.threadID
        }
    }
    /// Frees the bot held by `runID` and pops the first thread queued for it.
    /// nil while another claim of the same thread still holds the bot.
    public func releaseAndNextWaiting(runID: AgentRunID) -> AgentThreadID? {
        releaseAndNextWaiter(runID: runID)?.threadID
    }

    /// `releaseAndNextWaiting` with the bot the next thread waited for.
    public func releaseAndNextWaiter(runID: AgentRunID) -> (botID: BotID, threadID: AgentThreadID)? {
        lock.withLock {
            guard let botID = claims.first(where: { $0.value.contains { $0.runID == runID } })?.key,
                  removeClaim(botID: botID, runID: runID) else { return nil }
            guard var queue = waiting[botID], !queue.isEmpty else { return nil }
            let next = queue.removeFirst()
            waiting[botID] = queue.isEmpty ? nil : queue
            return (next.botID, next.threadID)
        }
    }

    /// Removes `runID`'s claim; true when that freed the bot. Caller holds `lock`.
    private func removeClaim(botID: BotID, runID: AgentRunID) -> Bool {
        guard var held = claims[botID], let index = held.firstIndex(where: { $0.runID == runID }) else { return false }
        held.remove(at: index)
        claims[botID] = held.isEmpty ? nil : held
        return held.isEmpty
    }

    public func begin(botID: BotID, entry: Entry) {
        lock.withLock { claims[botID] = [entry] }
    }

    /// Clears only when `runID` still owns the bot, so a stale finish cannot drop a newer run.
    public func end(botID: BotID, runID: AgentRunID) {
        lock.withLock { _ = removeClaim(botID: botID, runID: runID) }
    }

    public func endRun(runID: AgentRunID) {
        lock.withLock {
            for botID in Array(claims.keys) { _ = removeClaim(botID: botID, runID: runID) }
        }
    }

    public func active(botID: BotID, resourceID: BotID? = nil) -> Entry? {
        lock.withLock { claims[resourceID ?? botID]?.first }
    }

    public func busyMessage(botID: BotID, threadID: AgentThreadID, resourceID: BotID? = nil) -> String? {
        guard let entry = active(botID: botID, resourceID: resourceID), entry.threadID != threadID else { return nil }
        return "The VM is busy in \(entry.title)"
    }
}
