import Foundation
import CoreModel
import SocketServer
import RemoteCodeTreaty

/// Projects Agent runtime events only after a completed Bot send receipt binds
/// one authenticated host/Bot/conversation/request/run/thread tuple. Matching
/// events retained before that binding are reconciled only for a replayed receipt.
final class BotRuntimeEvidenceProjector: @unchecked Sendable {
    struct TerminalEvidence: Equatable {
        let botID: String
        let runID: String
        let failed: Bool
    }

    private struct Binding: Equatable {
        let hostID: String
        let botID: String
        let conversationID: String?
        let requestID: String
        let runID: String
        let threadID: String
    }

    /// `bot.run.stream` carries ids only: it is liveness evidence, and every
    /// one costs a frame and flushes the delta coalescing window. A bound run
    /// publishes its first one at once and then at most one per interval.
    static let streamTickInterval: TimeInterval = 1

    private let eventBus: EventBus
    private let onTerminal: (TerminalEvidence) -> Void
    private let now: () -> Date
    /// `onTerminal` settles the run with SQLite reads and writes. It runs
    /// here, in the order the terminals were projected, so the EventBus
    /// delivery lane fans `bot.run.completed` out without waiting for it.
    private let terminalQueue = DispatchQueue(
        label: "io.remotecode.bot-runtime-evidence.terminal",
        qos: .userInitiated
    )
    private let lock = NSLock()
    private var bindingsByRunID: [String: Binding] = [:]
    private var lastProjectedSequenceByRunID: [String: Int64] = [:]
    private var lastStreamTickByRunID: [String: Date] = [:]
    private var replayedEventCount = 0
    private var subscriptionID: UUID?

    /// Test seam: events that registration replay subscriptions passed to `receive`.
    var replayedEventCountForTesting: Int {
        lock.lock(); defer { lock.unlock() }
        return replayedEventCount
    }

    /// Test seam: returns once every terminal projected so far has run `onTerminal`.
    func flushTerminalsForTesting() {
        terminalQueue.sync {}
    }

    init(
        eventBus: EventBus = .shared,
        onTerminal: @escaping (TerminalEvidence) -> Void = { _ in },
        now: @escaping () -> Date = { Date() }
    ) {
        self.eventBus = eventBus
        self.onTerminal = onTerminal
        self.now = now
        subscriptionID = eventBus.subscribe(since: eventBus.currentSeq) { [weak self] event in
            self?.receive(event)
        }
    }

    deinit {
        if let subscriptionID { eventBus.unsubscribe(subscriptionID) }
    }

    /// Queued sends intentionally do not register: their run belongs to the
    /// already-live request, not to the newly queued message.
    @discardableResult
    func registerCompletedSend(_ value: JSONValue) -> Bool {
        guard let receipt = value.objectValue,
              receipt["status"]?.stringValue == "completed",
              let hostID = nonempty(receipt["host_id"]?.stringValue),
              let botID = nonempty(receipt["bot_id"]?.stringValue),
              let requestID = nonempty(receipt["request_id"]?.stringValue),
              receipt["client_request_id"]?.stringValue == requestID,
              let readback = receipt["readback"]?.objectValue,
              readback["host_id"]?.stringValue == hostID,
              readback["bot_id"]?.stringValue == botID,
              readback["request_id"]?.stringValue == requestID,
              readback["client_request_id"]?.stringValue == requestID,
              readback["enqueued"]?.boolValue == false,
              let runID = nonempty(readback["run_id"]?.stringValue),
              let run = readback["run"]?.objectValue,
              run["host_id"]?.stringValue == hostID,
              run["bot_id"]?.stringValue == botID,
              run["request_id"]?.stringValue == requestID,
              run["client_request_id"]?.stringValue == requestID,
              run["run_id"]?.stringValue == runID,
              let threadID = nonempty(run["thread_id"]?.stringValue) else {
            return false
        }
        let conversationID = nonempty(readback["conversation_id"]?.stringValue)
        guard nonempty(run["conversation_id"]?.stringValue) == conversationID else { return false }
        let binding = Binding(
            hostID: hostID,
            botID: botID,
            conversationID: conversationID,
            requestID: requestID,
            runID: canonicalRuntimeID(runID),
            threadID: canonicalRuntimeID(threadID)
        )
        lock.lock()
        // A new receipt names a run that has published nothing yet: its
        // provider start is queued behind the MainActor turn that registers
        // it. Only an idempotent replay of a receipt this projector already
        // knows can have retained events left to reconcile.
        let isReplayedReceipt = bindingsByRunID[binding.runID] != nil
            || lastProjectedSequenceByRunID[binding.runID] != nil
        bindingsByRunID[binding.runID] = binding
        lock.unlock()

        if isReplayedReceipt {
            let replaySubscriptionID = eventBus.subscribe(since: 0) { [weak self] event in
                self?.receiveReplayed(event)
            }
            eventBus.unsubscribe(replaySubscriptionID)
        }

        let ring = eventBus.healthCounters()
        lock.lock()
        if ring.retainedCount > 0 {
            lastProjectedSequenceByRunID = lastProjectedSequenceByRunID.filter {
                $0.value >= ring.oldestRetainedSeq
            }
        } else {
            lastProjectedSequenceByRunID.removeAll()
        }
        lock.unlock()
        return true
    }

