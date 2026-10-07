import Foundation
import CoreModel

/// Parser for official Grok Build CLI headless output
/// (`grok -p … --output-format streaming-json`).
///
/// Event shape (observed from grok 0.2.x / headless streaming-json docs):
/// - `{"type":"thought","data":"…"}` — reasoning token stream
/// - `{"type":"text","data":"…"}` — assistant text stream
/// - `{"type":"end","stopReason":"…","sessionId":"…","requestId":"…"}`
/// - optional tool_call / tool_result (non-exhaustive; treat unknown types as no-ops)
///
/// Phase boundaries match Grok TUI ordering: thought phases complete before
/// text/tools, and a later thought phase opens a new reasoning item (does not
/// keep rewriting the first Thought block above the answer).
///
/// Maps into the shared AssistantEvent model used by Agent App.
public final class GrokParser {
    public init(initialSessionId: String? = nil) {
        sessionId = initialSessionId?.isEmpty == false ? initialSessionId : nil
    }

    private var sessionId: String?
    private var threadEmitted = false
    private var currentTurnId: String?
    private var turnEmitted = false
    private var reasoningItemId: String?
    private var assistantItemId: String?
    private var assembledAssistantBody = ""
    /// Last non-empty assistant phase before tools/thought reset. Pure-EOS
    /// trailing phase falls back to this so finalMessage is not wiped to nil.
    private var lastNonEmptyAssistantPhase = ""
    private var turnFinished = false
    /// tool_call ids that have not yet reached a terminal tool_call_update /
    /// tool_result. Sealed on end/error/finalize so timeline tools do not stay
    /// streaming forever (GROK-PARSER-001).
    private var openToolCallIds = Set<String>()

    public var capturedSessionId: String? { sessionId }

    public func parseLine(_ line: String) -> [AssistantEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let data = trimmed.data(using: .utf8) else { return [] }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return parseObject(obj)
    }

