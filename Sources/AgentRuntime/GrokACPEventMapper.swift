import Foundation
import CoreModel

public final class GrokACPEventMapper: @unchecked Sendable {
    public let sessionId: String
    public private(set) var availableCommands: [GrokACPAvailableCommand] = []
    public private(set) var currentModeId: String?
    /// Negotiated Plan interaction mode id (may differ from the literal `"plan"`).
    public private(set) var planReviewModeId: String?
    public private(set) var latestUsage: AssistantTokenUsage?
    public private(set) var finalAssistantMessage: String?

    private var threadEmitted = false
    private var turnId: String?
    private var reasoningItemId: String?
    private var assistantItemId: String?
    private var currentAssistantPhase = ""
    private var finished = false
    private var seenEventIds = Set<String>()
    /// Shell-detached work Grok does NOT track: a tool_call whose rawInput
    /// command backgrounds children with `&` / `nohup` / `setsid` / `disown`.
    /// When set at a completed turn end, we prefix `[[RC_AWAITING]]` onto
    /// `finalAssistantMessage` (single source for both `.turnCompleted` and
    /// adapter `.finished`) so the host's existing marker path surfaces awaiting
    /// + auto-nudge. Grok has no provider deferral; this stamp is the only
    /// protection. Reset per turn.
    private var sawDetachedShellSpawn = false
    private let lock = NSLock()

    public init(sessionId: String) { self.sessionId = sessionId }

    /// Seed or refresh the ACP mode so plan session updates can distinguish
    /// live progress (default/full-access) from Plan-mode review artifacts.
    public func setCurrentModeId(_ modeId: String?) {
        lock.lock(); defer { lock.unlock() }
        currentModeId = modeId
    }

    public func setPlanReviewModeId(_ modeId: String?) {
        lock.lock(); defer { lock.unlock() }
        planReviewModeId = modeId
    }

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
            sawDetachedShellSpawn = false
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
        // After finishTurn, turnId is nil and finished is true. ensureTurn would
        // mint a fresh turnStarted; if the coordinator already cleared seq for the
        // run, that collides with durable seq 1 (often pre-turn servers_updated).
        if finished {
            return events
        }
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
            trackDetachedShellSpawn(in: update["rawInput"])
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
            // rawInput may only appear on update for some tools; accept it too.
            trackDetachedShellSpawn(in: update["rawInput"])
            if output != nil || title != nil {
                events.append(.itemDelta(itemId: id, bodyAppend: nil, outputAppend: output, summary: title))
            }
            if let status = update["status"] as? String {
                events.append(.itemCompleted(itemId: id, finalState: Self.itemState(status)))
            }