    private func receiveReplayed(_ event: EventBus.Event) {
        lock.lock()
        replayedEventCount += 1
        lock.unlock()
        receive(event)
    }

    private func receive(_ event: EventBus.Event) {
        let projectedKind: RemoteCodeEventKind
        switch event.kind {
        case "agent.item.delta", "agent.item.progress":
            projectedKind = .botRunStream
        case "agent.run.completed":
            projectedKind = .botRunCompleted
        case "agent.run.failed":
            projectedKind = .botRunFailed
        default:
            return
        }
        guard let source = event.payload.objectValue,
              let rawRunID = nonempty(source["run_id"]?.stringValue),
              let rawThreadID = nonempty(source["thread_id"]?.stringValue) else { return }
        let runID = canonicalRuntimeID(rawRunID)
        let threadID = canonicalRuntimeID(rawThreadID)
        lock.lock()
        guard let binding = bindingsByRunID[runID], binding.threadID == threadID else {
            lock.unlock()
            return
        }
        if lastProjectedSequenceByRunID[runID].map({ $0 >= event.seq }) == true {
            lock.unlock()
            return
        }
        lastProjectedSequenceByRunID[runID] = event.seq
        if projectedKind == .botRunCompleted || projectedKind == .botRunFailed {
            bindingsByRunID.removeValue(forKey: runID)
            lastStreamTickByRunID.removeValue(forKey: runID)
        } else {
            let tickTime = now()
            if let lastTick = lastStreamTickByRunID[runID] {
                let elapsed = tickTime.timeIntervalSince(lastTick)
                // A wall clock stepped backwards (negative) publishes: it
                // must never hold liveness back.
                if elapsed >= 0, elapsed < Self.streamTickInterval {
                    lock.unlock()
                    return
                }
            }
            lastStreamTickByRunID[runID] = tickTime
        }
        lock.unlock()

        var projectedPayload: [String: JSONValue] = [
            "host_id": .string(binding.hostID),
            "bot_id": .string(binding.botID),
            "conversation_id": binding.conversationID.map(JSONValue.string) ?? .null,
            "request_id": .string(binding.requestID),
            "client_request_id": .string(binding.requestID),
            "run_id": .string(binding.runID),
        ]
        if projectedKind == .botRunFailed,
           let message = nonempty(
               source["message"]?.stringValue
                   ?? source["error_message"]?.stringValue
                   ?? source["error"]?.stringValue
           ) {
            projectedPayload["message"] = .string(message)
        }
        eventBus.publish(kind: projectedKind, payload: .object(projectedPayload))
        if projectedKind == .botRunCompleted || projectedKind == .botRunFailed {
            let terminal = TerminalEvidence(
                botID: binding.botID,
                runID: binding.runID,
                failed: projectedKind == .botRunFailed
            )
            terminalQueue.async { [self] in onTerminal(terminal) }
        }
    }

    private func nonempty(_ value: String?) -> String? {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private func canonicalRuntimeID(_ value: String) -> String {
        UUID(uuidString: value)?.uuidString.lowercased() ?? value
    }
}
