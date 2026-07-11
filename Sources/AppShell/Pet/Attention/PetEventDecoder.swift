import Foundation
import CoreModel
import SocketServer

public enum PetEventDecoder {
    public static func decode(_ event: EventBus.Event) -> PetDomainEvent? {
        guard case .object(let payload) = event.payload else { return nil }

        switch event.kind {
        case "agent.run.started":
            guard let runID = uuidString(payload["run_id"]) else { return nil }
            return .agentRunStarted(runID: runID)
        case "agent.turn.started":
            guard uuidString(payload["thread_id"]) != nil else { return nil }
            return .agentTurnStarted
        case "agent.item.started":
            guard let threadID = uuidString(payload["thread_id"]),
                  let item = payload["item"]?.objectValue,
                  let itemID = nonemptyString(item["id"]),
                  let rawType = nonemptyString(item["type"]),
                  let type = AssistantItemType(rawValue: rawType) else { return nil }
            return .agentItemStarted(itemID: scoped(threadID: threadID, localID: itemID), type: type)
        case "agent.item.completed":
            guard let threadID = uuidString(payload["thread_id"]),
                  let itemID = nonemptyString(payload["item_id"]) else { return nil }
            return .agentItemCompleted(itemID: scoped(threadID: threadID, localID: itemID))
        case "agent.item.delta":
            return .agentItemDelta
        case "agent.item.progress":
            return .agentItemProgress
        case "agent.context.compaction":
            guard uuidString(payload["thread_id"]) != nil else { return nil }
            return .contextCompaction
        case "agent.request.opened":
            guard let threadID = uuidString(payload["thread_id"]),
                  let requestID = nonemptyString(payload["request_id"]) else { return nil }
            return .approvalOpened(requestID: scoped(threadID: threadID, localID: requestID))
        case "agent.request.resolved":
            guard let threadID = uuidString(payload["thread_id"]),
                  let requestID = nonemptyString(payload["request_id"]) else { return nil }
            return .approvalResolved(requestID: scoped(threadID: threadID, localID: requestID))
        case "agent.user_input.requested":
            guard let threadID = uuidString(payload["thread_id"]),
                  let requestID = nonemptyString(payload["request_id"]) else { return nil }
            return .questionOpened(requestID: scoped(threadID: threadID, localID: requestID))
        case "agent.user_input.resolved":
            guard let threadID = uuidString(payload["thread_id"]),
                  let requestID = nonemptyString(payload["request_id"]) else { return nil }
            return .questionResolved(requestID: scoped(threadID: threadID, localID: requestID))
        case "agent.run.finished":
            guard let runID = uuidString(payload["run_id"]),
                  let rawStatus = nonemptyString(payload["status"]),
                  let status = AgentRunStatus(rawValue: rawStatus),
                  status != .pending,
                  status != .running else { return nil }
            return .agentRunFinished(runID: runID, status: status)
        case "agent.run.error":
            guard let runID = uuidString(payload["run_id"]),
                  let recoverable = payload["recoverable"]?.boolValue else { return nil }
            return .agentRunError(runID: runID, recoverable: recoverable)

        case "git.checkout", "git.branch_created", "git.commit", "git.push", "git.deliver":
            guard uuidString(payload["workspace_id"]) != nil,
                  let succeeded = payload["ok"]?.boolValue else { return nil }
            return .git(succeeded ? .succeeded : .failed)
        case "project.script_started":
            guard uuidString(payload["workspace_id"]) != nil,
                  uuidString(payload["surface_id"]) != nil else { return nil }
            return .projectScript(.started)
        case "project.script.finished":
            guard uuidString(payload["workspace_id"]) != nil,
                  uuidString(payload["surface_id"]) != nil else { return nil }
            switch payload["result"]?.stringValue {
            case "success": return .projectScript(.succeeded)
            case "failure": return .projectScript(.failed)
            default: return nil
            }
        case "agent.provider.updated":
            guard let succeeded = payload["ok"]?.boolValue else { return nil }
            return .providerUpdate(succeeded ? .succeeded : .failed)
        case "ssh.transfer.started":
            guard uuidString(payload["surface_id"]) != nil else { return nil }
            return .sshTransfer(.started)
        case "ssh.transfer.completed":
            guard uuidString(payload["surface_id"]) != nil else { return nil }
            return .sshTransfer(.succeeded)
        case "ssh.transfer.failed":
            guard uuidString(payload["surface_id"]) != nil else { return nil }
            return .sshTransfer(.failed)
        case "ssh.session.updated":
            guard uuidString(payload["surface_id"]) != nil else { return nil }
            switch payload["status"]?.stringValue {
            case "connected": return .sshSession(.connected)
            case "disconnected":
                switch payload["reason"]?.stringValue {
                case "unexpected_child_exit": return .sshSession(.unexpectedDisconnect)
                case "connection_failed": return .sshSession(.connectionFailed)
                case "user_requested", nil: return .sshSession(.explicitDisconnect)
                default: return nil
                }
            default: return nil
            }
        case "surface.browser":
            guard uuidString(payload["surface_id"]) != nil else { return nil }
            return .browserNavigation
        case "files.edit.opened":
            guard uuidString(payload["workspace_id"]) != nil,
                  uuidString(payload["surface_id"]) != nil else { return nil }
            return .file(.opened)
        case "files.edit.patch_applied":
            guard uuidString(payload["workspace_id"]) != nil,
                  uuidString(payload["surface_id"]) != nil else { return nil }
            return .file(.saved(conflictID: nil))
        // The recorder and reducer both consume this identity: persistence marks
        // the exact row resolved, while animation clears the matching live blocker.
        case "files.edit.saved":
            guard uuidString(payload["workspace_id"]) != nil,
                  uuidString(payload["surface_id"]) != nil else { return nil }
            return .file(.saved(conflictID: nonemptyString(payload["session_id"])))
        case "files.edit.conflict":
            guard uuidString(payload["workspace_id"]) != nil,
                  uuidString(payload["surface_id"]) != nil,
                  let sessionID = nonemptyString(payload["session_id"]) else { return nil }
            return .file(.conflict(id: sessionID))
        case "files.edit.discarded":
            guard uuidString(payload["workspace_id"]) != nil,
                  uuidString(payload["surface_id"]) != nil else { return nil }
            return .file(.discarded(conflictID: nonemptyString(payload["session_id"])))
        case "files.edit.closed":
            guard uuidString(payload["workspace_id"]) != nil,
                  uuidString(payload["surface_id"]) != nil else { return nil }
            return .file(.closed(conflictID: nonemptyString(payload["session_id"])))

        case "surface.output", "surface.output.summary":
            return .surfaceOutput
        case "agent.thread.token_usage", "agent.account.usage", "agent.account.usage.refresh":
            return .tokenUsage
        case "fs.workspace.changed", "files.state.updated":
            return .filesystemChanged
        case "pane.resized", "pane.split", "pane.swapped",
             "surface.created", "surface.closed", "surface.focused", "surface.moved",
             "surface.reordered", "surface.renamed", "surface.updated", "window.created",
             "workspace.created", "workspace.closed", "workspace.renamed",
             "workspace.reordered", "workspace.selected", "workspace.updated":
            return .layoutChanged
        default:
            // `agent.run.completed` and `agent.run.failed` intentionally land here.
            // AppContext also publishes canonical `agent.run.finished`; decoding both
            // would replay the same terminal outcome twice.
            return nil
        }
    }

    private static func nonemptyString(_ value: JSONValue?) -> String? {
        guard let value = value?.stringValue, !value.isEmpty else { return nil }
        return value
    }

    private static func uuidString(_ value: JSONValue?) -> String? {
        guard let value = nonemptyString(value), UUID(uuidString: value) != nil else { return nil }
        return value
    }

    private static func scoped(threadID: String, localID: String) -> String {
        "\(threadID):\(localID)"
    }
}