    /// Dispatch on an already-decoded streaming-json object so GrokRunner
    /// can share one JSONSerialization with providerRuntime filtering.
    public func parseObject(
        _ obj: [String: Any],
        now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) -> [AssistantEvent] {
        guard let type = obj["type"] as? String else { return [] }

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
            // Terminal UX: a new thought phase after answer/tool text is a *new*
            // Thinking… row (chronological), not more tokens on the first Thought
            // block sitting above the message.
            if assistantItemId != nil {
                rememberAssistantPhaseBeforeReset()
                assembledAssistantBody = ""
            }
            closeAssistantItem(&out)
            let itemId = openReasoningItem(&out, now: now)
            out.append(.itemDelta(itemId: itemId, bodyAppend: chunk, outputAppend: nil, summary: nil))

        case "text":
            ensureTurn(&out)
            let chunk = textChunk(from: obj)
            guard !chunk.isEmpty else { return out }
            // Seal Thinking… → Thought before the answer streams so reasoning
            // cannot keep expanding on top of the assistant message.
            closeReasoningItem(&out)
            let itemId = openAssistantItem(&out, now: now)
            assembledAssistantBody += chunk
            out.append(.itemDelta(itemId: itemId, bodyAppend: chunk, outputAppend: nil, summary: nil))

        case "usage":
            // grok-build 1.0 streaming-json emits a per-response `usage` line
            // before `end`. Usage must not wait for `end` only.
            if let usage = Self.tokenUsage(from: obj) {
                out.append(.tokenUsage(usage))
            }

        case "end":
            ensureTurn(&out)
            // Prefer the authoritative session id on end so resume works.
            if let sid = (obj["sessionId"] as? String) ?? (obj["session_id"] as? String), !sid.isEmpty {
                sessionId = sid
                // Re-emit so TimelineAggregator.providerThreadId is the real session.
                out.append(.threadStarted(threadId: sid, providerThreadId: sid))
            }
            // Usage needs these events — without them Grok stays "No data"
            // while Claude/Codex fill weekly used % / token totals.
            if let usage = Self.tokenUsage(from: obj) {
                out.append(.tokenUsage(usage))
            }
            let stopReason = (obj["stopReason"] as? String) ?? (obj["stop_reason"] as? String)
            closeOpenItems(&out, toolFinalState: Self.toolFinalState(forStopReason: stopReason))
            if let turnId = currentTurnId, !turnFinished {
                turnFinished = true
                out.append(.turnCompleted(turnId: turnId, finalMessage: resolvedFinalMessage()))
            }

        case "error":
            ensureTurn(&out)
            closeOpenItems(&out, toolFinalState: .failed)
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
            // Tools break a thought phase (same as the Grok TUI timeline order).
            if assistantItemId != nil {
                rememberAssistantPhaseBeforeReset()
                assembledAssistantBody = ""
            }
            closeReasoningItem(&out)
            closeAssistantItem(&out)
            let name = (obj["name"] as? String)
                ?? (obj["tool"] as? String)
                ?? (obj["toolName"] as? String)
                ?? (obj["title"] as? String)
                ?? "tool"
            // Prefer toolCallId (live streaming-json 1.0); fall back to id.
            let itemId = (obj["toolCallId"] as? String)
                ?? (obj["tool_call_id"] as? String)
                ?? (obj["id"] as? String)
                ?? UUID().uuidString
            let turnId = currentTurnId ?? ""
            let input = encodeJSON(obj["input"] ?? obj["arguments"] ?? obj["rawInput"] ?? obj["data"] ?? [:])
            openToolCallIds.insert(itemId)
            out.append(.itemStarted(item: AssistantItem(
                id: itemId, turnId: turnId, type: .tool, state: .streaming,
                summary: name, body: input ?? "", startedAtMs: now
            )))

        case "tool_call_update":
            // Live grok 1.0 streaming-json completes tools via tool_call_update
            // (status pending → completed), not tool_result (GROK-PARSER-001).
            ensureTurn(&out)
            let itemId = (obj["toolCallId"] as? String)
                ?? (obj["tool_call_id"] as? String)
                ?? (obj["id"] as? String)
                ?? UUID().uuidString
            let output = Self.toolOutput(from: obj)
            let title = obj["title"] as? String
            if output != nil || title != nil {
                out.append(.itemDelta(itemId: itemId, bodyAppend: nil, outputAppend: output, summary: title))
            }
            if let status = obj["status"] as? String {
                switch status {
                case "completed", "cancelled", "failed":
                    openToolCallIds.remove(itemId)
                    out.append(.itemCompleted(itemId: itemId, finalState: Self.itemState(status)))
                case "in_progress", "pending", "running":
                    openToolCallIds.insert(itemId)
                    // Keep item streaming — do not mark completed on progress status.
                default:
                    openToolCallIds.remove(itemId)
                    out.append(.itemCompleted(itemId: itemId, finalState: Self.itemState(status)))
                }
            }

        case "tool_result", "tool_response":
            ensureTurn(&out)
            let itemId = (obj["toolCallId"] as? String)
                ?? (obj["tool_call_id"] as? String)
                ?? (obj["id"] as? String)
                ?? UUID().uuidString
            let payload = (obj["content"] as? String)
                ?? (obj["output"] as? String)
                ?? (obj["data"] as? String)
                ?? encodeJSON(obj["result"] as Any? ?? obj["content"] as Any? ?? "")
                ?? ""
            openToolCallIds.remove(itemId)
            out.append(.itemDelta(itemId: itemId, bodyAppend: nil, outputAppend: payload, summary: nil))
            out.append(.itemCompleted(itemId: itemId, finalState: .completed))

        case "plan":
            // grok-build streaming-json AcpLine::Plan { entries }.
            ensureTurn(&out)
            let entries = obj["entries"] as? [[String: Any]] ?? []
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
                out.append(.activePlanUpdated(AssistantActivePlan(
                    steps: steps,
                    updatedAtMs: now
                )))
            }

        case "max_turns_reached":
            ensureTurn(&out)
            closeOpenItems(&out, toolFinalState: .completed)
            if let turnId = currentTurnId, !turnFinished {
                turnFinished = true
                out.append(.turnCompleted(turnId: turnId, finalMessage: resolvedFinalMessage()))
            }

