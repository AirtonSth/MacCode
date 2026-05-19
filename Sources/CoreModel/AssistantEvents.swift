import Foundation

public enum AssistantItemType: String, Codable, Sendable {
    case reasoning
    case plan
    case tool
    case assistantMessage
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
    public var startedAtMs: Int64
    public var finishedAtMs: Int64?

    public init(id: String, turnId: String, type: AssistantItemType, state: AssistantItemState = .streaming, summary: String? = nil, body: String = "", output: String? = nil, startedAtMs: Int64, finishedAtMs: Int64? = nil) {
        self.id = id; self.turnId = turnId; self.type = type; self.state = state
        self.summary = summary; self.body = body; self.output = output
        self.startedAtMs = startedAtMs; self.finishedAtMs = finishedAtMs
    }
}

public enum AssistantEvent: Codable, Sendable, Equatable {
    case threadStarted(threadId: String, providerThreadId: String?)
    case turnStarted(turnId: String)
    case itemStarted(item: AssistantItem)
    case itemDelta(itemId: String, bodyAppend: String?, outputAppend: String?, summary: String?)
    case itemState(itemId: String, state: AssistantItemState)
    case itemCompleted(itemId: String, finalState: AssistantItemState)
    case turnCompleted(turnId: String, finalMessage: String?)
    case error(message: String, recoverable: Bool)

    public var debugDescription: String {
        switch self {
        case .threadStarted(let t, _): return "threadStarted(\(t))"
        case .turnStarted(let t): return "turnStarted(\(t))"
        case .itemStarted(let i): return "itemStarted(\(i.id) \(i.type.rawValue))"
        case .itemDelta(let i, _, _, _): return "itemDelta(\(i))"
        case .itemState(let i, let s): return "itemState(\(i) -> \(s.rawValue))"
        case .itemCompleted(let i, let s): return "itemCompleted(\(i) -> \(s.rawValue))"
        case .turnCompleted(let t, _): return "turnCompleted(\(t))"
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

    public var threadId: String?
    public var providerThreadId: String?
    public var turns: [AssistantTurnSnapshot]
    public var error: String?

    public init() { self.turns = [] }

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
        case .itemStarted(let item):
            ensureTurn(item.turnId)
            if let idx = turns.firstIndex(where: { $0.turnId == item.turnId }) {
                turns[idx].items.append(item)
            }
        case .itemDelta(let iid, let bodyAppend, let outputAppend, let summary):
            mutateItem(iid) { item in
                if let b = bodyAppend {
                    item.body = Self.cappedText(item.body + b, limit: Self.liveTextLimit)
                }
                if let o = outputAppend {
                    item.output = Self.cappedText((item.output ?? "") + o, limit: Self.liveOutputLimit)
                }
                if let s = summary { item.summary = s }
            }
        case .itemState(let iid, let state):
            mutateItem(iid) { $0.state = state }
        case .itemCompleted(let iid, let state):
            mutateItem(iid) { item in
                item.state = state
                item.finishedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
            }
        case .turnCompleted(let tid, let final):
            if let idx = turns.firstIndex(where: { $0.turnId == tid }) {
                turns[idx].finalAssistantMessage = final.map { Self.cappedText($0, limit: Self.liveTextLimit) }
                turns[idx].finished = true
            }
        case .error(let m, _):
            self.error = m
        }
    }

    private mutating func ensureTurn(_ tid: String) {
        if turns.firstIndex(where: { $0.turnId == tid }) == nil {
            turns.append(AssistantTurnSnapshot(turnId: tid))
        }
    }

    private mutating func mutateItem(_ iid: String, _ mut: (inout AssistantItem) -> Void) {
        for ti in turns.indices {
            for ii in turns[ti].items.indices where turns[ti].items[ii].id == iid {
                mut(&turns[ti].items[ii])
                return
            }
        }
    }

    public static func cappedText(_ value: String, limit: Int = liveTextLimit) -> String {
        guard value.count > limit else { return value }
        return String(value.suffix(limit))
    }
}
