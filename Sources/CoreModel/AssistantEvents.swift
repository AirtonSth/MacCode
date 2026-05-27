import Foundation

public enum AssistantItemType: String, Codable, Sendable {
    case reasoning
    case plan
    case tool
    case assistantMessage
    case commandExecution
    case fileChange
    case mcpToolCall
    case dynamicToolCall
    case collabToolCall
    case webSearch
    case imageView
    case review
    case contextCompaction
    case error
}

public enum AssistantItemState: String, Codable, Sendable {
    case streaming
    case completed
    case failed
    case cancelled
}

public struct AssistantItem: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let turnId: String
    public var type: AssistantItemType
    public var state: AssistantItemState
    public var summary: String?
    public var body: String
    public var output: String?
    public var progress: Double?
    public var startedAtMs: Int64
    public var finishedAtMs: Int64?

    public init(id: String, turnId: String, type: AssistantItemType, state: AssistantItemState = .streaming, summary: String? = nil, body: String = "", output: String? = nil, progress: Double? = nil, startedAtMs: Int64, finishedAtMs: Int64? = nil) {
        self.id = id; self.turnId = turnId; self.type = type; self.state = state
        self.summary = summary; self.body = body; self.output = output; self.progress = progress
        self.startedAtMs = startedAtMs; self.finishedAtMs = finishedAtMs
    }
}

public enum AssistantRequestKind: String, Codable, Sendable {
    case commandExecution
    case fileRead
    case fileChange
    case applyPatch
    case exec
    case toolUserInput
    case dynamic
    case authTokensRefresh
}

public enum AssistantRequestState: String, Codable, Sendable {
    case pending
    case approved
    case declined
    case cancelled
    case resolved
    case stale
}

public struct AssistantPendingRequest: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let turnId: String?
    public let kind: AssistantRequestKind
    public var title: String
    public var detail: String?
    public var state: AssistantRequestState
    public var createdAtMs: Int64
    public var resolvedAtMs: Int64?

    public init(id: String, turnId: String?, kind: AssistantRequestKind, title: String, detail: String? = nil, state: AssistantRequestState = .pending, createdAtMs: Int64, resolvedAtMs: Int64? = nil) {
        self.id = id
        self.turnId = turnId
        self.kind = kind
        self.title = title
        self.detail = detail
        self.state = state
        self.createdAtMs = createdAtMs
        self.resolvedAtMs = resolvedAtMs
    }
}

public struct AssistantUserInputRequest: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let turnId: String?
    public var prompt: String
    public var options: [String]
    public var allowsMultipleSelection: Bool
    public var isSecret: Bool
    public var answer: String?
    public var state: AssistantRequestState
    public var createdAtMs: Int64
    public var resolvedAtMs: Int64?

    public init(id: String, turnId: String?, prompt: String, options: [String] = [], allowsMultipleSelection: Bool = false, isSecret: Bool = false, answer: String? = nil, state: AssistantRequestState = .pending, createdAtMs: Int64, resolvedAtMs: Int64? = nil) {
        self.id = id
        self.turnId = turnId
        self.prompt = prompt
        self.options = options
        self.allowsMultipleSelection = allowsMultipleSelection
        self.isSecret = isSecret
        self.answer = answer
        self.state = state
        self.createdAtMs = createdAtMs
        self.resolvedAtMs = resolvedAtMs
    }

    private enum CodingKeys: String, CodingKey {
        case id, turnId, prompt, options, allowsMultipleSelection, isSecret, answer, state, createdAtMs, resolvedAtMs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        turnId = try c.decodeIfPresent(String.self, forKey: .turnId)
        prompt = try c.decode(String.self, forKey: .prompt)
        options = try c.decodeIfPresent([String].self, forKey: .options) ?? []
        allowsMultipleSelection = try c.decodeIfPresent(Bool.self, forKey: .allowsMultipleSelection) ?? false
        isSecret = try c.decodeIfPresent(Bool.self, forKey: .isSecret) ?? false
        answer = try c.decodeIfPresent(String.self, forKey: .answer)
        state = try c.decodeIfPresent(AssistantRequestState.self, forKey: .state) ?? .pending
        createdAtMs = try c.decodeIfPresent(Int64.self, forKey: .createdAtMs) ?? 0
        resolvedAtMs = try c.decodeIfPresent(Int64.self, forKey: .resolvedAtMs)
    }
}

