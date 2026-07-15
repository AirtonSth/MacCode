import Foundation
import CoreModel

public final class GrokACPEventMapper: @unchecked Sendable {
    public let sessionId: String
    public private(set) var availableCommands: [GrokACPAvailableCommand] = []
    public private(set) var currentModeId: String?
    public private(set) var latestUsage: AssistantTokenUsage?
    public private(set) var finalAssistantMessage: String?

    private var threadEmitted = false
    private var turnId: String?
    private var reasoningItemId: String?
    private var assistantItemId: String?
    private var currentAssistantPhase = ""
    private var finished = false
    private var seenEventIds = Set<String>()
    private let lock = NSLock()

    public init(sessionId: String) { self.sessionId = sessionId }

    public func beginTurn() -> [AssistantEvent] {
        lock.lock(); defer { lock.unlock() }
        var events: [AssistantEvent] = []
        ensureThread(&events)
        if turnId == nil {
            let id = UUID().uuidString
            turnId = id
            finished = false
            currentAssistantPhase = ""
            finalAssistantMessage = nil
            events.append(.turnStarted(turnId: id))
        }
        return events
    }

    public func consumeSessionUpdate(_ update: [String: Any]) -> [AssistantEvent] {
        lock.lock(); defer { lock.unlock() }
        var events: [AssistantEvent] = []
        if let metadata = update["_meta"] as? [String: Any],
           let eventId = metadata["eventId"] as? String,
           !seenEventIds.insert(eventId).inserted {
            return []
        }
        ensureThread(&events)
        ensureTurn(&events)
        let now = Self.now
        guard let kind = update["sessionUpdate"] as? String else { return events }

        switch kind {
        case "agent_thought_chunk":
            let text = Self.contentText(update["content"])
            guard !text.isEmpty else { return events }
            closeAssistant(&events)
            currentAssistantPhase = ""
            let itemId = openReasoning(&events, now: now)
            events.append(.itemDelta(itemId: itemId, bodyAppend: text, outputAppend: nil, summary: nil))

        case "agent_message_chunk":
            let text = Self.contentText(update["content"])
            guard !text.isEmpty else { return events }
            closeReasoning(&events)
            let itemId = openAssistant(&events, now: now)
            currentAssistantPhase += text
            events.append(.itemDelta(itemId: itemId, bodyAppend: text, outputAppend: nil, summary: nil))

        case "tool_call":
            closeReasoning(&events)
            closeAssistant(&events)
            currentAssistantPhase = ""
            let id = update["toolCallId"] as? String ?? UUID().uuidString
            let title = update["title"] as? String ?? "Grok tool"
            events.append(.itemStarted(item: AssistantItem(
                id: id,
                turnId: turnId ?? "",
                type: .tool,
                state: .streaming,
                summary: title,
                body: Self.jsonString(update["rawInput"]) ?? "",
                startedAtMs: now
            )))

        case "tool_call_update":
            let id = update["toolCallId"] as? String ?? UUID().uuidString
            let output = Self.toolOutput(update)
            let title = update["title"] as? String
            if output != nil || title != nil {
                events.append(.itemDelta(itemId: id, bodyAppend: nil, outputAppend: output, summary: title))
            }
            if let status = update["status"] as? String {
                events.append(.itemCompleted(itemId: id, finalState: Self.itemState(status)))
            }

        case "plan":
            let entries = update["entries"] as? [[String: Any]] ?? []
            let markdown = entries.enumerated().compactMap { index, entry -> String? in
                guard let content = entry["content"] as? String, !content.isEmpty else { return nil }
                let status = entry["status"] as? String ?? "pending"
                return "\(index + 1). [\(status)] \(content)"
            }.joined(separator: "\n")
            if !markdown.isEmpty {
                events.append(.proposedPlan(AssistantProposedPlan(
                    id: "grok-plan-\(turnId ?? UUID().uuidString)",
                    turnId: turnId,
                    markdown: markdown
                )))
            }

        case "usage_update":
            if let usage = Self.usage(update["usage"] as? [String: Any] ?? update) {
                latestUsage = usage
                events.append(.tokenUsage(usage))
            }

        case "available_commands_update":
            availableCommands = (update["availableCommands"] as? [[String: Any]] ?? []).compactMap { raw in
                guard let name = raw["name"] as? String, !name.isEmpty else { return nil }
                return GrokACPAvailableCommand(name: name, description: raw["description"] as? String)
            }
            events.append(Self.runtimeEvent(method: kind, payload: update))

        case "current_mode_update":
            currentModeId = update["currentModeId"] as? String
            events.append(Self.runtimeEvent(method: kind, payload: update))

        case "config_option_update", "session_info_update", "user_message_chunk":
            events.append(Self.runtimeEvent(method: kind, payload: update))

        default:
            events.append(Self.runtimeEvent(method: kind, payload: update))
        }
        return events
    }

