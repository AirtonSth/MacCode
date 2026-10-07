import SocketServer
import Surfaces

/// Error fields of the failed-run mirror events (`agent.run.error`,
/// `agent.run.failed`). `message` is display text (machine markers removed);
/// `recovery_action` is `sign_in` | `retry` | `start_fresh` | `new_session`,
/// or null when no action is safe. Classification runs on the raw message.
enum AgentRunErrorWire {
    static func fields(message: String, recoverable: Bool) -> [String: JSONValue] {
        [
            "message": .string(AgentErrorRecoveryAction.displayText(message)),
            "recovery_action": AgentErrorRecoveryAction
                .pairedWireValue(message: message, recoverable: recoverable)
                .map(JSONValue.string) ?? .null
        ]
    }
}