public struct AssistantPendingCallbacksSnapshot: Codable, Sendable, Equatable {
    public var requests: [AssistantPendingRequest]
    public var userInputs: [AssistantUserInputRequest]

    public init(requests: [AssistantPendingRequest] = [], userInputs: [AssistantUserInputRequest] = []) {
        self.requests = requests
        self.userInputs = userInputs
    }
}

public struct AssistantTokenUsage: Codable, Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var totalTokens: Int
    public var contextWindow: Int?
    public var compactsAutomatically: Bool?

    public init(inputTokens: Int = 0, outputTokens: Int = 0, totalTokens: Int = 0, contextWindow: Int? = nil, compactsAutomatically: Bool? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.contextWindow = contextWindow
        self.compactsAutomatically = compactsAutomatically
    }
}

public struct AssistantProposedPlan: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let turnId: String?
    public var markdown: String
    public var implementedAtMs: Int64?

    public init(id: String, turnId: String?, markdown: String, implementedAtMs: Int64? = nil) {
        self.id = id
        self.turnId = turnId
        self.markdown = markdown
        self.implementedAtMs = implementedAtMs
    }

    public var exportTitle: String {
        Self.exportTitle(for: markdown)
    }

    public var exportFileName: String {
        Self.exportFileName(for: markdown)
    }

    public var collapsedPreview: String {
        Self.collapsedPreview(for: markdown)
    }

    public var isImplemented: Bool {
        implementedAtMs != nil
    }

    public var showsImplementationActions: Bool {
        !isImplemented
    }

    public static func exportTitle(for markdown: String) -> String {
        let fallback = "Proposed Plan"
        for rawLine in markdown.split(whereSeparator: \.isNewline) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let stripped = trimmed
                .replacingOccurrences(of: #"^#{1,6}\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"^\d+[\.)]\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"^[-*]\s*"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !stripped.isEmpty else { continue }
            return String(stripped.prefix(80))
        }
        return fallback
    }

    public static func exportFileName(for markdown: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let title = exportTitle(for: markdown).unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(title)
            .replacingOccurrences(of: #"\s+"#, with: "-", options: .regularExpression)
            .replacingOccurrences(of: #"-+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_ "))
            .lowercased()
        return "\(collapsed.isEmpty ? "proposed-plan" : String(collapsed.prefix(64))).md"
    }

    public static func collapsedPreview(for markdown: String, maxLines: Int = 10) -> String {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count > maxLines else { return markdown }
        return lines.prefix(maxLines).joined(separator: "\n")
    }
}

public enum AssistantPlanStepStatus: String, Codable, Sendable, Equatable {
    case pending
    case inProgress = "in_progress"
    case completed
}

public struct AssistantPlanStep: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var title: String
    public var status: AssistantPlanStepStatus

    public init(id: String, title: String, status: AssistantPlanStepStatus) {
        self.id = id
        self.title = title
        self.status = status
    }
}

public struct AssistantActivePlan: Codable, Sendable, Equatable {
    public var explanation: String?
    public var steps: [AssistantPlanStep]
    public var updatedAtMs: Int64

    public init(explanation: String? = nil, steps: [AssistantPlanStep], updatedAtMs: Int64) {
        self.explanation = explanation
        self.steps = steps
        self.updatedAtMs = updatedAtMs
    }
}

