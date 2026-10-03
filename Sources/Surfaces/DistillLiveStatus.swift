import Foundation
import CoreModel

/// Live Distill ACP status (compaction, model, subagents) folded from
/// `providerRuntime` events so the running strip can mirror the Distill TUI.
/// Pure value type: only runtime events touch it, never per-token events.
public struct DistillLiveStatus: Equatable, Sendable {
    public struct Subagent: Equatable, Sendable, Identifiable {
        public var id: String
        public var childSessionId: String?
        public var type: String
        public var description: String
        public var model: String?
        public var effort: String?
        public var tokensUsed: Int
        public var durationMs: Int
        public var receivedAt: Date
        public var compactingSince: Date?
        /// `completed` / `failed` / `cancelled` once the subagent ended.
        public var finishedStatus: String?

        public var isActive: Bool { finishedStatus == nil }
        public var isCompacting: Bool { isActive && compactingSince != nil }

        /// "general-purpose" → "General", "explore" → "Explore".
        public var typeLabel: String {
            let first = type.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " }).first.map(String.init) ?? type
            guard let head = first.first else { return "Agent" }
            return head.uppercased() + first.dropFirst()
        }

        public var phaseText: String {
            switch finishedStatus {
            case nil: return isCompacting ? "Compacting" : "Running"
            case "completed": return "Done"
            case "failed": return "Failed"
            case "cancelled": return "Cancelled"
            default: return "Done"
            }
        }

        /// Model without its provider prefix ("meta/muse-spark" → "muse-spark").
        public var shortModel: String? {
            guard let model, !model.isEmpty else { return nil }
            return model.split(separator: "/").last.map(String.init) ?? model
        }

        public func elapsedSeconds(now: Date) -> Int {
            let base = max(0, durationMs) / 1000
            guard isActive else { return base }
            return base + max(0, Int(now.timeIntervalSince(receivedAt)))
        }
    }

    public static let maxSubagents = 50

    /// Run these events belong to; the owner resets the value when it changes.
    public var runId: AgentRunID?
    public var mainCompactingSince: Date?
    public var model: String?
    public var effort: String?
    public var subagents: [Subagent] = []

    public init(runId: AgentRunID? = nil) {
        self.runId = runId
    }

    public var compactingSubagent: Subagent? {
        subagents.last(where: { $0.isCompacting })
    }

    /// "Subagent (<description>): Compacting…" / "Compacting…" / nil (keep existing copy).
    public var headline: String? {
        if let sub = compactingSubagent { return "Subagent (\(sub.description)): Compacting…" }
        if mainCompactingSince != nil { return "Compacting…" }
        return nil
    }

    /// Start of the compaction the headline describes.
    public var headlineSince: Date? {
        compactingSubagent?.compactingSince ?? mainCompactingSince
    }

    /// "<model> <effort>" of whoever the headline describes (else the main agent).
    public var modelEffortText: String? {
        let sub = compactingSubagent
        let name = sub != nil ? sub?.model : model
        let level = sub != nil ? sub?.effort : effort
        let text = [name, level].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        return text.isEmpty ? nil : text
    }

    public var isEmpty: Bool {
        headline == nil && modelEffortText == nil && subagents.isEmpty
    }

    /// 135000 → "135k", 1500 → "1.5k", 950 → "950".
    public static func formatTokens(_ n: Int) -> String {
        func scaled(_ value: Double, _ suffix: String) -> String {
            let rounded = (value * 10).rounded() / 10
            return rounded == rounded.rounded()
                ? "\(Int(rounded))\(suffix)"
                : String(format: "%.1f%@", rounded, suffix)
        }
        if n < 1_000 { return "\(max(0, n))" }
        if n < 10_000 { return scaled(Double(n) / 1_000, "k") }
        if n < 1_000_000 { return "\(n / 1_000)k" }
        return scaled(Double(n) / 1_000_000, "M")
    }

    private static let kinds: [String] = [
        "auto_compact_", "subagent_", "model_changed"
    ]

    public static func isCarrierMethod(_ method: String) -> Bool {
        method == "x.ai/session_notification" || method == "x.ai/session/update"
            || method == "_x.ai/session_notification" || method == "_x.ai/session/update"
            || kinds.contains(where: { method.hasPrefix($0) })
    }

