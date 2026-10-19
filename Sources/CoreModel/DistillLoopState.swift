import Foundation

public enum DistillLoopStatus: String, Codable, Equatable, Sendable {
    case active
    case paused
    case expired
    case stopped
}

public enum DistillLoopIterationStatus: String, Codable, Equatable, Sendable {
    case running
    case completed
    case failed
    case cancelled
}

public struct DistillLoopIteration: Codable, Equatable, Sendable {
    public static let outputPreviewLimit = 280

    public var subagentID: String
    public var status: DistillLoopIterationStatus
    public var durationMs: Int?
    public var tokensUsed: Int?
    public var outputPreview: String?

    public init(
        subagentID: String,
        status: DistillLoopIterationStatus,
        durationMs: Int? = nil,
        tokensUsed: Int? = nil,
        outputPreview: String? = nil
    ) {
        self.subagentID = subagentID
        self.status = status
        self.durationMs = durationMs
        self.tokensUsed = tokensUsed
        self.outputPreview = outputPreview.map { String($0.prefix(Self.outputPreviewLimit)) }
    }

    enum CodingKeys: String, CodingKey {
        case subagentID = "subagent_id"
        case status
        case durationMs = "duration_ms"
        case tokensUsed = "tokens_used"
        case outputPreview = "output_preview"
    }
}

/// Per-thread state of one Distill `/loop` scheduled task, folded from ACP scheduler notifications.
public struct DistillLoopState: Codable, Equatable, Sendable {
    public var taskID: String
    public var prompt: String
    public var humanSchedule: String
    public var nextFireAt: Date?
    public var iterations: Int
    public var lastIteration: DistillLoopIteration?
    public var runningSubagentID: String?
    public var state: DistillLoopStatus
    public var pausedReason: String?
    public var schedulerRevision: Int

    public init(
        taskID: String,
        prompt: String,
        humanSchedule: String,
        nextFireAt: Date? = nil,
        iterations: Int = 0,
        lastIteration: DistillLoopIteration? = nil,
        runningSubagentID: String? = nil,
        state: DistillLoopStatus = .active,
        pausedReason: String? = nil,
        schedulerRevision: Int = 0
    ) {
        self.taskID = taskID
        self.prompt = prompt
        self.humanSchedule = humanSchedule
        self.nextFireAt = nextFireAt
        self.iterations = iterations
        self.lastIteration = lastIteration
        self.runningSubagentID = runningSubagentID
        self.state = state
        self.pausedReason = pausedReason
        self.schedulerRevision = schedulerRevision
    }

    enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case prompt
        case humanSchedule = "human_schedule"
        case nextFireAt = "next_fire_at"
        case iterations
        case lastIteration = "last_iteration"
        case runningSubagentID = "running_subagent_id"
        case state
        case pausedReason = "paused_reason"
        case schedulerRevision = "scheduler_revision"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        taskID = try c.decode(String.self, forKey: .taskID)
        prompt = try c.decode(String.self, forKey: .prompt)
        humanSchedule = try c.decode(String.self, forKey: .humanSchedule)
        if let raw = try c.decodeIfPresent(String.self, forKey: .nextFireAt) {
            guard let date = DistillLoopDate.parse(raw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .nextFireAt, in: c, debugDescription: "Invalid ISO8601 date: \(raw)")
            }
            nextFireAt = date
        } else {
            nextFireAt = nil
        }
        iterations = try c.decodeIfPresent(Int.self, forKey: .iterations) ?? 0
        lastIteration = try c.decodeIfPresent(DistillLoopIteration.self, forKey: .lastIteration)
        runningSubagentID = try c.decodeIfPresent(String.self, forKey: .runningSubagentID)
        state = try c.decodeIfPresent(DistillLoopStatus.self, forKey: .state) ?? .active
        pausedReason = try c.decodeIfPresent(String.self, forKey: .pausedReason)
        schedulerRevision = try c.decodeIfPresent(Int.self, forKey: .schedulerRevision) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(taskID, forKey: .taskID)
        try c.encode(prompt, forKey: .prompt)
        try c.encode(humanSchedule, forKey: .humanSchedule)
        try c.encodeIfPresent(nextFireAt.map(DistillLoopDate.format), forKey: .nextFireAt)
        try c.encode(iterations, forKey: .iterations)
        try c.encodeIfPresent(lastIteration, forKey: .lastIteration)
        try c.encodeIfPresent(runningSubagentID, forKey: .runningSubagentID)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(pausedReason, forKey: .pausedReason)
        try c.encode(schedulerRevision, forKey: .schedulerRevision)
    }
}