public struct ProviderRuntimeEvent: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var provider: AgentProvider
    public var source: String
    public var method: String
    public var providerTurnId: String?
    public var providerItemId: String?
    public var providerRequestId: String?
    public var payloadJSON: String
    public var receivedAtMs: Int64

    public init(id: String = UUID().uuidString,
                provider: AgentProvider,
                source: String,
                method: String,
                providerTurnId: String? = nil,
                providerItemId: String? = nil,
                providerRequestId: String? = nil,
                payloadJSON: String,
                receivedAtMs: Int64) {
        self.id = id
        self.provider = provider
        self.source = source
        self.method = method
        self.providerTurnId = providerTurnId
        self.providerItemId = providerItemId
        self.providerRequestId = providerRequestId
        self.payloadJSON = payloadJSON
        self.receivedAtMs = receivedAtMs
    }

    public static func fromJSONLine(_ line: String, provider: AgentProvider, source: String, receivedAtMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> ProviderRuntimeEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = obj["type"] as? String else { return nil }
        let payloadData = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? data
        let payload = String(data: payloadData, encoding: .utf8) ?? trimmed
        let nested = obj["item"] as? [String: Any]
        let message = obj["message"] as? [String: Any]
        return ProviderRuntimeEvent(
            provider: provider,
            source: source,
            method: method,
            providerTurnId: obj["turn_id"] as? String ?? message?["id"] as? String,
            providerItemId: obj["item_id"] as? String ?? nested?["id"] as? String ?? obj["id"] as? String,
            providerRequestId: obj["request_id"] as? String,
            payloadJSON: payload,
            receivedAtMs: receivedAtMs
        )
    }
}

public enum AssistantWorkActivityKind: String, Codable, Sendable, Equatable {
    case runtime
    case tool
    case request
    case userInput
    case error
}

public struct AssistantWorkActivity: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var kind: AssistantWorkActivityKind
    public var title: String
    public var detail: String?
    public var state: String?
    public var createdAtMs: Int64

    public init(id: String,
                kind: AssistantWorkActivityKind,
                title: String,
                detail: String? = nil,
                state: String? = nil,
                createdAtMs: Int64) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.state = state
        self.createdAtMs = createdAtMs
    }
}

public enum AgentPlanImplementationPrompt {
    public static func make(markdown: String) -> String {
        """
        Implement this proposed plan now.

        Constraints:
        - Keep the implementation scoped to this plan.
        - Preserve unrelated user changes.
        - Run the smallest reliable tests that prove the change.
        - Report proof and any remaining risk.

        Proposed plan:
        \(markdown.trimmingCharacters(in: .whitespacesAndNewlines))
        """
    }
}

public enum AssistantEvent: Codable, Sendable, Equatable {
    case threadStarted(threadId: String, providerThreadId: String?)
    case turnStarted(turnId: String)
    case itemStarted(item: AssistantItem)
    case itemDelta(itemId: String, bodyAppend: String?, outputAppend: String?, summary: String?)
    case itemState(itemId: String, state: AssistantItemState)
    case itemProgress(itemId: String, progress: Double?)
    case itemCompleted(itemId: String, finalState: AssistantItemState)
    case turnCompleted(turnId: String, finalMessage: String?)
    case proposedPlan(AssistantProposedPlan)
    case activePlanUpdated(AssistantActivePlan)
    case requestOpened(AssistantPendingRequest)
    case requestResolved(requestId: String, state: AssistantRequestState)
    case userInputRequested(AssistantUserInputRequest)
    case userInputResolved(requestId: String, answer: String?)
    case tokenUsage(AssistantTokenUsage)
    case contextCompaction(summary: String?)
    case providerRuntime(ProviderRuntimeEvent)
    case error(message: String, recoverable: Bool)

    public var debugDescription: String {
        switch self {
        case .threadStarted(let t, _): return "threadStarted(\(t))"
        case .turnStarted(let t): return "turnStarted(\(t))"
        case .itemStarted(let i): return "itemStarted(\(i.id) \(i.type.rawValue))"
        case .itemDelta(let i, _, _, _): return "itemDelta(\(i))"
        case .itemState(let i, let s): return "itemState(\(i) -> \(s.rawValue))"
        case .itemProgress(let i, let p): return "itemProgress(\(i) -> \(p ?? -1))"
        case .itemCompleted(let i, let s): return "itemCompleted(\(i) -> \(s.rawValue))"
        case .turnCompleted(let t, _): return "turnCompleted(\(t))"
        case .proposedPlan(let p): return "proposedPlan(\(p.id))"
        case .activePlanUpdated(let p): return "activePlanUpdated(\(p.steps.count))"
        case .requestOpened(let r): return "requestOpened(\(r.id) \(r.kind.rawValue))"
        case .requestResolved(let r, let s): return "requestResolved(\(r) -> \(s.rawValue))"
        case .userInputRequested(let r): return "userInputRequested(\(r.id))"
        case .userInputResolved(let r, _): return "userInputResolved(\(r))"
        case .tokenUsage(let u): return "tokenUsage(\(u.totalTokens))"
        case .contextCompaction: return "contextCompaction"
        case .providerRuntime(let e): return "providerRuntime(\(e.provider.rawValue) \(e.method))"
        case .error(let m, _): return "error(\(m))"
        }
    }
}