        default:
            break
        }
        return out
    }

    public func finalize() -> [AssistantEvent] {
        var out: [AssistantEvent] = []
        closeOpenItems(&out, toolFinalState: .completed)
        if let turnId = currentTurnId, !turnFinished {
            turnFinished = true
            out.append(.turnCompleted(turnId: turnId, finalMessage: resolvedFinalMessage()))
        }
        return out
    }

    // MARK: - Internals

    private func textChunk(from obj: [String: Any]) -> String {
        let raw: String
        if let s = obj["data"] as? String {
            raw = s
        } else if let s = obj["text"] as? String {
            raw = s
        } else if let s = obj["content"] as? String {
            raw = s
        } else {
            raw = ""
        }
        // Same control-token defense as GrokACPEventMapper.contentText — CLI
        // streaming-json can leak `<|eos|>` into type=text / type=thought.
        return ProviderControlTokenSanitizer.stripStreamingChunk(raw)
    }

    private func rememberAssistantPhaseBeforeReset() {
        if !assembledAssistantBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lastNonEmptyAssistantPhase = assembledAssistantBody
        }
    }

    private func resolvedFinalMessage() -> String? {
        let trailing = assembledAssistantBody.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trailing.isEmpty { return assembledAssistantBody }
        let fallback = lastNonEmptyAssistantPhase.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? nil : lastNonEmptyAssistantPhase
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

    private func closeReasoningItem(_ out: inout [AssistantEvent]) {
        if let id = reasoningItemId {
            out.append(.itemCompleted(itemId: id, finalState: .completed))
            reasoningItemId = nil
        }
    }

    private func closeAssistantItem(_ out: inout [AssistantEvent]) {
        if let id = assistantItemId {
            out.append(.itemCompleted(itemId: id, finalState: .completed))
            assistantItemId = nil
        }
    }

    private func closeOpenItems(
        _ out: inout [AssistantEvent],
        toolFinalState: AssistantItemState = .completed
    ) {
        closeReasoningItem(&out)
        closeAssistantItem(&out)
        for id in openToolCallIds.sorted() {
            out.append(.itemCompleted(itemId: id, finalState: toolFinalState))
        }
        openToolCallIds.removeAll(keepingCapacity: false)
    }

    private func encodeJSON(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let s = String(data: data, encoding: .utf8) else {
            return value as? String
        }
        return s
    }

    private static func toolOutput(from obj: [String: Any]) -> String? {
        if let raw = obj["rawOutput"] {
            if let string = raw as? String { return string }
            if JSONSerialization.isValidJSONObject(raw),
               let data = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]),
               let string = String(data: data, encoding: .utf8) {
                return string
            }
        }
        if let string = obj["output"] as? String, !string.isEmpty { return string }
        if let string = obj["content"] as? String, !string.isEmpty { return string }
        let blocks = obj["content"] as? [[String: Any]] ?? []
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

    /// Map streaming-json / ACP-style stop reasons onto tool terminal state when
    /// sealing tools that never received a terminal update.
    private static func toolFinalState(forStopReason stopReason: String?) -> AssistantItemState {
        guard let stopReason, !stopReason.isEmpty else { return .completed }
        let normalized = normalizeStopReason(stopReason)
        if normalized == "cancelled" || normalized == "canceled" { return .cancelled }
        if GrokACPTerminalClassifier.isCompletedStopReason(normalized) { return .completed }
        // Live CLI often emits PascalCase EndTurn; after normalize that is end_turn.
        // Anything else (error, failed, …) fails open tools.
        return .failed
    }

    /// `EndTurn` → `end_turn`, `max_tokens` stays, so classifier can match ACP ids.
    // SEP-3: compile once — replacingOccurrences(options: .regularExpression)
    // recompiled on every call (same PERF pattern as ClaudeParser.whitespaceRegex).
    private static let camelBoundaryRegex = try! NSRegularExpression(pattern: "([a-z0-9])([A-Z])")
    private static func normalizeStopReason(_ stopReason: String) -> String {
        let trimmed = stopReason.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        let snake = Self.camelBoundaryRegex.stringByReplacingMatches(
            in: trimmed, range: range, withTemplate: "$1_$2"
        )
        return snake.lowercased()
    }

    /// Maps Grok `end` spend fields into the shared token-usage event.
    ///
    /// Observed shape (streaming-json):
    /// ```json
    /// "usage": {
    ///   "input_tokens": 25103,
    ///   "cache_read_input_tokens": 6016,
    ///   "output_tokens": 18,
    ///   "reasoning_tokens": 13,
    ///   "total_tokens": 31137
    /// },
    /// "modelUsage": { "grok-4.5": { "inputTokens": …, "outputTokens": …, "cacheReadInputTokens": … } }
    /// ```
    static func tokenUsage(from obj: [String: Any]) -> AssistantTokenUsage? {
        if let modelUsage = obj["modelUsage"] as? [String: Any] ?? obj["model_usage"] as? [String: Any] {
            var uncached = 0
            var read = 0
            var output = 0
            var window: Int?
            var modelCostUSD = 0.0
            var modelCostComplete = true
            var modelCount = 0
            for value in modelUsage.values {
                guard let usage = value as? [String: Any] else { continue }
                modelCount += 1
                uncached += intValue(usage["inputTokens"]) ?? intValue(usage["input_tokens"]) ?? 0
                read += intValue(usage["cacheReadInputTokens"]) ?? intValue(usage["cache_read_input_tokens"]) ?? 0
                output += intValue(usage["outputTokens"]) ?? intValue(usage["output_tokens"]) ?? 0
                if let cost = doubleValue(usage["costUSD"] ?? usage["cost_usd"]) {
                    modelCostUSD += cost
                } else {
                    modelCostComplete = false
                }
                if let contextWindow = intValue(usage["contextWindow"]) ?? intValue(usage["context_window"]) {
                    window = max(window ?? 0, contextWindow)
                }
            }
            // Prefer top-level usage for cache-read when modelUsage omitted it.
            if read == 0, let top = obj["usage"] as? [String: Any] {
                read = intValue(top["cache_read_input_tokens"]) ?? intValue(top["cacheReadInputTokens"]) ?? 0
            }
            if window == nil, let top = obj["usage"] as? [String: Any] {
                window = intValue(top["context_window"]) ?? intValue(top["contextWindow"])
            }
            let input = uncached + read
            let total = input + output
            guard total > 0 else { return nil }
            let reportedCostMicros = costMicros(
                fromUSD: doubleValue(obj["total_cost_usd"] ?? obj["totalCostUSD"])
                    ?? (modelCount > 0 && modelCostComplete ? modelCostUSD : nil)
                    ?? costUSD(from: obj["usage"] as? [String: Any])
            )
            // modelUsage is session-cumulative (cache re-reads sum across the
            // session). Leave contextTokens nil so the gauge cannot treat it as
            // current context occupancy.
            return AssistantTokenUsage(
                inputTokens: input,
                outputTokens: output,
                totalTokens: total,
                contextWindow: window,
                uncachedInputTokens: uncached,
                cacheReadInputTokens: read > 0 ? read : nil,
                reportedCostMicros: reportedCostMicros,
                contextTokens: nil,
                semantics: .cumulative
            )
        }

        let usage = obj["usage"] as? [String: Any] ?? obj["token_usage"] as? [String: Any]
        guard let usage else { return nil }
        let uncached = intValue(usage["input_tokens"]) ?? intValue(usage["inputTokens"]) ?? 0
        let read = intValue(usage["cache_read_input_tokens"]) ?? intValue(usage["cacheReadInputTokens"]) ?? 0
        let output = intValue(usage["output_tokens"]) ?? intValue(usage["outputTokens"]) ?? 0
        // reasoning_tokens are billed as output-side work; include in total when
        // present and not already folded into output_tokens.
        let reasoning = intValue(usage["reasoning_tokens"]) ?? intValue(usage["reasoningTokens"]) ?? 0
        let input = uncached + read
        let total = intValue(usage["total_tokens"])
            ?? intValue(usage["totalTokens"])
            ?? (input + output + reasoning)
        guard total > 0 || input > 0 || output > 0 else { return nil }
        let window = intValue(usage["context_window"]) ?? intValue(usage["contextWindow"])
        let reportedCostMicros = costMicros(
            fromUSD: doubleValue(obj["total_cost_usd"] ?? obj["totalCostUSD"])
                ?? doubleValue(usage["costUSD"] ?? usage["cost_usd"])
                ?? costUSD(from: usage)
        )
        // Per-request occupancy: uncached + cache read + output (+ reasoning when
        // billed separately). Not the cumulative modelUsage path.
        let contextTokens = uncached + read + max(output, reasoning > 0 && output == 0 ? reasoning : output)
        return AssistantTokenUsage(
            inputTokens: input,
            outputTokens: max(output, reasoning > 0 && output == 0 ? reasoning : output),
            totalTokens: total,
            contextWindow: window,
            uncachedInputTokens: uncached,
            cacheReadInputTokens: read > 0 ? read : nil,
            reportedCostMicros: reportedCostMicros,
            contextTokens: contextTokens > 0 ? contextTokens : nil,
            semantics: .cumulative
        )
    }

    private static func costUSD(from usage: [String: Any]?) -> Double? {
        guard let usage else { return nil }
        if let ticks = doubleValue(usage["cost_in_usd_ticks"] ?? usage["costInUsdTicks"]),
           ticks.isFinite, ticks >= 0 {
            return ticks / 10_000_000_000
        }
        return nil
    }

    private static func costMicros(fromUSD value: Double?) -> Int? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        let micros = (value * 1_000_000).rounded()
        guard micros <= Double(Int.max) else { return nil }
        return Int(micros)
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        if let value = any as? Double { return value }
        if let value = any as? Int { return Double(value) }
        if let value = any as? NSNumber { return value.doubleValue }
        if let value = any as? String { return Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }
}
