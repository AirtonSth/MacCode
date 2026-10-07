import CoreModel
import Foundation
import SocketServer
import Surfaces

extension AgentThreadChromeWrite {
    /// Partial `agent.thread.updated`: only the columns the write changed, so
    /// mirrors keep every other field. `updated_at` is the value the row now
    /// holds, which stops iOS from stamping its own "now" on the row.
    var eventPayload: JSONValue {
        var payload: [String: JSONValue] = [
            "thread_id": .string(threadID.value.uuidString),
            // Same formatter (and whole-second form) `AgentThreadRepository`
            // stores; built per event because publishers run on any thread.
            "updated_at": .string(ISO8601DateFormatter().string(from: updatedAt)),
        ]
        if let status {
            payload["status"] = .string(status.rawValue)
        }
        if let hasUnread {
            payload["has_unread"] = .bool(hasUnread)
            payload["hasUnread"] = .bool(hasUnread)
        }
        if let providerThreadID {
            payload["provider_thread_id"] = .string(providerThreadID)
        }
        return .object(payload)
    }

    /// Call only after the write committed.
    func publish(on bus: EventBus = .shared) {
        bus.publish(kind: .agentThreadUpdated, payload: eventPayload)
    }
}
