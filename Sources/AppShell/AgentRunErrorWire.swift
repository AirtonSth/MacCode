import CoreModel
import Foundation
import SocketServer
import Surfaces

/// Error fields of the failed-run mirror events (host capability
/// `agent.run_recovery_action_v1`). `message` is display text (machine markers
/// removed); `recovery_action` is `sign_in` | `retry` | `start_fresh` |
/// `new_session`, or null when no action is safe. Classification runs on the
/// raw message.
///
/// - `agent.run.error`: `message`, `recoverable`, `recovery_action` (always).
/// - `agent.run.failed`: `recovery_action` always (null for cancelled or
///   interrupted runs); `message` only when the run stored one. When the run
///   already published `agent.run.error`, that event's action wins and is
///   repeated here, as the Mac row keeps the stream error's action.
/// - `agent.thread.read`: every replayed `{"error": {…}}` row carries the same
///   `message` and `recovery_action` as the live `agent.run.error`.
enum AgentRunErrorWire {
    static func fields(message: String, recoverable: Bool) -> [String: JSONValue] {
        [
            "message": .string(AgentErrorRecoveryAction.displayText(message)),
            "recovery_action": recoveryAction(message: message, recoverable: recoverable)
        ]
    }

    static func recoveryAction(message: String, recoverable: Bool) -> JSONValue {
        AgentErrorRecoveryAction
            .pairedWireValue(message: message, recoverable: recoverable)
            .map(JSONValue.string) ?? .null
    }

    /// `agent.run.error` payload fields for a stream `.error`.
    static func errorEventFields(message: String, recoverable: Bool) -> [String: JSONValue] {
        var object = fields(message: message, recoverable: recoverable)
        object["recoverable"] = .bool(recoverable)
        return object
    }

    /// `agent.run.failed` payload fields. `streamErrorAction` is the action the
    /// run's last `agent.run.error` carried (it wins); otherwise the stored
    /// message is classified as the Mac finish path does (not recoverable).
    static func failedEventFields(
        status: AgentRunStatus,
        storedMessage: String?,
        streamErrorAction: JSONValue?
    ) -> [String: JSONValue] {
        guard status == .failed else { return ["recovery_action": .null] }
        var object: [String: JSONValue] = [:]
        if let storedMessage, !storedMessage.isEmpty {
            object = fields(message: storedMessage, recoverable: false)
        }
        object["recovery_action"] = streamErrorAction ?? object["recovery_action"] ?? .null
        return object
    }
}

/// The last `agent.run.error` action per run, taken when the run finishes so
/// `agent.run.failed` repeats it. Bounded: a run that never finishes cannot
/// grow it without limit.
final class AgentRunErrorActionLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var actions: [AgentRunID: JSONValue] = [:]
    private var order: [AgentRunID] = []
    private let capacity: Int

    init(capacity: Int = 256) {
        self.capacity = capacity
    }

    func record(runId: AgentRunID, action: JSONValue) {
        lock.lock()
        defer { lock.unlock() }
        if actions.updateValue(action, forKey: runId) == nil {
            order.append(runId)
            if order.count > capacity {
                actions[order.removeFirst()] = nil
            }
        }
    }

    func take(runId: AgentRunID) -> JSONValue? {
        lock.lock()
        defer { lock.unlock() }
        guard let action = actions.removeValue(forKey: runId) else { return nil }
        order.removeAll { $0 == runId }
        return action
    }
}

extension AppCommandRouter {
    public func replayedRunErrorFields(message: String, recoverable: Bool) -> [String: JSONValue] {
        AgentRunErrorWire.fields(message: message, recoverable: recoverable)
    }
}
