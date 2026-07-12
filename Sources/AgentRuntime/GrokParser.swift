import Foundation
import CoreModel

/// Parser for official Grok Build CLI headless output
/// (`grok -p … --output-format streaming-json`).
///
/// Event shape (observed from grok 0.2.x):
/// - `{"type":"thought","data":"…"}` — reasoning token stream
/// - `{"type":"text","data":"…"}` — assistant text stream
/// - `{"type":"end","stopReason":"…","sessionId":"…","requestId":"…"}`
///
/// Maps into the shared AssistantEvent model used by Agent App.
public final class GrokParser {
    public init() {}

    private var sessionId: String?
    private var threadEmitted = false
    private var currentTurnId: String?
    private var turnEmitted = false
    private var reasoningItemId: String?
    private var assistantItemId: String?
    private var assembledAssistantBody = ""
    private var turnFinished = false

    public var capturedSessionId: String? { sessionId }

    public func parseLine(_ line: String) -> [AssistantEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let data = trimmed.data(using: .utf8) else { return [] }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        guard let type = obj["type"] as? String else { return [] }
        let now = Int64(Date().timeIntervalSince1970 * 1000)

        if let sid = (obj["sessionId"] as? String) ?? (obj["session_id"] as? String), !sid.isEmpty {
            sessionId = sid
        }

        var out: [AssistantEvent] = []
        ensureThread(&out)

        switch type {
        case "thought":
            ensureTurn(&out)
            let chunk = textChunk(from: obj)
            guard !chunk.isEmpty else { return out }
            let itemId = openReasoningItem(&out, now: now)
            out.append(.itemDelta(itemId: itemId, bodyAppend: chunk, outputAppend: nil, summary: nil))

        case "text":
            ensureTurn(&out)
            let chunk = textChunk(from: obj)
            guard !chunk.isEmpty else { return out }
            let itemId = openAssistantItem(&out, now: now)
            assembledAssistantBody += chunk
            out.append(.itemDelta(itemId: itemId, bodyAppend: chunk, outputAppend: nil, summary: nil))

        case "end":
            ensureTurn(&out)
            // Prefer the authoritative session id on end so resume works.
            if let sid = (obj["sessionId"] as? String) ?? (obj["session_id"] as? String), !sid.isEmpty {
                sessionId = sid
                // Re-emit so TimelineAggregator.providerThreadId is the real session.
                out.append(.threadStarted(threadId: sid, providerThreadId: sid))
            }
            closeOpenItems(&out)
            if let turnId = currentTurnId, !turnFinished {
                turnFinished = true
                let final = assembledAssistantBody.isEmpty ? nil : assembledAssistantBody
                out.append(.turnCompleted(turnId: turnId, finalMessage: final))
            }

        case "error":
            ensureTurn(&out)
            let message = (obj["message"] as? String)
                ?? (obj["data"] as? String)
                ?? (obj["error"] as? String)
                ?? "Grok CLI error"
            let itemId = UUID().uuidString
            let turnId = currentTurnId ?? ""
            out.append(.itemStarted(item: AssistantItem(
                id: itemId, turnId: turnId, type: .error, state: .failed,
                summary: "error", body: message, startedAtMs: now
            )))
            out.append(.itemCompleted(itemId: itemId, finalState: .failed))

        case "tool_call", "tool_use", "tool":
            ensureTurn(&out)
            let name = (obj["name"] as? String)
                ?? (obj["tool"] as? String)
                ?? (obj["toolName"] as? String)
                ?? "tool"
            let itemId = (obj["id"] as? String) ?? (obj["toolCallId"] as? String) ?? UUID().uuidString
            let turnId = currentTurnId ?? ""
            let input = encodeJSON(obj["input"] ?? obj["arguments"] ?? obj["data"] ?? [:])
            out.append(.itemStarted(item: AssistantItem(
                id: itemId, turnId: turnId, type: .tool, state: .streaming,
                summary: name, body: input ?? "", startedAtMs: now
            )))

        case "tool_result", "tool_response":
            ensureTurn(&out)
            let itemId = (obj["id"] as? String)
                ?? (obj["toolCallId"] as? String)
                ?? (obj["tool_call_id"] as? String)
                ?? UUID().uuidString
            let payload = (obj["content"] as? String)
                ?? (obj["output"] as? String)
                ?? (obj["data"] as? String)
                ?? encodeJSON(obj["result"] as Any? ?? obj["content"] as Any? ?? "")
                ?? ""
            out.append(.itemDelta(itemId: itemId, bodyAppend: nil, outputAppend: payload, summary: nil))
            out.append(.itemCompleted(itemId: itemId, finalState: .completed))

        default:
            break
        }
        return out
    }

    public func finalize() -> [AssistantEvent] {
        var out: [AssistantEvent] = []
        closeOpenItems(&out)
        if let turnId = currentTurnId, !turnFinished {
            turnFinished = true
            let final = assembledAssistantBody.isEmpty ? nil : assembledAssistantBody
            out.append(.turnCompleted(turnId: turnId, finalMessage: final))
        }
        return out
    }

    // MARK: - Internals

    private func textChunk(from obj: [String: Any]) -> String {
        if let s = obj["data"] as? String { return s }
        if let s = obj["text"] as? String { return s }
        if let s = obj["content"] as? String { return s }
        return ""
    }

    private func ensureThread(_ out: inout [AssistantEvent]) {
        guard !threadEmitted else { return }
        threadEmitted = true
        let id = sessionId ?? UUID().uuidString
        out.append(.threadStarted(threadId: id, providerThreadId: sessionId))
    }

    private func ensureTurn(_ out: inout [AssistantEvent]) {
        guard !turnEmitted else { return }
        turnEmitted = true
        turnFinished = false
        let id = UUID().uuidString
        currentTurnId = id
        out.append(.turnStarted(turnId: id))
    }

    private func openReasoningItem(_ out: inout [AssistantEvent], now: Int64) -> String {
        if let id = reasoningItemId { return id }
        let id = UUID().uuidString
        reasoningItemId = id
        out.append(.itemStarted(item: AssistantItem(
            id: id, turnId: currentTurnId ?? "", type: .reasoning, state: .streaming,
            body: "", startedAtMs: now
        )))
        return id
    }

    private func openAssistantItem(_ out: inout [AssistantEvent], now: Int64) -> String {
        if let id = assistantItemId { return id }
        let id = UUID().uuidString
        assistantItemId = id
        out.append(.itemStarted(item: AssistantItem(
            id: id, turnId: currentTurnId ?? "", type: .assistantMessage, state: .streaming,
            body: "", startedAtMs: now
        )))
        return id
    }

    private func closeOpenItems(_ out: inout [AssistantEvent]) {
        if let id = reasoningItemId {
            out.append(.itemCompleted(itemId: id, finalState: .completed))
            reasoningItemId = nil
        }
        if let id = assistantItemId {
            out.append(.itemCompleted(itemId: id, finalState: .completed))
            assistantItemId = nil
        }
    }

    private func encodeJSON(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let s = String(data: data, encoding: .utf8) else {
            return value as? String
        }
        return s
    }
}