    public func finishTurn(stopReason: String, usage: [String: Any]?) -> [AssistantEvent] {
        lock.lock(); defer { lock.unlock() }
        var events: [AssistantEvent] = []
        ensureThread(&events)
        ensureTurn(&events)
        if let usage, let parsed = Self.usage(usage) {
            latestUsage = parsed
            events.append(.tokenUsage(parsed))
        }
        closeOpenItems(&events)
        guard let turnId, !finished else { return events }
        finished = true
        finalAssistantMessage = currentAssistantPhase.isEmpty ? nil : currentAssistantPhase
        events.append(.turnCompleted(turnId: turnId, finalMessage: finalAssistantMessage))
        self.turnId = nil
        currentAssistantPhase = ""
        return events
    }

    private func ensureThread(_ events: inout [AssistantEvent]) {
        guard !threadEmitted else { return }
        threadEmitted = true
        events.append(.threadStarted(threadId: sessionId, providerThreadId: sessionId))
    }

    private func ensureTurn(_ events: inout [AssistantEvent]) {
        guard turnId == nil else { return }
        let id = UUID().uuidString
        turnId = id
        finished = false
        currentAssistantPhase = ""
        events.append(.turnStarted(turnId: id))
    }

    private func openReasoning(_ events: inout [AssistantEvent], now: Int64) -> String {
        if let reasoningItemId { return reasoningItemId }
        let id = UUID().uuidString
        reasoningItemId = id
        events.append(.itemStarted(item: AssistantItem(
            id: id, turnId: turnId ?? "", type: .reasoning, state: .streaming, body: "", startedAtMs: now
        )))
        return id
    }

    private func openAssistant(_ events: inout [AssistantEvent], now: Int64) -> String {
        if let assistantItemId { return assistantItemId }
        let id = UUID().uuidString
        assistantItemId = id
        events.append(.itemStarted(item: AssistantItem(
            id: id, turnId: turnId ?? "", type: .assistantMessage, state: .streaming, body: "", startedAtMs: now
        )))
        return id
    }

    private func closeReasoning(_ events: inout [AssistantEvent]) {
        guard let reasoningItemId else { return }
        events.append(.itemCompleted(itemId: reasoningItemId, finalState: .completed))
        self.reasoningItemId = nil
    }

    private func closeAssistant(_ events: inout [AssistantEvent]) {
        guard let assistantItemId else { return }
        events.append(.itemCompleted(itemId: assistantItemId, finalState: .completed))
        self.assistantItemId = nil
    }

    private func closeOpenItems(_ events: inout [AssistantEvent]) {
        closeReasoning(&events)
        closeAssistant(&events)
    }

    private static var now: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    private static func contentText(_ value: Any?) -> String {
        if let string = value as? String { return string }
        guard let content = value as? [String: Any] else { return "" }
        return content["text"] as? String ?? ""
    }

    private static func toolOutput(_ update: [String: Any]) -> String? {
        if let raw = update["rawOutput"] { return jsonString(raw) }
        let blocks = update["content"] as? [[String: Any]] ?? []
        let text = blocks.compactMap { block -> String? in
            if let content = block["content"] as? [String: Any] { return content["text"] as? String }
            return block["text"] as? String
        }.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    private static func itemState(_ status: String) -> AssistantItemState {
        switch status {
        case "completed": return .completed
        case "cancelled": return .cancelled
        default: return .failed
        }
    }

    private static func usage(_ raw: [String: Any]) -> AssistantTokenUsage? {
        let input = int(raw["inputTokens"]) ?? int(raw["input_tokens"]) ?? 0
        let output = int(raw["outputTokens"]) ?? int(raw["output_tokens"]) ?? 0
        let total = int(raw["totalTokens"]) ?? int(raw["total_tokens"]) ?? input + output
        let cached = int(raw["cachedReadTokens"]) ?? int(raw["cache_read_input_tokens"])
        guard total > 0 || input > 0 || output > 0 else { return nil }
        return AssistantTokenUsage(
            inputTokens: input,
            outputTokens: output,
            totalTokens: total,
            uncachedInputTokens: cached.map { max(0, input - $0) },
            cacheReadInputTokens: cached
        )
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func jsonString(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String { return string }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func runtimeEvent(method: String, payload: [String: Any]) -> AssistantEvent {
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        return .providerRuntime(ProviderRuntimeEvent(
            provider: .grok,
            source: "grok.acp",
            method: method,
            providerItemId: payload["toolCallId"] as? String,
            payloadJSON: String(data: data, encoding: .utf8) ?? "{}",
            receivedAtMs: now
        ))
    }
}
