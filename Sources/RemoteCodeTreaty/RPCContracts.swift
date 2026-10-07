import Foundation

public protocol RemoteCodeRPCContract {
    associatedtype Params: Codable & Sendable
    associatedtype Result: Codable & Sendable
    static var method: String { get }
}

public struct RemoteCodeError: Codable, Equatable, Sendable, Error {
    public enum Kind: Equatable, Sendable {
        case parseError
        case invalidRequest
        case methodNotFound
        case invalidParams
        case internalError
        case missingRequestID
        case botControlPlaneOff
        case botNotFound
        case botLimit
        case reservedCapability
        case crossTarget
        case botHandleConflict
        case pathContainment
        case botBrowserPersistence
        case dockerHomeClear
        case botFileNotFound
        case commandReceiptUnavailable
        case legacyReceiptUnverifiable
        case idempotencyRequestMismatch
        case idempotencyOwnerMismatch
        case commandOutcomeUnknown
        case commandInProgress
        case authenticatedHostMismatch
        /// `bot.team.*` / `bot.group.*`: the team, group or turn is gone
        /// (code -32044 with `data.domain == "bot_group"`; not a deleted bot).
        case botGroupNotFound
        /// `bot.team.*` / `bot.group.*`: `expected_revision` is stale; re-read.
        case botGroupRevisionConflict
        /// `bot.team.*` / `bot.group.*`: this host cannot run groups right now.
        case botGroupRuntimeUnavailable
        /// `agent.manual_action.resolve`: the request is not one of this thread's.
        case manualActionNotFound
        /// `agent.manual_action.resolve`: another resolve won; `data.state` is the current state.
        case manualActionStateConflict
        /// `agent.manual_action.resolve` `take` on a thread that runs on the Mac.
        case manualActionTakeUnavailable
        /// `agent.thread.actor.set`: unknown thread or bot.
        case threadActorNotFound
        /// `agent.thread.actor.set`: the thread is locked (messages, a locked actor or a run).
        case threadActorLocked
        /// `agent.thread.actor.set` `execution_target` `vm` for a bot without a VM.
        case threadActorTargetUnavailable
        /// `agent.mac_execution.resolve`: unknown thread.
        case macExecutionNotFound
        /// `agent.mac_execution.resolve`: nothing pending (already answered).
        case macExecutionNotPending
        /// `agent.attachment.get`: the message is not on this thread, or the attachment is not on it.
        case attachmentNotFound
        /// `agent.attachment.get`: the bytes exceed `max_bytes`; `data.data_size_bytes` says by how much.
        case attachmentTooLarge
        /// `agent.attachment.get`: stored bytes gone or changed, or a thumbnail of a non-image.
        case attachmentUnavailable
        case unknown(Int)
    }

    public let code: Int
    public let message: String
    public let data: RemoteCodeJSONValue?

    public init(code: Int, message: String, data: RemoteCodeJSONValue?) {
        self.code = code
        self.message = message
        self.data = data
    }

    public var kind: Kind {
        // Team and group refusals reuse some bot codes; their `data` tells
        // them apart, so a bot handler never drops a bot for a missing group.
        if case .object(let data)? = data, data["domain"] == .string("bot_group") {
            switch data["kind"] {
            case .string("not_found"): return .botGroupNotFound
            case .string("revision_conflict"): return .botGroupRevisionConflict
            case .string("runtime_unavailable"): return .botGroupRuntimeUnavailable
            default: break
            }
        }
        if case .object(let data)? = data, data["domain"] == .string("thread_actor") {
            switch data["kind"] {
            case .string("not_found"): return .threadActorNotFound
            case .string("locked"): return .threadActorLocked
            case .string("target_unavailable"): return .threadActorTargetUnavailable
            default: break
            }
        }
        if case .object(let data)? = data, data["domain"] == .string("mac_execution") {
            switch data["kind"] {
            case .string("not_found"): return .macExecutionNotFound
            case .string("not_pending"): return .macExecutionNotPending
            default: break
            }
        }
        if case .object(let data)? = data, data["domain"] == .string("attachment") {
            switch data["kind"] {
            case .string("not_found"): return .attachmentNotFound
            case .string("too_large"): return .attachmentTooLarge
            case .string("unavailable"): return .attachmentUnavailable
            default: break
            }
        }
        if case .object(let data)? = data, data["domain"] == .string("manual_action") {
            switch data["kind"] {
            case .string("not_found"): return .manualActionNotFound
            case .string("state_conflict"): return .manualActionStateConflict
            case .string("take_unavailable"): return .manualActionTakeUnavailable
            default: break
            }
        }
        switch code {
        case -32700: return .parseError
        case -32600: return .invalidRequest
        case -32601: return .methodNotFound
        case -32602: return .invalidParams
        case -32603: return .internalError
        case -32097: return .missingRequestID
        case -32081: return .botControlPlaneOff
        case -32044: return .botNotFound
        case -32082: return .botLimit
        case -32083: return .reservedCapability
        case -32084: return .crossTarget
        case -32085: return .botHandleConflict
        case -32086: return .pathContainment
        case -32087: return .botBrowserPersistence
        case -32088: return .dockerHomeClear
        case -32090: return .botFileNotFound
        case -32091: return .commandReceiptUnavailable
        case -32092: return .legacyReceiptUnverifiable
        case -32093: return .idempotencyRequestMismatch
        case -32094: return .idempotencyOwnerMismatch
        case -32095: return .commandOutcomeUnknown
        case -32096: return .commandInProgress
        case -32098: return .authenticatedHostMismatch
        // `rpc.batch` error items carry only `code` and `message` (no
        // `data`), so the attachment codes, used by nothing else, also map
        // on their own.
        case -32066: return .attachmentNotFound
        case -32067: return .attachmentTooLarge
        case -32068: return .attachmentUnavailable
        default: return .unknown(code)
        }
    }
}