enum DistillLoopDate {
    static func parse(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }

    static func format(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}

/// Loop list plus the reducer's dedupe memory: deleted task ids keep their revision so a
/// stale `created`/`fired` that arrives after the deletion cannot resurrect the loop.
public struct DistillLoopLedger: Equatable, Sendable {
    public var loops: [DistillLoopState]
    public var tombstones: [String: Int]
    public var maxRevision: Int

    public init(loops: [DistillLoopState] = [], tombstones: [String: Int] = [:], maxRevision: Int? = nil) {
        self.loops = loops
        self.tombstones = tombstones
        self.maxRevision = maxRevision ?? (loops.map(\.schedulerRevision).max() ?? 0)
    }
}

/// Folds Distill ACP scheduler notifications into per-thread loop state.
public enum DistillLoopReducer {
    public static let shutdownPausedReason = "MacCode restarted the agent; resuming…"
    private static let wakePromptPrefix = "subagent-completed-"
    private static let revisionKey = "x.ai/schedulerRevision"

    /// Subagent id for a wake-turn prompt id (`subagent-completed-<id>`), else nil.
    public static func isWakePromptID(_ promptID: String) -> String? {
        guard promptID.hasPrefix(wakePromptPrefix) else { return nil }
        let id = String(promptID.dropFirst(wakePromptPrefix.count))
        return id.isEmpty ? nil : id
    }

    /// Stateless form: tombstones are not remembered across calls.
    public static func apply(
        method: String,
        params: [String: Any],
        to loops: [DistillLoopState]
    ) -> [DistillLoopState] {
        apply(method: method, params: params, to: DistillLoopLedger(loops: loops)).loops
    }

    public static func apply(
        method: String,
        params: [String: Any],
        to ledger: DistillLoopLedger
    ) -> DistillLoopLedger {
        let name = method.hasPrefix("_") ? String(method.dropFirst()) : method
        guard let update = params["update"] as? [String: Any] else { return ledger }
        let revision = ((params["_meta"] as? [String: Any])?[revisionKey] as? NSNumber)?.intValue
        switch name {
        case "x.ai/scheduled_task_created":
            return created(update, revision: revision, ledger)
        case "x.ai/scheduled_task_fired":
            return fired(update, revision: revision, ledger)
        case "x.ai/scheduled_task_deleted":
            return deleted(update, revision: revision, ledger)
        case "x.ai/session_notification":
            guard update["sessionUpdate"] as? String == "subagent_finished" else { return ledger }
            var out = ledger
            out.loops = finished(update, ledger.loops)
            return out
        default:
            return ledger
        }
    }

    /// A tombstoned task only comes back with a strictly newer revision.
    private static func isResurrectionBlocked(_ taskID: String, revision: Int?, _ ledger: DistillLoopLedger) -> Bool {
        guard let mark = ledger.tombstones[taskID] else { return false }
        guard let revision else { return true }
        return revision <= mark
    }

    private static func created(_ u: [String: Any], revision: Int?, _ ledger: DistillLoopLedger) -> DistillLoopLedger {
        guard let taskID = u["task_id"] as? String else { return ledger }
        if isResurrectionBlocked(taskID, revision: revision, ledger) { return ledger }
        var out = ledger
        out.tombstones.removeValue(forKey: taskID)
        let index = out.loops.firstIndex { $0.taskID == taskID }
        // A paused loop re-announced after a restart may carry a restarted revision counter.
        let reannounce = index.map { out.loops[$0].state == .paused } ?? false
        if let revision, !reannounce, revision <= ledger.maxRevision { return ledger }
        if let index {
            // Same task id: keep iterations and last iteration (history survives re-announce).
            apply(schedule: u, to: &out.loops[index])
            out.loops[index].state = .active
            out.loops[index].pausedReason = nil
            out.loops[index].schedulerRevision = revision ?? out.loops[index].schedulerRevision
        } else {
            var loop = DistillLoopState(taskID: taskID, prompt: "", humanSchedule: "", schedulerRevision: revision ?? 0)
            apply(schedule: u, to: &loop)
            out.loops.append(loop)
        }
        if reannounce {
            out.maxRevision = out.loops.map(\.schedulerRevision).max() ?? 0
        } else if let revision {
            out.maxRevision = max(out.maxRevision, revision)
        }
        return out
    }

