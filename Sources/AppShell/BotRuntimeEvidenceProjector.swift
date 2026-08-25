import Foundation
import CoreModel
import SocketServer

/// Projects Agent runtime events only after a completed Bot send receipt binds
/// one authenticated host/Bot/conversation/request/run/thread tuple.
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

    private let eventBus: EventBus
    private let onTerminal: (TerminalEvidence) -> Void
    private let lock = NSLock()
    private var bindingsByRunID: [String: Binding] = [:]
    private var subscriptionID: UUID?

    init(
        eventBus: EventBus = .shared,
        onTerminal: @escaping (TerminalEvidence) -> Void = { _ in }
    ) {
        self.eventBus = eventBus
        self.onTerminal = onTerminal
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
            runID: runID,
            threadID: threadID
        )
        lock.lock()
        bindingsByRunID[runID] = binding
        lock.unlock()
        return true
    }

    private func receive(_ event: EventBus.Event) {
        let projectedKind: String
        switch event.kind {
        case "agent.item.delta", "agent.item.progress":
            projectedKind = "bot.run.stream"
        case "agent.run.completed":
            projectedKind = "bot.run.completed"
        case "agent.run.failed":
            projectedKind = "bot.run.failed"
        default:
            return
        }
        guard let source = event.payload.objectValue,
              let runID = nonempty(source["run_id"]?.stringValue),
              let threadID = nonempty(source["thread_id"]?.stringValue) else { return }
        lock.lock()
        guard let binding = bindingsByRunID[runID], binding.threadID == threadID else {
            lock.unlock()
            return
        }
        if projectedKind == "bot.run.completed" || projectedKind == "bot.run.failed" {
            bindingsByRunID.removeValue(forKey: runID)
        }
        lock.unlock()

        eventBus.publish(kind: projectedKind, payload: .object([
            "host_id": .string(binding.hostID),
            "bot_id": .string(binding.botID),
            "conversation_id": binding.conversationID.map(JSONValue.string) ?? .null,
            "request_id": .string(binding.requestID),
            "client_request_id": .string(binding.requestID),
            "run_id": .string(binding.runID),
        ]))
        if projectedKind == "bot.run.completed" || projectedKind == "bot.run.failed" {
            onTerminal(TerminalEvidence(
                botID: binding.botID,
                runID: binding.runID,
                failed: projectedKind == "bot.run.failed"
            ))
        }
    }

    private func nonempty(_ value: String?) -> String? {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }
}