        case "plan":
            // ACP `plan` entries are live work-plan progress (statused steps),
            // matching Codex/Claude plan_update → activePlanUpdated. Emitting
            // proposedPlan for every update makes Full access auto-queue
            // "Implement this proposed plan now" while Grok is already working.
            let entries = update["entries"] as? [[String: Any]] ?? []
            let steps = entries.enumerated().compactMap { index, entry -> AssistantPlanStep? in
                guard let content = entry["content"] as? String else { return nil }
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                let statusRaw = entry["status"] as? String ?? "pending"
                let status = AssistantPlanStepStatus(rawValue: statusRaw)
                    ?? (statusRaw == "inProgress" ? .inProgress : .pending)
                return AssistantPlanStep(id: "\(index)-\(trimmed)", title: trimmed, status: status)
            }
            if !steps.isEmpty {
                events.append(.activePlanUpdated(AssistantActivePlan(
                    steps: steps,
                    updatedAtMs: now
                )))
                // Plan interaction mode still needs a reviewable proposed plan
                // for Approve / full-access auto-implement after the plan turn.
                if Self.isPlanReviewMode(currentModeId, planReviewModeId: planReviewModeId) {
                    let markdown = steps.enumerated().map { index, step in
                        "\(index + 1). [\(step.status.rawValue)] \(step.title)"
                    }.joined(separator: "\n")
                    events.append(.proposedPlan(AssistantProposedPlan(
                        id: "grok-plan-\(turnId ?? UUID().uuidString)",
                        turnId: turnId,
                        markdown: markdown
                    )))
                }
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

        case "subagent_spawned", "subagent_progress", "subagent_finished":
            // Grok normally emits these under method `_x.ai/session/update`.
            // When they arrive as plain ACP `session/update` kinds instead,
            // re-wrap so ProviderNativeSubagentLifecycle (which keys on the
            // `_x.ai/session/*` method envelope) still persists a Subagents row.
            events.append(Self.runtimeEvent(
                method: "_x.ai/session/update",
                payload: [
                    "sessionId": sessionId,
                    "update": update
                ]
            ))

        default:
            events.append(Self.runtimeEvent(method: kind, payload: update))
        }
        return events
    }

    public func finishTurn(stopReason: String, usage: [String: Any]?) -> [AssistantEvent] {
        lock.lock(); defer { lock.unlock() }
        var events: [AssistantEvent] = []
        ensureThread(&events)
        // Idempotent: a second finish (prompt complete + process exit race) must
        // not call ensureTurn after turnId was cleared — that re-opens turnStarted.
        if finished {
            return events
        }
        if turnId == nil {
            // Error path: complete a turn that never received beginTurn.
            ensureTurn(&events)
        }
        if let usage, let parsed = Self.usage(usage) {
            latestUsage = parsed
            events.append(.tokenUsage(parsed))
        }
        closeOpenItems(&events)
        guard let turnId else { return events }
        finished = true
        var final = currentAssistantPhase.isEmpty ? nil : currentAssistantPhase
        // Stamp only for a COMPLETED turn (end_turn). Never for failed/cancelled.
        // Single stamp on finalAssistantMessage so both .turnCompleted here and
        // adapter .finished (which reads the same property) see the marker once.
        if stopReason == "end_turn", sawDetachedShellSpawn {
            final = BackgroundAwaitContinuation.prefixingAwaitingMarker(final)
        }
        finalAssistantMessage = final
        events.append(.turnCompleted(turnId: turnId, finalMessage: finalAssistantMessage))
        self.turnId = nil
        currentAssistantPhase = ""
        sawDetachedShellSpawn = false
        return events
    }

    /// Inspect tool rawInput for a shell command string that detaches work.
    /// Accepts `command` / `cmd` / `script` string keys only.
    private func trackDetachedShellSpawn(in rawInput: Any?) {
        guard let dict = rawInput as? [String: Any] else { return }
        for key in ["command", "cmd", "script"] {
            guard let command = dict[key] as? String,
                  BackgroundAwaitContinuation.commandDetachesShellWork(command) else { continue }
            sawDetachedShellSpawn = true
            return
        }
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
        sawDetachedShellSpawn = false
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

    /// ACP Plan interaction mode only — not permission modes like bypassPermissions.
    private static func isPlanReviewMode(_ modeId: String?, planReviewModeId: String?) -> Bool {
        guard let modeId else { return false }
        let normalized = modeId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        if let planReviewModeId,
           planReviewModeId.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(normalized) == .orderedSame {
            return true
        }
        // Fallback when the peer advertises the common wire id without catalog seed.
        return normalized.caseInsensitiveCompare("plan") == .orderedSame
    }

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
            ?? int(raw["cacheReadInputTokens"])
        let window = int(raw["contextWindow"]) ?? int(raw["context_window"]) ?? int(raw["modelContextWindow"])
        guard total > 0 || input > 0 || output > 0 else { return nil }
        // ACP usage_update / finishTurn usage is per-request occupancy, not the
        // cumulative modelUsage shape from the CLI end event.
        let contextTokens = total > 0 ? total : (input + output)
        return AssistantTokenUsage(
            inputTokens: input,
            outputTokens: output,
            totalTokens: total,
            contextWindow: window,
            uncachedInputTokens: cached.map { max(0, input - $0) },
            cacheReadInputTokens: cached,
            contextTokens: contextTokens > 0 ? contextTokens : nil,
            semantics: .cumulative
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