public struct AssistantTurnSnapshot: Codable, Sendable, Equatable {
    public let turnId: String
    public var items: [AssistantItem]
    public var finalAssistantMessage: String?
    public var finished: Bool

    public init(turnId: String, items: [AssistantItem] = [], finalAssistantMessage: String? = nil, finished: Bool = false) {
        self.turnId = turnId; self.items = items; self.finalAssistantMessage = finalAssistantMessage; self.finished = finished
    }
}

public struct AssistantTimelineState: Codable, Sendable, Equatable {
    public static let liveTextLimit = 80_000
    public static let liveOutputLimit = 120_000
    public static let liveTurnLimit = 80
    public static let providerRuntimeEventLimit = 500
    public static let workActivityLimit = 120

    public var threadId: String?
    public var providerThreadId: String?
    public var turns: [AssistantTurnSnapshot]
    public var workActivities: [AssistantWorkActivity]
    public var error: String?
    public var pendingRequests: [AssistantPendingRequest]
    public var pendingUserInputs: [AssistantUserInputRequest]
    public var proposedPlans: [AssistantProposedPlan]
    public var activePlan: AssistantActivePlan?
    public var tokenUsage: AssistantTokenUsage?
    public var contextCompactionSummary: String?
    public var providerRuntimeEvents: [ProviderRuntimeEvent]
    private var pendingItemDeltas: [String: PendingItemDelta]

    private struct PendingItemDelta: Codable, Sendable, Equatable {
        var body: String = ""
        var output: String = ""
        var summary: String?
    }

    public init() {
        self.turns = []
        self.workActivities = []
        self.pendingRequests = []
        self.pendingUserInputs = []
        self.proposedPlans = []
        self.providerRuntimeEvents = []
        self.pendingItemDeltas = [:]
    }

    public var latestAssistantMessage: String? {
        for turn in turns.reversed() {
            if let final = turn.finalAssistantMessage, !final.isEmpty { return final }
            for item in turn.items.reversed()
            where item.type == .assistantMessage && !item.body.isEmpty {
                return item.body
            }
        }
        return nil
    }

    public var assistantTexts: [String] {
        turns.flatMap { turn in
            var texts = turn.items.compactMap { item -> String? in
                guard item.type == .assistantMessage, !item.body.isEmpty else { return nil }
                return item.body
            }
            if let final = turn.finalAssistantMessage, !final.isEmpty {
                texts.append(final)
            }
            return texts
        }
    }

