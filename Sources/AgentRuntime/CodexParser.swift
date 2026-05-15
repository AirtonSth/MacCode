import Foundation
import CoreModel

/// Parser for the Codex CLI streaming JSONL output.
/// Codex emits JSON objects per line with a top-level "type" field.
/// Supported types: thread.started, turn.started, item.started, item.delta, item.completed,
/// item.failed, turn.completed, error.
public struct CodexParser {
    public init() {}

    public func parseLine(_ line: String) -> [AssistantEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let data = trimmed.data(using: .utf8) else { return [] }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        guard let type = obj["type"] as? String else { return [] }
        let now = Int64(Date().timeIntervalSince1970 * 1000)

        switch type {
        case "thread.started":
            let threadId = obj["thread_id"] as? String ?? obj["id"] as? String ?? UUID().uuidString
            let providerThreadId = obj["provider_thread_id"] as? String ?? obj["thread_id"] as? String
            return [.threadStarted(threadId: threadId, providerThreadId: providerThreadId)]
        case "turn.started":
            let tid = obj["turn_id"] as? String ?? obj["id"] as? String ?? UUID().uuidString
            return [.turnStarted(turnId: tid)]
        case "item.started":
            let id = obj["item_id"] as? String ?? obj["id"] as? String ?? UUID().uuidString
            let turnId = obj["turn_id"] as? String ?? ""
            let kind = (obj["item_type"] as? String) ?? (obj["kind"] as? String) ?? "assistantMessage"
            let it = AssistantItem(
                id: id, turnId: turnId,
                type: mapItemType(kind),
                state: .streaming,
                summary: obj["summary"] as? String,
                body: obj["body"] as? String ?? "",
                output: obj["output"] as? String,
                startedAtMs: now
            )
            return [.itemStarted(item: it)]
        case "item.delta":
            let id = obj["item_id"] as? String ?? obj["id"] as? String ?? ""
            let body = obj["body_delta"] as? String ?? obj["delta"] as? String
            let output = obj["output_delta"] as? String
            let summary = obj["summary"] as? String
            return [.itemDelta(itemId: id, bodyAppend: body, outputAppend: output, summary: summary)]
        case "item.completed":
            let id = obj["item_id"] as? String ?? obj["id"] as? String ?? ""
            return [.itemCompleted(itemId: id, finalState: .completed)]
        case "item.failed":
            let id = obj["item_id"] as? String ?? obj["id"] as? String ?? ""
            return [.itemCompleted(itemId: id, finalState: .failed)]
        case "turn.completed":
            let tid = obj["turn_id"] as? String ?? obj["id"] as? String ?? ""
            let final = obj["final_message"] as? String ?? obj["message"] as? String
            return [.turnCompleted(turnId: tid, finalMessage: final)]
        case "error":
            let msg = obj["message"] as? String ?? "unknown error"
            let recoverable = obj["recoverable"] as? Bool ?? false
            return [.error(message: msg, recoverable: recoverable)]
        default:
            return []
        }
    }

    private func mapItemType(_ s: String) -> AssistantItemType {
        switch s.lowercased() {
        case "reasoning": return .reasoning
        case "plan": return .plan
        case "tool", "tool_call", "command": return .tool
        case "assistantmessage", "assistant", "message", "text": return .assistantMessage
        default: return .assistantMessage
        }
    }
}
