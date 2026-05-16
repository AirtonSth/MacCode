import Foundation
import CoreModel

/// Parser for `codex exec --json` output. Real success schema:
///   thread.started{thread_id} · turn.started ·
///   item.completed{item:{id,type:"agent_message"|"reasoning"|
///   "command_execution"…, text}} · turn.completed
/// Legacy synthetic events (item.started/item.delta/turn.completed
/// {final_message}) are still handled for older builds + tests.
public final class CodexParser {
    public init() {}

    private var currentTurnId: String?
    private var assembled = ""

    private func ensureTurn(_ out: inout [AssistantEvent]) {
        if currentTurnId == nil {
            let t = UUID().uuidString
            currentTurnId = t
            out.append(.turnStarted(turnId: t))
        }
    }

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
            currentTurnId = tid
            assembled = ""
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
            if let b = body { assembled += b }
            return [.itemDelta(itemId: id, bodyAppend: body, outputAppend: output, summary: summary)]
        case "item.completed":
            // Real `codex exec --json`: the payload is a nested `item`
            // {id,type,text}. agent_message carries the assistant reply.
            if let item = obj["item"] as? [String: Any] {
                let iid = item["id"] as? String ?? UUID().uuidString
                let kind = (item["type"] as? String) ?? "agent_message"
                let text = item["text"] as? String
                    ?? item["output"] as? String
                    ?? item["command"] as? String ?? ""
                let tt = mapItemType(kind)
                var out: [AssistantEvent] = []
                ensureTurn(&out)
                let turnId = currentTurnId ?? ""
                switch tt {
                case .assistantMessage:
                    assembled += (assembled.isEmpty ? "" : "\n") + text
                    out.append(.itemStarted(item: AssistantItem(id: iid, turnId: turnId, type: .assistantMessage, state: .streaming, summary: nil, body: "", startedAtMs: now)))
                    out.append(.itemDelta(itemId: iid, bodyAppend: text, outputAppend: nil, summary: nil))
                    out.append(.itemCompleted(itemId: iid, finalState: .completed))
                case .tool:
                    let summary = item["command"] as? String ?? item["name"] as? String ?? kind
                    out.append(.itemStarted(item: AssistantItem(id: iid, turnId: turnId, type: .tool, state: .completed, summary: summary, body: "", output: text, startedAtMs: now)))
                    out.append(.itemCompleted(itemId: iid, finalState: .completed))
                default: // reasoning / plan
                    out.append(.itemStarted(item: AssistantItem(id: iid, turnId: turnId, type: tt, state: .streaming, summary: nil, body: text, startedAtMs: now)))
                    out.append(.itemCompleted(itemId: iid, finalState: .completed))
                }
                return out
            }
            // Legacy synthetic schema.
            let id = obj["item_id"] as? String ?? obj["id"] as? String ?? ""
            return [.itemCompleted(itemId: id, finalState: .completed)]
        case "item.failed":
            let id = obj["item_id"] as? String ?? obj["id"] as? String ?? ""
            return [.itemCompleted(itemId: id, finalState: .failed)]
        case "turn.completed":
            let tid = obj["turn_id"] as? String ?? obj["id"] as? String ?? currentTurnId ?? ""
            // Real codex turn.completed has no message — use the accumulated
            // agent_message text; fall back to legacy fields.
            let final = (obj["final_message"] as? String ?? obj["message"] as? String)
                ?? (assembled.isEmpty ? nil : assembled)
            currentTurnId = nil
            return [.turnCompleted(turnId: tid, finalMessage: final)]
        case "turn.failed":
            let msg = (obj["error"] as? [String: Any])?["message"] as? String
                ?? obj["message"] as? String ?? "codex turn failed"
            return [.error(message: msg, recoverable: false)]
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
        case "plan", "todo_list", "plan_update": return .plan
        case "tool", "tool_call", "command", "command_execution",
             "file_change", "patch", "mcp_tool_call", "web_search":
            return .tool
        case "agent_message", "assistantmessage", "assistant", "message", "text":
            return .assistantMessage
        default: return .assistantMessage
        }
    }
}
