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
    /// Last non-empty assistant phase before a tool_call reset. Used only when
    /// the trailing phase is empty after control-token strip (pure `<|eos|>`)
    /// so finishTurn does not yield a nil final after a turn that already spoke.
    private var lastNonEmptyAssistantPhase = ""
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
    /// Open ACP tool_call ids that have not yet reached a terminal status.
    /// Used by the turn-inactivity watchdog to avoid false `.completed` while
    /// a long quiet tool is still in flight (starsac-class mid-CI cut).
    private var openToolCallIds = Set<String>()
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

    /// True when the open turn has already produced speakable assistant text.
    /// Used by the turn-inactivity watchdog to prefer `.completed` over `.failed`
    /// when synthesizing a terminal after `session/prompt` never returns — but
    /// only when no tool_call is still open (see `hasOpenToolCalls`).
    public var hasSpeakableFinalContent: Bool {
        lock.lock(); defer { lock.unlock() }
        if let final = finalAssistantMessage?
            .trimmingCharacters(in: .whitespacesAndNewlines), !final.isEmpty {
            return true
        }
        if !currentAssistantPhase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        if !lastNonEmptyAssistantPhase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return false
    }

    /// True while at least one tool_call lacks a terminal tool_call_update.
    public var hasOpenToolCalls: Bool {
        lock.lock(); defer { lock.unlock() }
        return !openToolCallIds.isEmpty
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
            lastNonEmptyAssistantPhase = ""
            finalAssistantMessage = nil
            sawDetachedShellSpawn = false
            openToolCallIds.removeAll(keepingCapacity: false)
            events.append(.turnStarted(turnId: id))
        }
        return events
    }

    /// Clear any synthetic turn opened while absorbing `session/load` replay.
    ///
    /// WHY: ACP `session/load` re-emits historical `session/update`s. If those
    /// leave `turnId` set, the next user prompt's `beginTurn()` no-ops into the
    /// replay turn and the UI counts prior tools as "Work so far · N steps in
    /// this turn" under the new user bubble.
    public func sealHydration() {
        lock.lock(); defer { lock.unlock() }
        reasoningItemId = nil
        assistantItemId = nil
        turnId = nil
        finished = true
        currentAssistantPhase = ""
        lastNonEmptyAssistantPhase = ""
        finalAssistantMessage = nil
        sawDetachedShellSpawn = false
        openToolCallIds.removeAll(keepingCapacity: false)
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
        guard let kind = update["sessionUpdate"] as? String else { return events }

        // After finishTurn / sealHydration, turnId is nil and finished is true.
        // Timeline content must not mint a fresh turnStarted (durable seq 1
        // collision). Session *state* (mode, commands, usage) still applies so
        // a follow-up prompt sees negotiated mode after load hydration.
        if finished {
            applySessionStateOnly(kind: kind, update: update, events: &events)
            return events
        }
        ensureTurn(&events)
        let now = Self.now

        switch kind {
        case "agent_thought_chunk":
            let text = Self.contentText(update["content"])
            guard !text.isEmpty else { return events }
            if !currentAssistantPhase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lastNonEmptyAssistantPhase = currentAssistantPhase
            }
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
            // Preserve last real answer phase before tools; pure-EOS tail after
            // tools can fall back instead of wiping the visible final entirely.
            if !currentAssistantPhase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lastNonEmptyAssistantPhase = currentAssistantPhase
            }
            currentAssistantPhase = ""
            let id = update["toolCallId"] as? String ?? UUID().uuidString
            let title = update["title"] as? String ?? "Grok tool"
            openToolCallIds.insert(id)
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
                switch status {
                case "completed", "cancelled", "failed":
                    openToolCallIds.remove(id)
                    events.append(.itemCompleted(itemId: id, finalState: Self.itemState(status)))
                case "in_progress", "pending", "running":
                    openToolCallIds.insert(id)
                    // Keep item streaming — do not mark completed on progress status.
                default:
                    openToolCallIds.remove(id)
                    events.append(.itemCompleted(itemId: id, finalState: Self.itemState(status)))
                }
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
            applyUsageUpdate(update, events: &events)

        case "available_commands_update":
            applyAvailableCommandsUpdate(update, events: &events)

        case "current_mode_update":
            applyCurrentModeUpdate(update, events: &events)

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

    /// Session state that must survive after sealHydration / finishTurn without
    /// reopening a user-facing turn.
    private func applySessionStateOnly(
        kind: String,
        update: [String: Any],
        events: inout [AssistantEvent]
    ) {
        switch kind {
        case "usage_update":
            applyUsageUpdate(update, events: &events)
        case "available_commands_update":
            applyAvailableCommandsUpdate(update, events: &events)
        case "current_mode_update":
            applyCurrentModeUpdate(update, events: &events)
        case "config_option_update", "session_info_update":
            events.append(Self.runtimeEvent(method: kind, payload: update))
        default:
            break
        }
    }

    private func applyUsageUpdate(_ update: [String: Any], events: inout [AssistantEvent]) {
        if let usage = Self.usage(update["usage"] as? [String: Any] ?? update) {
            latestUsage = usage
            events.append(.tokenUsage(usage))
        }
    }

    private func applyAvailableCommandsUpdate(_ update: [String: Any], events: inout [AssistantEvent]) {
        availableCommands = (update["availableCommands"] as? [[String: Any]] ?? []).compactMap { raw in
            guard let name = raw["name"] as? String, !name.isEmpty else { return nil }
            return GrokACPAvailableCommand(name: name, description: raw["description"] as? String)
        }
        events.append(Self.runtimeEvent(method: "available_commands_update", payload: update))
    }

    private func applyCurrentModeUpdate(_ update: [String: Any], events: inout [AssistantEvent]) {
        currentModeId = update["currentModeId"] as? String
        events.append(Self.runtimeEvent(method: "current_mode_update", payload: update))
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
        // Prefer the trailing phase; if it is empty after control-token strip
        // (pure `<|eos|>`), fall back to the last non-empty pre-tool phase so
        // a turn that already spoke does not persist a nil/missing answer.
        let trailing = currentAssistantPhase.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = lastNonEmptyAssistantPhase.trimmingCharacters(in: .whitespacesAndNewlines)
        var final: String? = !trailing.isEmpty ? currentAssistantPhase
            : (!fallback.isEmpty ? lastNonEmptyAssistantPhase : nil)
        // Stamp only for COMPLETED-class stop reasons (end_turn, max_tokens, …).
        // Never for failed/cancelled. Single stamp on finalAssistantMessage so both
        // .turnCompleted here and adapter .finished see the marker once.
        if GrokACPTerminalClassifier.isCompletedStopReason(stopReason), sawDetachedShellSpawn {
            final = BackgroundAwaitContinuation.prefixingAwaitingMarker(final)
        }
        finalAssistantMessage = final
        events.append(.turnCompleted(turnId: turnId, finalMessage: finalAssistantMessage))
        self.turnId = nil
        currentAssistantPhase = ""
        lastNonEmptyAssistantPhase = ""
        sawDetachedShellSpawn = false
        openToolCallIds.removeAll(keepingCapacity: false)
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
        lastNonEmptyAssistantPhase = ""
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
        let raw: String
        if let string = value as? String {
            raw = string
        } else if let content = value as? [String: Any] {
            raw = content["text"] as? String ?? ""
        } else {
            raw = ""
        }
        // Grok occasionally streams tokenizer control markers into
        // agent_message_chunk / agent_thought_chunk (live incident: final body
        // was literally `Repos8<|eos|>`). Drop them at the parse seam so the
        // timeline, finalMessage, and UI never see them.
        return ProviderControlTokenSanitizer.stripStreamingChunk(raw)
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
