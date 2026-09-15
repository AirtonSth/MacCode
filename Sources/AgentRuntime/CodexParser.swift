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
        return parseObject(obj)
    }

    /// Dispatch on an already-decoded `codex exec --json` object so CodexRunner
    /// can share one JSONSerialization with providerRuntime.
    public func parseObject(
        _ obj: [String: Any],
        now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) -> [AssistantEvent] {
        guard let type = obj["type"] as? String else { return [] }

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
        case "item.started", "item.updated":
            // Real `codex exec --json` nests the payload under `item`
            // (openai/codex exec_events ItemStartedEvent / ItemUpdatedEvent).
            // Legacy synthetic fixtures keep flat item_id/item_type.
            if let item = obj["item"] as? [String: Any] {
                return eventsForNestedItem(item, now: now, terminal: false)
            }
            let id = obj["item_id"] as? String ?? obj["id"] as? String ?? UUID().uuidString
            let turnId = obj["turn_id"] as? String ?? currentTurnId ?? ""
            let kind = (obj["item_type"] as? String) ?? (obj["kind"] as? String) ?? "assistantMessage"
            let it = AssistantItem(
                id: id, turnId: turnId,
                type: mapItemType(kind),
                state: .streaming,
                summary: obj["summary"] as? String,
                body: obj["body"] as? String ?? "",
                output: obj["output"] as? String,
                progress: Self.progressValue(obj),
                startedAtMs: now
            )
            return [.itemStarted(item: it)]
        case "item.delta":
            let id = obj["item_id"] as? String ?? obj["id"] as? String ?? ""
            let body = obj["body_delta"] as? String ?? obj["delta"] as? String
            let output = obj["output_delta"] as? String
            let summary = obj["summary"] as? String
            if let b = body { assembled += b }
            var out: [AssistantEvent] = [.itemDelta(itemId: id, bodyAppend: body, outputAppend: output, summary: summary)]
            if let progress = Self.progressValue(obj) {
                out.append(.itemProgress(itemId: id, progress: progress))
            }
            return out
        case "item.completed":
            // Real `codex exec --json`: the payload is a nested `item`
            // {id,type,text|aggregated_output,...}. agent_message carries the reply.
            if let item = obj["item"] as? [String: Any] {
                return eventsForNestedItem(item, now: now, terminal: true)
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
            var out: [AssistantEvent] = []
            if let usage = tokenUsage(from: obj["usage"] as? [String: Any]) {
                out.append(.tokenUsage(usage))
            }
            currentTurnId = nil
            // Reset the agent_message accumulator so a subsequent turn (even one
            // that arrives without a turn.started) does not bleed this turn's text
            // into its own final message (was: doubled transcript in the mirror).
            assembled = ""
            out.append(.turnCompleted(turnId: tid, finalMessage: final))
            return out
        case "request.opened":
            let id = obj["request_id"] as? String ?? obj["id"] as? String ?? UUID().uuidString
            let kind = mapRequestKind(obj["request_type"] as? String ?? obj["kind"] as? String ?? "")
            let title = obj["title"] as? String ?? obj["summary"] as? String ?? kind.rawValue
            let detail = obj["detail"] as? String ?? obj["command"] as? String ?? obj["path"] as? String
            return [.requestOpened(AssistantPendingRequest(id: id, turnId: currentTurnId, kind: kind, title: title, detail: detail, createdAtMs: now))]
        case "request.resolved":
            let id = obj["request_id"] as? String ?? obj["id"] as? String ?? ""
            let state = AssistantRequestState(rawValue: obj["state"] as? String ?? "") ?? .resolved
            return [.requestResolved(requestId: id, state: state)]
        case "user_input.requested":
            let id = obj["request_id"] as? String ?? obj["id"] as? String ?? UUID().uuidString
            let prompt = obj["prompt"] as? String ?? obj["question"] as? String ?? "Input required"
            let options = obj["options"] as? [String] ?? []
            let allowsMultiple = obj["allows_multiple_selection"] as? Bool
                ?? obj["allows_multiple"] as? Bool
                ?? obj["multi_select"] as? Bool
                ?? ((obj["max_selections"] as? Int).map { $0 > 1 } ?? false)
            return [.userInputRequested(AssistantUserInputRequest(id: id, turnId: currentTurnId, prompt: prompt, options: options, allowsMultipleSelection: allowsMultiple, createdAtMs: now))]
        case "user_input.resolved":
            let id = obj["request_id"] as? String ?? obj["id"] as? String ?? ""
            let answer = obj["answer"] as? String
            return [.userInputResolved(requestId: id, answer: answer)]
        case "turn.proposed_plan", "proposed_plan":
            let id = obj["plan_id"] as? String ?? obj["id"] as? String ?? UUID().uuidString
            let markdown = obj["plan_markdown"] as? String ?? obj["markdown"] as? String ?? obj["text"] as? String ?? ""
            return [.proposedPlan(AssistantProposedPlan(id: id, turnId: currentTurnId, markdown: markdown))]
        case "plan_update", "update_plan", "turn.plan_update":
            guard let plan = activePlan(from: obj, now: now) else { return [] }
            return [.activePlanUpdated(plan)]
        case "thread.token_usage", "token_usage":
            let input = obj["input_tokens"] as? Int ?? 0
            let output = obj["output_tokens"] as? Int ?? 0
            let total = obj["total_tokens"] as? Int ?? (input + output)
            let window = obj["context_window"] as? Int
            let compactsAutomatically = obj["compacts_automatically"] as? Bool ?? obj["compactsAutomatically"] as? Bool
            // Codex reports a single input total plus an optional cached portion (no
            // separate cache-creation bucket). Split it (G3): uncached = input - cached,
            // read = cached, creation = 0. inputTokens stays the billed total (back-compat).
            let cachedInput = obj["cached_input_tokens"] as? Int ?? obj["cachedInputTokens"] as? Int ?? 0
            return [.tokenUsage(AssistantTokenUsage(
                inputTokens: input,
                outputTokens: output,
                totalTokens: total,
                contextWindow: window,
                compactsAutomatically: compactsAutomatically,
                uncachedInputTokens: max(0, input - cachedInput),
                cacheCreationInputTokens: 0,
                cacheReadInputTokens: cachedInput,
                semantics: .cumulative
            ))]
        case "context.compaction", "context_compaction":
            return [.contextCompaction(summary: obj["summary"] as? String)]
        case "turn.failed":
            let msg = (obj["error"] as? [String: Any])?["message"] as? String
                ?? obj["message"] as? String ?? "codex turn failed"
            return [.error(message: msg, recoverable: false)]
        case "error":
            let msg = obj["message"] as? String ?? "unknown error"
            let recoverable = obj["recoverable"] as? Bool ?? false
            return [.error(message: msg, recoverable: recoverable)]
        default:
            if isExplicitlyUnsupportedRealtimeEvent(type) {
                var out: [AssistantEvent] = []
                ensureTurn(&out)
                let turnId = currentTurnId ?? ""
                let id = obj["id"] as? String ?? obj["event_id"] as? String ?? "unsupported-\(UUID().uuidString)"
                let message = "Unsupported Codex realtime event: \(type)"
                out.append(.itemStarted(item: AssistantItem(
                    id: id,
                    turnId: turnId,
                    type: .error,
                    state: .completed,
                    summary: "Unsupported realtime event",
                    body: message,
                    startedAtMs: now,
                    finishedAtMs: now
                )))
                out.append(.itemCompleted(itemId: id, finalState: .completed))
                return out
            }
            return []
        }
    }

    private func isExplicitlyUnsupportedRealtimeEvent(_ type: String) -> Bool {
        let lowered = type.lowercased()
        return lowered.hasPrefix("realtime.")
            || lowered.hasPrefix("audio.")
            || lowered.contains("audio_delta")
            || lowered.contains("realtime")
    }

    /// Project a nested `codex exec --json` ThreadItem into Assistant events.
    /// `terminal` true = item.completed (or final snapshot); false = started/updated.
    private func eventsForNestedItem(
        _ item: [String: Any],
        now: Int64,
        terminal: Bool
    ) -> [AssistantEvent] {
        let iid = item["id"] as? String ?? UUID().uuidString
        let kind = (item["type"] as? String) ?? "agent_message"
        let text = Self.itemText(from: item)
        let tt = mapItemType(kind)
        let wireState = Self.itemState(for: item["status"] as? String)
        let finalState: AssistantItemState = terminal
            ? (wireState == .streaming ? .completed : wireState)
            : wireState
        var out: [AssistantEvent] = []
        ensureTurn(&out)
        let turnId = currentTurnId ?? ""
        switch tt {
        case .assistantMessage:
            if terminal, !text.isEmpty {
                assembled += (assembled.isEmpty ? "" : "\n") + text
            }
            out.append(.itemStarted(item: AssistantItem(
                id: iid, turnId: turnId, type: .assistantMessage,
                state: terminal ? finalState : .streaming,
                summary: nil, body: terminal ? "" : text, startedAtMs: now
            )))
            if terminal, !text.isEmpty {
                out.append(.itemDelta(itemId: iid, bodyAppend: text, outputAppend: nil, summary: nil))
            }
            if terminal {
                out.append(.itemCompleted(itemId: iid, finalState: finalState))
            }
        case .commandExecution, .tool, .mcpToolCall, .dynamicToolCall, .collabToolCall:
            let summary = item["command"] as? String
                ?? item["name"] as? String
                ?? item["tool"] as? String
                ?? kind
            out.append(.itemStarted(item: AssistantItem(
                id: iid, turnId: turnId, type: tt,
                state: finalState,
                summary: summary, body: "", output: text,
                progress: Self.progressValue(item), startedAtMs: now,
                finishedAtMs: terminal ? now : nil
            )))
            if terminal {
                out.append(.itemCompleted(itemId: iid, finalState: finalState))
            }
        default: // reasoning / plan / file_change / web_search
            if tt == .plan, let plan = activePlan(from: item, now: now) {
                out.append(.activePlanUpdated(plan))
            }
            out.append(.itemStarted(item: AssistantItem(
                id: iid, turnId: turnId, type: tt,
                state: terminal ? finalState : .streaming,
                summary: item["command"] as? String ?? item["name"] as? String,
                body: "", output: text,
                progress: Self.progressValue(item), startedAtMs: now,
                finishedAtMs: terminal ? now : nil
            )))
            if terminal {
                out.append(.itemCompleted(itemId: iid, finalState: finalState))
            }
        }
        return out
    }

    private static func itemText(from item: [String: Any]) -> String {
        // Prefer command_execution.aggregated_output (openai/codex ThreadItem).
        if let aggregated = item["aggregated_output"] as? String, !aggregated.isEmpty {
            return aggregated
        }
        if let text = item["text"] as? String, !text.isEmpty { return text }
        if let output = item["output"] as? String, !output.isEmpty { return output }
        if let command = item["command"] as? String, !command.isEmpty { return command }
        if let changes = item["changes"] {
            if let data = try? JSONSerialization.data(withJSONObject: changes),
               let s = String(data: data, encoding: .utf8) {
                return s
            }
        }
        return ""
    }

    /// Mirror CodexAppServerAdapter.itemState for exec JSONL status strings.
    private static func itemState(for status: String?) -> AssistantItemState {
        let normalized = status?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "")
            .lowercased()
        switch normalized {
        case "completed", "succeeded", "success", "approved":
            return .completed
        case "failed", "blocked", "timedout", "errored", "error":
            return .failed
        case "cancelled", "canceled", "declined", "decline", "denied", "deny",
             "stopped", "aborted", "interrupted":
            return .cancelled
        default:
            return .streaming
        }
    }

    private func tokenUsage(from usage: [String: Any]?) -> AssistantTokenUsage? {
        guard let usage else { return nil }
        let input = usage["input_tokens"] as? Int ?? usage["inputTokens"] as? Int ?? 0
        let output = usage["output_tokens"] as? Int ?? usage["outputTokens"] as? Int ?? 0
        let cached = usage["cached_input_tokens"] as? Int
            ?? usage["cachedInputTokens"] as? Int
            ?? 0
        let cacheWrite = usage["cache_write_input_tokens"] as? Int
            ?? usage["cacheWriteInputTokens"] as? Int
            ?? 0
        let total = usage["total_tokens"] as? Int ?? (input + output)
        return AssistantTokenUsage(
            inputTokens: input,
            outputTokens: output,
            totalTokens: total,
            contextWindow: usage["context_window"] as? Int ?? usage["contextWindow"] as? Int,
            compactsAutomatically: usage["compacts_automatically"] as? Bool
                ?? usage["compactsAutomatically"] as? Bool,
            uncachedInputTokens: max(0, input - cached),
            cacheCreationInputTokens: cacheWrite,
            cacheReadInputTokens: cached,
            semantics: .cumulative
        )
    }

    private func mapItemType(_ s: String) -> AssistantItemType {
        switch s.lowercased() {
        case "reasoning": return .reasoning
        case "plan", "todo_list", "plan_update": return .plan
        case "command", "command_execution": return .commandExecution
        case "file_change", "patch", "apply_patch": return .fileChange
        case "mcp", "mcp_tool_call": return .mcpToolCall
        case "dynamic", "dynamic_tool_call": return .dynamicToolCall
        case "collab", "collab_tool_call": return .collabToolCall
        case "web_search": return .webSearch
        case "image_view": return .imageView
        case "review": return .review
        case "context_compaction": return .contextCompaction
        case "error": return .error
        case "tool", "tool_call": return .tool
        case "agent_message", "assistantmessage", "assistant", "message", "text":
            return .assistantMessage
        default: return .assistantMessage
        }
    }

    private func activePlan(from obj: [String: Any], now: Int64) -> AssistantActivePlan? {
        let rawSteps = obj["items"] as? [[String: Any]]
            ?? obj["plan"] as? [[String: Any]]
            ?? obj["steps"] as? [[String: Any]]
            ?? (obj["update"] as? [String: Any])?["plan"] as? [[String: Any]]
        guard let rawSteps, !rawSteps.isEmpty else { return nil }
        let steps = rawSteps.enumerated().compactMap { index, raw -> AssistantPlanStep? in
            let title = raw["step"] as? String
                ?? raw["title"] as? String
                ?? raw["text"] as? String
                ?? raw["content"] as? String
                ?? ""
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let status: AssistantPlanStepStatus
            if let completed = raw["completed"] as? Bool {
                status = completed ? .completed : .pending
            } else {
                let statusRaw = raw["status"] as? String ?? "pending"
                status = AssistantPlanStepStatus(rawValue: statusRaw)
                    ?? (statusRaw == "inProgress" ? .inProgress : .pending)
            }
            let id = raw["id"] as? String ?? "\(index)-\(trimmed)"
            return AssistantPlanStep(id: id, title: trimmed, status: status)
        }
        guard !steps.isEmpty else { return nil }
        return AssistantActivePlan(
            explanation: obj["explanation"] as? String,
            steps: steps,
            updatedAtMs: now
        )
    }

    private func mapRequestKind(_ s: String) -> AssistantRequestKind {
        switch s.lowercased() {
        case "command_execution": return .commandExecution
        case "file_read": return .fileRead
        case "file_change": return .fileChange
        case "apply_patch": return .applyPatch
        case "exec": return .exec
        case "tool_user_input", "user_input": return .toolUserInput
        case "dynamic": return .dynamic
        case "auth_tokens_refresh": return .authTokensRefresh
        default: return .dynamic
        }
    }

    // PERF: progressValue trims string percent payloads on streaming item
    // events; share one CharacterSet instead of allocating per string parse.
    private static let progressPercentTrimSet = CharacterSet(charactersIn: "% ")

    private static func progressValue(_ obj: [String: Any]) -> Double? {
        for key in ["progress", "percentage", "percent"] {
            if let value = obj[key] as? Double { return AssistantTimelineState.normalizedProgress(value) }
            if let value = obj[key] as? Int { return AssistantTimelineState.normalizedProgress(Double(value)) }
            if let value = obj[key] as? String,
               let parsed = Double(value.trimmingCharacters(in: progressPercentTrimSet)) {
                return AssistantTimelineState.normalizedProgress(parsed)
            }
        }
        return nil
    }
}
