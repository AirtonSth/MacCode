import Foundation
import CoreModel

/// Parser for Anthropic Claude CLI streaming output.
/// Maps stream events into the same normalized AssistantEvent model.
/// Supported events:
/// - system { subtype: "init", session_id }
/// - message_start { message: { id } }
/// - content_block_start { index, content_block: { type, id?, name? } }
/// - content_block_delta { index, delta: { type: "text_delta" | "thinking_delta" | "input_json_delta", text/thinking/partial_json } }
/// - content_block_stop { index }
/// - message_delta { delta }
/// - message_stop {}
/// - result { type: "result", subtype?, error? }
public final class ClaudeParser {
    public init() {}

    private var sessionId: String?
    private var threadEmitted = false
    private var currentTurnId: String?
    private var indexToItemId: [Int: String] = [:]
    private var indexToType: [Int: AssistantItemType] = [:]
    private var assembledAssistantBody: String = ""

    public func parseLine(_ line: String) -> [AssistantEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let data = trimmed.data(using: .utf8) else { return [] }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        guard let type = obj["type"] as? String else { return [] }
        let now = Int64(Date().timeIntervalSince1970 * 1000)

        var out: [AssistantEvent] = []

        if type == "system", (obj["subtype"] as? String) == "init" {
            if let sid = obj["session_id"] as? String {
                sessionId = sid
                if !threadEmitted {
                    threadEmitted = true
                    out.append(.threadStarted(threadId: sid, providerThreadId: sid))
                }
            }
            return out
        }

        if !threadEmitted {
            threadEmitted = true
            out.append(.threadStarted(threadId: sessionId ?? UUID().uuidString, providerThreadId: sessionId))
        }

        switch type {
        case "message_start":
            if currentTurnId == nil {
                let msg = obj["message"] as? [String: Any]
                let id = (msg?["id"] as? String) ?? UUID().uuidString
                currentTurnId = id
                out.append(.turnStarted(turnId: id))
            }
        case "content_block_start":
            let index = obj["index"] as? Int ?? 0
            let block = obj["content_block"] as? [String: Any] ?? [:]
            let bt = (block["type"] as? String) ?? "text"
            let itemType: AssistantItemType
            switch bt {
            case "thinking": itemType = .reasoning
            case "tool_use": itemType = .tool
            default: itemType = .assistantMessage
            }
            let itemId = (block["id"] as? String) ?? UUID().uuidString
            indexToItemId[index] = itemId
            indexToType[index] = itemType
            let turnId = currentTurnId ?? ""
            let summary = itemType == .tool ? (block["name"] as? String) : nil
            out.append(.itemStarted(item: AssistantItem(id: itemId, turnId: turnId, type: itemType, state: .streaming, summary: summary, body: "", startedAtMs: now)))
        case "content_block_delta":
            let index = obj["index"] as? Int ?? 0
            guard let itemId = indexToItemId[index] else { break }
            let delta = obj["delta"] as? [String: Any] ?? [:]
            let dtype = delta["type"] as? String
            switch dtype {
            case "text_delta":
                let text = delta["text"] as? String
                if let text { assembledAssistantBody += text }
                out.append(.itemDelta(itemId: itemId, bodyAppend: text, outputAppend: nil, summary: nil))
            case "thinking_delta":
                let text = delta["thinking"] as? String
                out.append(.itemDelta(itemId: itemId, bodyAppend: text, outputAppend: nil, summary: nil))
            case "input_json_delta":
                let text = delta["partial_json"] as? String
                out.append(.itemDelta(itemId: itemId, bodyAppend: nil, outputAppend: text, summary: nil))
            default:
                break
            }
        case "content_block_stop":
            let index = obj["index"] as? Int ?? 0
            if let itemId = indexToItemId[index] {
                out.append(.itemCompleted(itemId: itemId, finalState: .completed))
                indexToItemId.removeValue(forKey: index)
                indexToType.removeValue(forKey: index)
            }
        case "message_delta", "message_stop":
            break
        case "result":
            if let err = obj["error"] as? [String: Any], let msg = err["message"] as? String {
                out.append(.error(message: msg, recoverable: false))
            }
            if let tid = currentTurnId {
                out.append(.turnCompleted(turnId: tid, finalMessage: assembledAssistantBody.isEmpty ? nil : assembledAssistantBody))
                currentTurnId = nil
            }
        case "error":
            let msg = (obj["error"] as? [String: Any])?["message"] as? String ?? "claude error"
            out.append(.error(message: msg, recoverable: false))
        default:
            break
        }
        return out
    }

    public func finalize() -> [AssistantEvent] {
        guard let tid = currentTurnId else { return [] }
        currentTurnId = nil
        return [.turnCompleted(turnId: tid, finalMessage: assembledAssistantBody.isEmpty ? nil : assembledAssistantBody)]
    }
}