    /// Fold one Distill runtime event. Unrelated methods/kinds are ignored.
    public mutating func apply(method: String, payloadJSON: String, receivedAt: Date = Date()) {
        guard Self.isCarrierMethod(method),
              let data = payloadJSON.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        let update: [String: Any]
        if let nested = payload["update"] as? [String: Any] {
            update = nested
        } else if payload["sessionUpdate"] != nil {
            update = payload
        } else {
            // Plain ACP kind carried as the method name with fields at the root.
            var rebuilt = payload
            rebuilt["sessionUpdate"] = method
            update = rebuilt
        }
        let sessionId = payload["sessionId"] as? String ?? update["sessionId"] as? String
        guard let kind = update["sessionUpdate"] as? String else { return }

        switch kind {
        case "auto_compact_started":
            setCompacting(sessionId: sessionId, since: receivedAt)
        case "auto_compact_completed", "auto_compact_failed", "auto_compact_cancelled":
            setCompacting(sessionId: sessionId, since: nil)
        case "subagent_spawned":
            guard let id = Self.string(update["subagent_id"]) ?? Self.string(update["child_session_id"]) else { return }
            var sub = subagent(id: id, receivedAt: receivedAt)
            sub.childSessionId = Self.string(update["child_session_id"]) ?? sub.childSessionId
            sub.type = Self.string(update["subagent_type"]) ?? sub.type
            sub.description = Self.string(update["description"]) ?? sub.description
            sub.model = Self.string(update["model"]) ?? sub.model
            sub.receivedAt = receivedAt
            store(sub)
        case "subagent_progress":
            guard let id = Self.string(update["subagent_id"]) ?? Self.string(update["child_session_id"]) else { return }
            var sub = subagent(id: id, receivedAt: receivedAt)
            sub.childSessionId = Self.string(update["child_session_id"]) ?? sub.childSessionId
            sub.durationMs = Self.int(update["duration_ms"]) ?? sub.durationMs
            sub.tokensUsed = Self.int(update["tokens_used"]) ?? sub.tokensUsed
            sub.model = Self.string(update["active_model"]) ?? sub.model
            sub.effort = Self.string(update["active_reasoning_effort"]) ?? sub.effort
            sub.receivedAt = receivedAt
            store(sub)
        case "subagent_finished":
            guard let id = Self.string(update["subagent_id"]) ?? Self.string(update["child_session_id"]) else { return }
            var sub = subagent(id: id, receivedAt: receivedAt)
            sub.finishedStatus = Self.string(update["status"]) ?? "completed"
            sub.durationMs = Self.int(update["duration_ms"]) ?? sub.durationMs
            sub.tokensUsed = Self.int(update["tokens_used"]) ?? sub.tokensUsed
            sub.compactingSince = nil
            store(sub)
        case "model_changed":
            model = Self.string(update["model_id"]) ?? model
            effort = Self.string(update["reasoning_effort"]) ?? effort
        default:
            break
        }
    }

    private mutating func setCompacting(sessionId: String?, since: Date?) {
        if let sessionId,
           let index = subagents.firstIndex(where: { $0.childSessionId == sessionId }) {
            subagents[index].compactingSince = since
        } else {
            mainCompactingSince = since
        }
    }

    private func subagent(id: String, receivedAt: Date) -> Subagent {
        subagents.first(where: { $0.id == id }) ?? Subagent(
            id: id,
            childSessionId: nil,
            type: "agent",
            description: "",
            model: nil,
            effort: nil,
            tokensUsed: 0,
            durationMs: 0,
            receivedAt: receivedAt,
            compactingSince: nil,
            finishedStatus: nil
        )
    }

    private mutating func store(_ sub: Subagent) {
        if let index = subagents.firstIndex(where: { $0.id == sub.id }) {
            subagents[index] = sub
        } else {
            subagents.append(sub)
            if subagents.count > Self.maxSubagents { subagents.removeFirst() }
        }
    }

    private static func string(_ value: Any?) -> String? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        return s
    }

    private static func int(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let d = value as? Double, d.isFinite { return Int(d) }
        return nil
    }
}
