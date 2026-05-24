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
    private var indexToToolName: [Int: String] = [:]
    private var indexToToolInputJSON: [Int: String] = [:]
    private var assembledAssistantBody: String = ""

    public func parseLine(_ line: String) -> [AssistantEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let data = trimmed.data(using: .utf8) else { return [] }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        guard let type = obj["type"] as? String else { return [] }
        let now = Int64(Date().timeIntervalSince1970 * 1000)

        var out: [AssistantEvent] = []

        // Every line (incl. the cmux shim's hook_started/hook_response
        // lines that arrive BEFORE init) carries session_id — capture it
        // so the resume id is never lost.
        if let sid = obj["session_id"] as? String, !sid.isEmpty { sessionId = sid }

        if type == "system" {
            // Emit threadStarted only on init (the shim's hook_* lines must
            // NOT trip the fallback before the real session id is known).
            if (obj["subtype"] as? String) == "init", !threadEmitted {
                threadEmitted = true
                out.append(.threadStarted(threadId: sessionId ?? UUID().uuidString,
                                          providerThreadId: sessionId))
            }
            out.append(contentsOf: systemEvents(from: obj, now: now))
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
            if itemType == .tool {
                indexToToolName[index] = summary
                if let input = block["input"],
                   let data = try? JSONSerialization.data(withJSONObject: input),
                   let inputString = String(data: data, encoding: .utf8) {
                    indexToToolInputJSON[index] = inputString
                }
            }
            out.append(.itemStarted(item: AssistantItem(id: itemId, turnId: turnId, type: itemType, state: .streaming, summary: summary, body: "", progress: Self.progressValue(block) ?? Self.progressValue(obj), startedAtMs: now)))
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
                if let text {
                    indexToToolInputJSON[index, default: ""] += text
                }
                out.append(.itemDelta(itemId: itemId, bodyAppend: nil, outputAppend: text, summary: nil))
            default:
                break
            }
            if let progress = Self.progressValue(delta) ?? Self.progressValue(obj) {
                out.append(.itemProgress(itemId: itemId, progress: progress))
            }
        case "content_block_stop":
            let index = obj["index"] as? Int ?? 0
            if let itemId = indexToItemId[index] {
                out.append(.itemCompleted(itemId: itemId, finalState: .completed))
                if indexToType[index] == .tool {
                    out.append(contentsOf: structuredClaudeToolEvents(
                        toolId: itemId,
                        name: indexToToolName[index],
                        input: parseToolInput(indexToToolInputJSON[index]),
                        turnId: currentTurnId ?? "",
                        now: now
                    ))
                }
                indexToItemId.removeValue(forKey: index)
                indexToType.removeValue(forKey: index)
                indexToToolName.removeValue(forKey: index)
                indexToToolInputJSON.removeValue(forKey: index)
            }
        case "message_delta", "message_stop":
            break
        case "assistant", "user":
            // `claude --print --output-format stream-json` emits whole
            // messages, NOT Anthropic-API deltas: {type:"assistant",
            // message:{content:[{type:"text",text:…}|{type:"tool_use",…}]}}.
            ensureTurn(&out)
            let msg = obj["message"] as? [String: Any] ?? [:]
            let content = msg["content"] as? [[String: Any]] ?? []
            for block in content {
                let bt = (block["type"] as? String) ?? "text"
                let itemId = (block["id"] as? String) ?? UUID().uuidString
                let turnId = currentTurnId ?? ""
                switch bt {
                case "text":
                    let text = block["text"] as? String ?? ""
                    if text.isEmpty { break }
                    assembledAssistantBody += (assembledAssistantBody.isEmpty ? "" : "\n") + text
                    out.append(.itemStarted(item: AssistantItem(id: itemId, turnId: turnId, type: .assistantMessage, state: .streaming, summary: nil, body: "", startedAtMs: now)))
                    out.append(.itemDelta(itemId: itemId, bodyAppend: text, outputAppend: nil, summary: nil))
                    out.append(.itemCompleted(itemId: itemId, finalState: .completed))
                case "thinking":
                    let text = block["thinking"] as? String ?? ""
                    out.append(.itemStarted(item: AssistantItem(id: itemId, turnId: turnId, type: .reasoning, state: .streaming, summary: nil, body: "", startedAtMs: now)))
                    out.append(.itemDelta(itemId: itemId, bodyAppend: text, outputAppend: nil, summary: nil))
                    out.append(.itemCompleted(itemId: itemId, finalState: .completed))
                case "tool_use":
                    let name = block["name"] as? String
                    let input = (try? JSONSerialization.data(withJSONObject: block["input"] ?? [:]))
                        .flatMap { String(data: $0, encoding: .utf8) }
                    let structuredEvents = structuredClaudeToolEvents(
                        toolId: itemId,
                        name: name,
                        input: block["input"] as? [String: Any],
                        turnId: turnId,
                        now: now
                    )
                    out.append(.itemStarted(item: AssistantItem(id: itemId, turnId: turnId, type: .tool, state: .streaming, summary: name, body: input ?? "", startedAtMs: now)))
                    out.append(.itemCompleted(itemId: itemId, finalState: .completed))
                    out.append(contentsOf: structuredEvents)
                case "tool_result":
                    let payload = block["content"]
                    let s = (payload as? String) ?? ((try? JSONSerialization.data(withJSONObject: payload ?? [:])).flatMap { String(data: $0, encoding: .utf8) }) ?? ""
                    out.append(.itemStarted(item: AssistantItem(id: itemId, turnId: turnId, type: .tool, state: .completed, summary: "result", body: "", output: s, startedAtMs: now)))
                    out.append(.itemCompleted(itemId: itemId, finalState: .completed))
                default:
                    break
                }
            }
        case "result":
            // Authoritative final answer is the top-level `result` string.
            let isError = (obj["is_error"] as? Bool) ?? ((obj["subtype"] as? String).map { $0 != "success" } ?? false)
            let resultText = obj["result"] as? String
            if isError {
                let msg = resultText
                    ?? (obj["error"] as? [String: Any])?["message"] as? String
                    ?? "claude run failed"
                out.append(.error(message: msg, recoverable: false))
            }
            ensureTurn(&out)
            let final = (resultText?.isEmpty == false ? resultText : nil)
                ?? (assembledAssistantBody.isEmpty ? nil : assembledAssistantBody)
            if let tid = currentTurnId {
                out.append(.turnCompleted(turnId: tid, finalMessage: final))
                currentTurnId = nil
                assembledAssistantBody = ""
            }
        case "error":
            let msg = (obj["error"] as? [String: Any])?["message"] as? String ?? "claude error"
            out.append(.error(message: msg, recoverable: false))
        case "plan_update", "update_plan":
            if let plan = activePlan(from: obj, now: now) {
                out.append(.activePlanUpdated(plan))
            }
        case "tool_progress":
            if let event = progressItem(from: obj, defaultSummary: "Claude tool progress", now: now) {
                out.append(contentsOf: event)
            }
        case "tool_use_summary":
            out.append(contentsOf: completedRuntimeItem(
                id: stringValue(obj["id"]) ?? stringValue(obj["tool_use_id"]) ?? UUID().uuidString,
                type: .tool,
                summary: stringValue(obj["name"]) ?? stringValue(obj["tool_name"]) ?? "Claude tool summary",
                body: stringValue(obj["summary"]) ?? jsonString(obj["input"]) ?? jsonString(obj),
                now: now
            ))
        case "auth_status":
            out.append(contentsOf: authStatusEvents(from: obj, now: now))
        case "rate_limit_event":
            out.append(contentsOf: rateLimitEvents(from: obj, now: now))
        case "usage", "token_usage":
            if let usage = tokenUsage(from: obj) {
                out.append(.tokenUsage(usage))
            }
        case "compact_boundary", "context_compaction":
            out.append(contentsOf: compactionEvents(from: obj, now: now))
        case "permission_request", "request.opened", "canUseTool/request":
            if let request = permissionRequest(from: obj, now: now) {
                out.append(.requestOpened(request))
            }
        case "permission_decision", "request.resolved", "canUseTool/decision":
            if let resolved = permissionResolution(from: obj) {
                out.append(.requestResolved(requestId: resolved.id, state: resolved.state))
            }
        case "user_input_request", "elicitation":
            if let request = userInputRequest(from: obj, now: now) {
                out.append(.userInputRequested(request))
            }
        case "user_input_response", "user_input_resolved":
            if let id = stringValue(obj["request_id"]) ?? stringValue(obj["id"]) ?? stringValue(obj["elicitation_id"]) {
                out.append(.userInputResolved(requestId: id, answer: stringValue(obj["text"]) ?? stringValue(obj["answer"])))
            }
        default:
            break
        }
        return out
    }

    private func systemEvents(from obj: [String: Any], now: Int64) -> [AssistantEvent] {
        let subtype = obj["subtype"] as? String ?? ""
        switch subtype {
        case "init":
            var out: [AssistantEvent] = []
            if let usage = tokenUsage(from: obj) {
                out.append(.tokenUsage(usage))
            }
            return out
        case "status":
            return completedRuntimeItem(
                id: stringValue(obj["id"]) ?? "claude-status-\(now)",
                type: .tool,
                summary: "Claude status: \(stringValue(obj["status"]) ?? stringValue(obj["state"]) ?? "updated")",
                body: stringValue(obj["message"]) ?? jsonString(obj),
                now: now
            )
        case "compact_boundary":
            return compactionEvents(from: obj, now: now)
        case "hook_started", "hook_progress", "hook_response":
            let hook = stringValue(obj["hook_name"]) ?? stringValue(obj["name"]) ?? "hook"
            var out = completedRuntimeItem(
                id: stringValue(obj["id"]) ?? "\(subtype)-\(hook)-\(now)",
                type: .tool,
                summary: "Claude hook: \(hook)",
                body: stringValue(obj["output"]) ?? stringValue(obj["message"]) ?? jsonString(obj),
                now: now
            )
            if let progress = Self.progressValue(obj), let id = firstStartedItemId(in: out) {
                out.append(.itemProgress(itemId: id, progress: progress))
            }
            return out
        case "task_started", "task_progress", "task_notification":
            return taskEvents(from: obj, subtype: subtype, now: now)
        case "files_persisted":
            let files = obj["files"] as? [String] ?? []
            return completedRuntimeItem(
                id: stringValue(obj["id"]) ?? "files-persisted-\(now)",
                type: .fileChange,
                summary: "Claude files persisted",
                body: files.isEmpty ? (stringValue(obj["message"]) ?? jsonString(obj)) : files.joined(separator: "\n"),
                now: now
            )
        case "auth_status":
            return authStatusEvents(from: obj, now: now)
        case "rate_limit_event":
            return rateLimitEvents(from: obj, now: now)
        default:
            if let usage = tokenUsage(from: obj) {
                return [.tokenUsage(usage)]
            }
            return []
        }
    }

    private func taskEvents(from obj: [String: Any], subtype: String, now: Int64) -> [AssistantEvent] {
        var out = completedRuntimeItem(
            id: stringValue(obj["id"]) ?? stringValue(obj["task_id"]) ?? "\(subtype)-\(now)",
            type: .tool,
            summary: stringValue(obj["title"]) ?? stringValue(obj["task"]) ?? "Claude task",
            body: stringValue(obj["message"]) ?? stringValue(obj["notification"]) ?? jsonString(obj),
            now: now
        )
        if let progress = Self.progressValue(obj), let id = firstStartedItemId(in: out) {
            out.append(.itemProgress(itemId: id, progress: progress))
        }
        return out
    }

    private func progressItem(from obj: [String: Any], defaultSummary: String, now: Int64) -> [AssistantEvent]? {
        let id = stringValue(obj["id"]) ?? stringValue(obj["tool_use_id"]) ?? stringValue(obj["item_id"]) ?? "tool-progress-\(now)"
        var out = completedRuntimeItem(
            id: id,
            type: .tool,
            summary: stringValue(obj["name"]) ?? stringValue(obj["tool_name"]) ?? defaultSummary,
            body: stringValue(obj["message"]) ?? stringValue(obj["summary"]) ?? jsonString(obj),
            now: now
        )
        if let progress = Self.progressValue(obj) {
            out.append(.itemProgress(itemId: id, progress: progress))
        }
        return out
    }

    private func compactionEvents(from obj: [String: Any], now: Int64) -> [AssistantEvent] {
        let summary = stringValue(obj["summary"])
            ?? stringValue(obj["message"])
            ?? "Claude context compacted"
        var out = completedRuntimeItem(
            id: stringValue(obj["id"]) ?? "claude-compaction-\(now)",
            type: .contextCompaction,
            summary: summary,
            body: summary,
            now: now
        )
        out.append(.contextCompaction(summary: summary))
        return out
    }

    private func authStatusEvents(from obj: [String: Any], now: Int64) -> [AssistantEvent] {
        let status = stringValue(obj["status"]) ?? stringValue(obj["state"]) ?? "updated"
        let message = stringValue(obj["message"]) ?? "Claude auth \(status)"
        if boolValue(obj["authenticated"]) == false || status.lowercased().contains("fail") {
            return [
                .error(message: message, recoverable: true)
            ] + completedRuntimeItem(id: stringValue(obj["id"]) ?? "claude-auth-\(now)", type: .error, summary: "Claude auth", body: message, now: now)
        }
        return completedRuntimeItem(
            id: stringValue(obj["id"]) ?? "claude-auth-\(now)",
            type: .tool,
            summary: "Claude auth: \(status)",
            body: message,
            now: now
        )
    }

    private func rateLimitEvents(from obj: [String: Any], now: Int64) -> [AssistantEvent] {
        let reset = stringValue(obj["reset_at"]) ?? stringValue(obj["resetAt"])
        let message = stringValue(obj["message"])
            ?? [stringValue(obj["limit_type"]) ?? stringValue(obj["limitType"]) ?? "rate limit", reset.map { "reset \($0)" }]
                .compactMap { $0 }
                .joined(separator: " ")
        return [
            .error(message: "Claude \(message)", recoverable: true)
        ] + completedRuntimeItem(id: stringValue(obj["id"]) ?? "claude-rate-limit-\(now)", type: .error, summary: "Claude rate limit", body: message, now: now)
    }

    private func tokenUsage(from obj: [String: Any]) -> AssistantTokenUsage? {
        let usage = obj["usage"] as? [String: Any] ?? obj["token_usage"] as? [String: Any] ?? obj
        let input = intValue(usage["input_tokens"]) ?? intValue(usage["inputTokens"]) ?? 0
        let output = intValue(usage["output_tokens"]) ?? intValue(usage["outputTokens"]) ?? 0
        let total = intValue(usage["total_tokens"]) ?? intValue(usage["totalTokens"]) ?? (input + output)
        let window = intValue(usage["context_window"]) ?? intValue(usage["contextWindow"])
        guard input > 0 || output > 0 || total > 0 || window != nil else { return nil }
        let compactsAutomatically = usage["compacts_automatically"] as? Bool ?? usage["compactsAutomatically"] as? Bool
        return AssistantTokenUsage(inputTokens: input, outputTokens: output, totalTokens: total, contextWindow: window, compactsAutomatically: compactsAutomatically)
    }

    private func permissionRequest(from obj: [String: Any], now: Int64) -> AssistantPendingRequest? {
        let request = obj["request"] as? [String: Any] ?? obj
        let id = stringValue(request["request_id"])
            ?? stringValue(request["requestId"])
            ?? stringValue(request["id"])
            ?? stringValue(request["tool_use_id"])
        guard let id, !id.isEmpty else { return nil }
        let toolName = stringValue(request["tool_name"])
            ?? stringValue(request["toolName"])
            ?? stringValue(request["name"])
            ?? "Claude tool"
        let detail = stringValue(request["detail"])
            ?? stringValue(request["message"])
            ?? jsonString(request["input"])
            ?? jsonString(request)
        return AssistantPendingRequest(
            id: id,
            turnId: currentTurnId,
            kind: requestKind(from: toolName, request: request),
            title: toolName,
            detail: detail,
            createdAtMs: now
        )
    }

    private func permissionResolution(from obj: [String: Any]) -> (id: String, state: AssistantRequestState)? {
        let request = obj["request"] as? [String: Any] ?? obj
        let id = stringValue(request["request_id"])
            ?? stringValue(request["requestId"])
            ?? stringValue(request["id"])
            ?? stringValue(request["tool_use_id"])
        guard let id, !id.isEmpty else { return nil }
        let raw = (stringValue(request["state"]) ?? stringValue(request["decision"]) ?? stringValue(request["behavior"]) ?? "resolved").lowercased()
        let state: AssistantRequestState
        switch raw {
        case "allow", "allowed", "approve", "approved", "accept", "accepted":
            state = .approved
        case "deny", "denied", "decline", "declined", "reject", "rejected":
            state = .declined
        case "cancel", "cancelled", "canceled":
            state = .cancelled
        default:
            state = .resolved
        }
        return (id, state)
    }

    private func userInputRequest(from obj: [String: Any], now: Int64) -> AssistantUserInputRequest? {
        guard let id = stringValue(obj["request_id"]) ?? stringValue(obj["id"]) ?? stringValue(obj["elicitation_id"]) else {
            return nil
        }
        let schema = obj["requested_schema"] as? [String: Any]
        let prompt = stringValue(obj["prompt"])
            ?? stringValue(obj["question"])
            ?? stringValue(obj["message"])
            ?? stringValue(obj["title"])
            ?? stringValue(obj["description"])
            ?? "Input required"
        let options = optionValues(obj["options"] ?? obj["choices"] ?? schema?["enum"])
        return AssistantUserInputRequest(
            id: id,
            turnId: stringValue(obj["turn_id"]) ?? currentTurnId ?? id,
            prompt: prompt,
            options: options,
            allowsMultipleSelection: boolValue(obj["allows_multiple_selection"])
                ?? boolValue(obj["allowsMultipleSelection"])
                ?? boolValue(schema?["uniqueItems"])
                ?? false,
            createdAtMs: now
        )
    }

    private func requestKind(from toolName: String, request: [String: Any]) -> AssistantRequestKind {
        if let raw = stringValue(request["kind"]) ?? stringValue(request["request_type"]) ?? stringValue(request["requestType"]),
           let kind = AssistantRequestKind(rawValue: raw) {
            return kind
        }
        let lowered = toolName.lowercased()
        if lowered.contains("bash") || lowered.contains("shell") || lowered.contains("exec") {
            return .commandExecution
        }
        if lowered.contains("read") {
            return .fileRead
        }
        if lowered.contains("edit") || lowered.contains("write") || lowered.contains("patch") {
            return .fileChange
        }
        return .dynamic
    }

    private func completedRuntimeItem(id: String, type: AssistantItemType, summary: String, body: String?, now: Int64) -> [AssistantEvent] {
        let turnId = currentTurnId ?? ""
        return [
            .itemStarted(item: AssistantItem(id: id, turnId: turnId, type: type, state: .completed, summary: summary, body: body ?? "", startedAtMs: now, finishedAtMs: now)),
            .itemCompleted(itemId: id, finalState: type == .error ? .failed : .completed)
        ]
    }

    private func firstStartedItemId(in events: [AssistantEvent]) -> String? {
        for event in events {
            if case .itemStarted(let item) = event { return item.id }
        }
        return nil
    }

    private func structuredClaudeToolEvents(toolId: String, name: String?, input: [String: Any]?, turnId: String, now: Int64) -> [AssistantEvent] {
        guard let tool = name?.lowercased() else { return [] }
        let input = input ?? [:]
        if tool == "askuserquestion" || tool == "ask_user_question" || tool == "ask_user" {
            let prompt = stringValue(input["question"])
                ?? stringValue(input["prompt"])
                ?? stringValue(input["message"])
                ?? "Input required"
            return [.userInputRequested(AssistantUserInputRequest(
                id: toolId,
                turnId: turnId,
                prompt: prompt,
                options: optionValues(input["options"] ?? input["choices"]),
                allowsMultipleSelection: boolValue(input["allows_multiple_selection"])
                    ?? boolValue(input["allowsMultipleSelection"])
                    ?? boolValue(input["multi_select"])
                    ?? false,
                createdAtMs: now
            ))]
        }
        if tool == "exitplanmode" || tool == "exit_plan_mode" {
            let markdown = stringValue(input["plan"])
                ?? stringValue(input["markdown"])
                ?? stringValue(input["plan_markdown"])
                ?? stringValue(input["content"])
                ?? ""
            guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
            return [.proposedPlan(AssistantProposedPlan(id: toolId, turnId: turnId, markdown: markdown))]
        }
        return []
    }

    private func parseToolInput(_ raw: String?) -> [String: Any] {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }

    private func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private func boolValue(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool:
            return bool
        case let string as String:
            switch string.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        case let number as NSNumber:
            return number.boolValue
        default:
            return nil
        }
    }

    private func intValue(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    private func jsonString(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String { return string }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func optionValues(_ value: Any?) -> [String] {
        if let strings = value as? [String] {
            return strings
        }
        if let raw = value as? [[String: Any]] {
            return raw.compactMap {
                stringValue($0["label"])
                    ?? stringValue($0["value"])
                    ?? stringValue($0["text"])
                    ?? stringValue($0["title"])
            }
        }
        return []
    }

    private func activePlan(from obj: [String: Any], now: Int64) -> AssistantActivePlan? {
        let rawSteps = obj["plan"] as? [[String: Any]]
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
            let statusRaw = raw["status"] as? String ?? "pending"
            let status = AssistantPlanStepStatus(rawValue: statusRaw)
                ?? (statusRaw == "inProgress" ? .inProgress : .pending)
            let id = raw["id"] as? String ?? "\(index)-\(trimmed)"
            return AssistantPlanStep(id: id, title: trimmed, status: status)
        }
        guard !steps.isEmpty else { return nil }
        return AssistantActivePlan(explanation: obj["explanation"] as? String, steps: steps, updatedAtMs: now)
    }

    /// The CLI never sends `message_start`, so synthesize a turn the
    /// first time any assistant/result content appears.
    private func ensureTurn(_ out: inout [AssistantEvent]) {
        if currentTurnId == nil {
            let tid = UUID().uuidString
            currentTurnId = tid
            out.append(.turnStarted(turnId: tid))
        }
    }

    public func finalize() -> [AssistantEvent] {
        guard let tid = currentTurnId else { return [] }
        currentTurnId = nil
        return [.turnCompleted(turnId: tid, finalMessage: assembledAssistantBody.isEmpty ? nil : assembledAssistantBody)]
    }

    private static func progressValue(_ obj: [String: Any]) -> Double? {
        for key in ["progress", "percentage", "percent"] {
            if let value = obj[key] as? Double { return AssistantTimelineState.normalizedProgress(value) }
            if let value = obj[key] as? Int { return AssistantTimelineState.normalizedProgress(Double(value)) }
            if let value = obj[key] as? String,
               let parsed = Double(value.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) {
                return AssistantTimelineState.normalizedProgress(parsed)
            }
        }
        return nil
    }
}