    private static func fired(_ u: [String: Any], revision: Int?, _ ledger: DistillLoopLedger) -> DistillLoopLedger {
        guard let taskID = u["task_id"] as? String else { return ledger }
        if isResurrectionBlocked(taskID, revision: revision, ledger) { return ledger }
        var out = ledger
        out.tombstones.removeValue(forKey: taskID)
        let index: Int
        if let found = out.loops.firstIndex(where: { $0.taskID == taskID }) {
            if let revision, revision <= out.loops[found].schedulerRevision { return ledger }
            index = found
        } else {
            out.loops.append(DistillLoopState(taskID: taskID, prompt: "", humanSchedule: ""))
            index = out.loops.count - 1
        }
        apply(schedule: u, to: &out.loops[index])
        out.loops[index].state = .active
        out.loops[index].pausedReason = nil
        out.loops[index].iterations += 1
        if let subagentID = u["subagent_id"] as? String {
            out.loops[index].runningSubagentID = subagentID
            out.loops[index].lastIteration = DistillLoopIteration(subagentID: subagentID, status: .running)
        }
        if let revision {
            out.loops[index].schedulerRevision = revision
            out.maxRevision = max(out.maxRevision, revision)
        }
        return out
    }

    private static func deleted(_ u: [String: Any], revision: Int?, _ ledger: DistillLoopLedger) -> DistillLoopLedger {
        guard let taskID = u["task_id"] as? String else { return ledger }
        let reason = u["reason"] as? String
        let index = ledger.loops.firstIndex(where: { $0.taskID == taskID })
        if let index, let revision, revision <= ledger.loops[index].schedulerRevision { return ledger }
        var out = ledger
        switch reason {
        case "shutdown":
            guard let index else { return ledger }
            out.loops[index].state = .paused
            out.loops[index].pausedReason = shutdownPausedReason
            out.loops[index].nextFireAt = nil
            if let revision { out.loops[index].schedulerRevision = revision }
        case "expired":
            guard let index else { return ledger }
            out.loops[index].state = .expired
            out.loops[index].pausedReason = nil
            out.loops[index].nextFireAt = nil
            if let revision { out.loops[index].schedulerRevision = revision }
        default:
            // Delete may overtake its `created`: remember it even when the loop is unknown.
            let mark = revision ?? max(index.map { ledger.loops[$0].schedulerRevision } ?? 0, ledger.maxRevision)
            out.tombstones[taskID] = max(mark, out.tombstones[taskID] ?? 0)
            if let index { out.loops.remove(at: index) }
        }
        if let revision { out.maxRevision = max(out.maxRevision, revision) }
        return out
    }

    private static func finished(_ u: [String: Any], _ loops: [DistillLoopState]) -> [DistillLoopState] {
        guard let subagentID = u["subagent_id"] as? String,
              let index = loops.firstIndex(where: {
                  $0.runningSubagentID == subagentID || $0.lastIteration?.subagentID == subagentID
              }) else { return loops }
        var out = loops
        let status: DistillLoopIterationStatus
        switch u["status"] as? String {
        case "completed": status = .completed
        case "cancelled", "canceled": status = .cancelled
        default: status = .failed
        }
        let output = (u["output"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        out[index].lastIteration = DistillLoopIteration(
            subagentID: subagentID,
            status: status,
            durationMs: (u["duration_ms"] as? NSNumber)?.intValue,
            tokensUsed: (u["tokens_used"] as? NSNumber)?.intValue,
            outputPreview: output?.isEmpty == false ? output : nil
        )
        if out[index].runningSubagentID == subagentID { out[index].runningSubagentID = nil }
        return out
    }

    private static func apply(schedule u: [String: Any], to loop: inout DistillLoopState) {
        if let prompt = u["prompt"] as? String { loop.prompt = prompt }
        if let schedule = u["human_schedule"] as? String { loop.humanSchedule = schedule }
        loop.nextFireAt = (u["next_fire_at"] as? String).flatMap(DistillLoopDate.parse)
    }
}