    public mutating func apply(_ ev: AssistantEvent) {
        switch ev {
        case .threadStarted(let tid, let ptid):
            self.threadId = tid; self.providerThreadId = ptid
        case .turnStarted(let tid):
            turns.append(AssistantTurnSnapshot(turnId: tid))
            trimTurns()
        case .itemStarted(let item):
            ensureTurn(item.turnId)
            if let idx = turns.firstIndex(where: { $0.turnId == item.turnId }) {
                let pending = pendingItemDeltas.removeValue(forKey: item.id)
                if let itemIndex = turns[idx].items.firstIndex(where: { $0.id == item.id }) {
                    let existing = turns[idx].items[itemIndex]
                    var merged = item
                    if merged.body.isEmpty { merged.body = existing.body }
                    if merged.output == nil { merged.output = existing.output }
                    if merged.progress == nil { merged.progress = existing.progress }
                    if merged.summary == nil { merged.summary = existing.summary }
                    if merged.finishedAtMs == nil { merged.finishedAtMs = existing.finishedAtMs }
                    if merged.state == .streaming, existing.state != .streaming { merged.state = existing.state }
                    applyPendingDelta(pending, to: &merged)
                    turns[idx].items[itemIndex] = merged
                } else {
                    var started = item
                    applyPendingDelta(pending, to: &started)
                    turns[idx].items.append(started)
                }
            }
            if let recorded = self.item(withId: item.id) {
                recordActivity(for: recorded, state: recorded.state)
            }
        case .itemDelta(let iid, let bodyAppend, let outputAppend, let summary):
            let applied = mutateItem(iid) { item in
                if let b = bodyAppend {
                    item.body = Self.cappedText(item.body + b, limit: Self.liveTextLimit)
                }
                if let o = outputAppend {
                    item.output = Self.cappedText((item.output ?? "") + o, limit: Self.liveOutputLimit)
                }
                if let s = summary { item.summary = s }
            }
            if !applied {
                var pending = pendingItemDeltas[iid] ?? PendingItemDelta()
                if let b = bodyAppend {
                    pending.body = Self.cappedText(pending.body + b, limit: Self.liveTextLimit)
                }
                if let o = outputAppend {
                    pending.output = Self.cappedText(pending.output + o, limit: Self.liveOutputLimit)
                }
                if let s = summary { pending.summary = s }
                pendingItemDeltas[iid] = pending
            }
        case .itemState(let iid, let state):
            mutateItem(iid) { $0.state = state }
        case .itemProgress(let iid, let progress):
            mutateItem(iid) { $0.progress = progress.map(Self.normalizedProgress) }
            if let item = item(withId: iid) {
                recordActivity(for: item, state: item.state)
            }
        case .itemCompleted(let iid, let state):
            mutateItem(iid) { item in
                item.state = state
                item.finishedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
            }
            if let item = item(withId: iid) {
                recordActivity(for: item, state: state)
            }
        case .turnCompleted(let tid, let final):
            if let idx = turns.firstIndex(where: { $0.turnId == tid }) {
                turns[idx].finalAssistantMessage = final.map { Self.cappedText($0, limit: Self.liveTextLimit) }
                turns[idx].finished = true
            }
        case .proposedPlan(let plan):
            proposedPlans.removeAll { $0.id == plan.id }
            proposedPlans.append(plan)
        case .activePlanUpdated(let plan):
            activePlan = plan
        case .requestOpened(let request):
            pendingRequests.removeAll { $0.id == request.id }
            pendingRequests.append(request)
            recordActivity(AssistantWorkActivity(
                id: "request:\(request.id)",
                kind: .request,
                title: "Approval requested: \(request.title)",
                detail: request.detail,
                state: request.state.rawValue,
                createdAtMs: request.createdAtMs
            ))
        case .requestResolved(let requestId, let state):
            if let idx = pendingRequests.firstIndex(where: { $0.id == requestId }) {
                pendingRequests[idx].state = state
                pendingRequests[idx].resolvedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
                let request = pendingRequests[idx]
                recordActivity(AssistantWorkActivity(
                    id: "request:\(request.id)",
                    kind: .request,
                    title: "Approval \(state.rawValue): \(request.title)",
                    detail: request.detail,
                    state: state.rawValue,
                    createdAtMs: request.resolvedAtMs ?? request.createdAtMs
                ))
            }
        case .userInputRequested(let request):
            pendingUserInputs.removeAll { $0.id == request.id }
            pendingUserInputs.append(request)
            recordActivity(AssistantWorkActivity(
                id: "user_input:\(request.id)",
                kind: .userInput,
                title: "Question requested",
                detail: request.prompt,
                state: request.state.rawValue,
                createdAtMs: request.createdAtMs
            ))
        case .userInputResolved(let requestId, let answer):
            if let idx = pendingUserInputs.firstIndex(where: { $0.id == requestId }) {
                pendingUserInputs[idx].answer = answer
                pendingUserInputs[idx].state = .resolved
                pendingUserInputs[idx].resolvedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
                let request = pendingUserInputs[idx]
                recordActivity(AssistantWorkActivity(
                    id: "user_input:\(request.id)",
                    kind: .userInput,
                    title: "Question resolved",
                    detail: answer ?? request.prompt,
                    state: AssistantRequestState.resolved.rawValue,
                    createdAtMs: request.resolvedAtMs ?? request.createdAtMs
                ))
            }
        case .tokenUsage(let usage):
            tokenUsage = usage
        case .contextCompaction(let summary):
            contextCompactionSummary = summary
        case .providerRuntime(let event):
            providerRuntimeEvents.append(event)
            if providerRuntimeEvents.count > Self.providerRuntimeEventLimit {
                providerRuntimeEvents.removeFirst(providerRuntimeEvents.count - Self.providerRuntimeEventLimit)
            }
            recordActivity(AssistantWorkActivity(
                id: "runtime:\(event.id)",
                kind: .runtime,
                title: "\(event.provider.rawValue) runtime: \(event.method)",
                detail: event.source,
                state: nil,
                createdAtMs: event.receivedAtMs
            ))
        case .error(let m, _):
            self.error = m
            recordActivity(AssistantWorkActivity(
                id: "error:\(UUID().uuidString)",
                kind: .error,
                title: "Agent error",
                detail: m,
                state: "failed",
                createdAtMs: Int64(Date().timeIntervalSince1970 * 1000)
            ))
        }
    }

