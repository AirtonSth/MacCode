import Foundation
import CoreModel

enum ProviderNativeSubagentPhase: Equatable {
    case active
    case completed
    case failed
    case cancelled
    case unknown
}

struct ProviderNativeSubagentUpdate: Equatable {
    let childRunId: AgentRunID
    let provider: AgentProvider
    let phase: ProviderNativeSubagentPhase

    var nodeId: String {
        "native.\(provider.rawValue).\(childRunId.value.uuidString.lowercased())"
    }
}

/// Converts provider-owned child lifecycle notifications into the same
/// content-free identity/status contract used by nested provider CLI receipts.
enum ProviderNativeSubagentLifecycle {
    private static let codexCollaborationTools = Set([
        "spawnagent", "wait", "sendinput", "closeagent",
    ])

    /// Cheap event-shape guard for the coordinator's event hot path. It avoids
    /// repository reads for ordinary text/tool/token events while leaving exact
    /// parsing and provider validation to `updates`.
    static func isPotentialLifecycleEvent(_ event: AssistantEvent) -> Bool {
        switch event {
        case .providerRuntime(let runtimeEvent):
            return runtimeEvent.provider == .grok
                && (runtimeEvent.method == "_x.ai/session_notification"
                    || runtimeEvent.method == "_x.ai/session/update")
        case .itemDelta(_, _, let outputAppend, let summary):
            guard outputAppend != nil, let summary else { return false }
            return codexCollaborationTools.contains(summary.lowercased())
        default:
            return false
        }
    }

    static func updates(
        from event: AssistantEvent,
        parentProvider: AgentProvider
    ) -> [ProviderNativeSubagentUpdate] {
        switch event {
        case .providerRuntime(let runtimeEvent):
            return grokUpdates(from: runtimeEvent)
        case .itemDelta(_, _, let outputAppend, let summary):
            guard parentProvider == .codex,
                  let outputAppend,
                  let summary,
                  codexCollaborationTools.contains(summary.lowercased()) else {
                return []
            }
            return codexUpdates(from: outputAppend)
        default:
            return []
        }
    }

    private static func grokUpdates(
        from event: ProviderRuntimeEvent
    ) -> [ProviderNativeSubagentUpdate] {
        guard event.provider == .grok,
              event.method == "_x.ai/session_notification"
                || event.method == "_x.ai/session/update",
              let data = event.payloadJSON.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        let update = (payload["update"] as? [String: Any]) ?? payload
        guard let kind = update["sessionUpdate"] as? String,
              kind == "subagent_spawned"
                || kind == "subagent_progress"
                || kind == "subagent_finished",
              let childID = uuid(
                update["child_session_id"] as? String
                    ?? update["subagent_id"] as? String
              ) else {
            return []
        }

        let phase: ProviderNativeSubagentPhase
        switch kind {
        case "subagent_spawned", "subagent_progress":
            phase = .active
        case "subagent_finished":
            phase = terminalPhase(update["status"] as? String)
        default:
            return []
        }
        return [ProviderNativeSubagentUpdate(
            childRunId: AgentRunID(childID),
            provider: .grok,
            phase: phase
        )]
    }

    private static func codexUpdates(from output: String) -> [ProviderNativeSubagentUpdate] {
        guard let data = output.data(using: .utf8),
              let states = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        return states.compactMap { childID, rawState in
            guard let childUUID = uuid(childID),
                  let state = rawState as? [String: Any],
                  let status = state["status"] as? String,
                  let phase = codexPhase(status) else {
                return nil
            }
            return ProviderNativeSubagentUpdate(
                childRunId: AgentRunID(childUUID),
                provider: .codex,
                phase: phase
            )
        }
        .sorted {
            $0.childRunId.value.uuidString < $1.childRunId.value.uuidString
        }
    }

    private static func codexPhase(_ status: String) -> ProviderNativeSubagentPhase? {
        switch status.lowercased() {
        case "pendinginit", "running":
            return .active
        case "completed", "succeeded", "success":
            return .completed
        case "failed", "error":
            return .failed
        case "cancelled", "canceled", "interrupted":
            return .cancelled
        case "notfound":
            return .unknown
        default:
            return nil
        }
    }

    private static func terminalPhase(_ status: String?) -> ProviderNativeSubagentPhase {
        switch status?.lowercased() {
        case "completed", "succeeded", "success":
            return .completed
        case "failed", "error":
            return .failed
        case "cancelled", "canceled", "interrupted":
            return .cancelled
        default:
            return .unknown
        }
    }

    private static func uuid(_ value: String?) -> UUID? {
        guard let value else { return nil }
        return UUID(uuidString: value)
    }
}