    private mutating func ensureTurn(_ tid: String) {
        if turns.firstIndex(where: { $0.turnId == tid }) == nil {
            turns.append(AssistantTurnSnapshot(turnId: tid))
            trimTurns()
        }
    }

    private mutating func trimTurns() {
        guard turns.count > Self.liveTurnLimit else { return }
        turns = Array(turns.suffix(Self.liveTurnLimit))
    }

    @discardableResult
    private mutating func mutateItem(_ iid: String, _ mut: (inout AssistantItem) -> Void) -> Bool {
        for ti in turns.indices {
            for ii in turns[ti].items.indices where turns[ti].items[ii].id == iid {
                mut(&turns[ti].items[ii])
                return true
            }
        }
        return false
    }

    private func applyPendingDelta(_ pending: PendingItemDelta?, to item: inout AssistantItem) {
        guard let pending else { return }
        if !pending.body.isEmpty {
            item.body = Self.cappedText(item.body + pending.body, limit: Self.liveTextLimit)
        }
        if !pending.output.isEmpty {
            item.output = Self.cappedText((item.output ?? "") + pending.output, limit: Self.liveOutputLimit)
        }
        if let summary = pending.summary {
            item.summary = summary
        }
    }

    private func item(withId iid: String) -> AssistantItem? {
        for turn in turns {
            if let item = turn.items.first(where: { $0.id == iid }) {
                return item
            }
        }
        return nil
    }

    private mutating func recordActivity(for item: AssistantItem, state: AssistantItemState) {
        guard item.type != .assistantMessage, item.type != .reasoning, item.type != .plan else { return }
        recordActivity(AssistantWorkActivity(
            id: "item:\(item.id)",
            kind: .tool,
            title: "\(state == .streaming ? "Running" : state.rawValue.capitalized): \(Self.activityLabel(for: item))",
            detail: item.output ?? item.body,
            state: state.rawValue,
            createdAtMs: item.finishedAtMs ?? item.startedAtMs
        ))
    }

    private mutating func recordActivity(_ activity: AssistantWorkActivity) {
        var next = activity
        next.title = Self.cappedText(next.title, limit: 240)
        next.detail = next.detail.map { Self.cappedText($0, limit: 1_000) }
        workActivities.removeAll { $0.id == activity.id }
        workActivities.append(next)
        if workActivities.count > Self.workActivityLimit {
            workActivities.removeFirst(workActivities.count - Self.workActivityLimit)
        }
    }

    private static func activityLabel(for item: AssistantItem) -> String {
        if let progress = item.progress {
            let percent = Int((normalizedProgress(progress) * 100).rounded())
            return "\(percent)% \(baseActivityLabel(for: item))"
        }
        return baseActivityLabel(for: item)
    }

    private static func baseActivityLabel(for item: AssistantItem) -> String {
        if let summary = item.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            return summary.replacingOccurrences(of: "\n", with: " ")
        }
        let body = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { return body.replacingOccurrences(of: "\n", with: " ") }
        return item.type.rawValue
    }

    public static func normalizedProgress(_ value: Double) -> Double {
        if value > 1 { return min(1, max(0, value / 100)) }
        return min(1, max(0, value))
    }

    public static func cappedText(_ value: String, limit: Int = liveTextLimit) -> String {
        guard value.count > limit else { return value }
        return String(value.suffix(limit))
    }
}
