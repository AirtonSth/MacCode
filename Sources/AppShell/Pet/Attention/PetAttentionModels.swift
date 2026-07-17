import Foundation
import CoreModel

public enum PetAttentionFilter: Sendable, Equatable {
    case all
    case completed
    case needsYou
}

public enum PetAttentionClassification: Sendable, Equatable {
    case completed
    case needsYou
}

public enum PetAttentionCallbackKind: String, Sendable, Equatable {
    case approval
    case question
}

public enum PetNotificationCategory: String, CaseIterable, Sendable, Equatable {
    case gitCompleted = "pet.git.completed"
    case gitFailed = "pet.git.failed"
    case projectScriptCompleted = "pet.project-script.completed"
    case projectScriptFailed = "pet.project-script.failed"
    case sshTransferCompleted = "pet.ssh-transfer.completed"
    case sshTransferFailed = "pet.ssh-transfer.failed"
    case sshUnexpectedDisconnect = "pet.ssh-session.unexpected-disconnect"
    case providerUpdateFailed = "pet.provider-update.failed"
    case fileConflict = "pet.file.conflict"
    case serverListenerFailed = "pet.server-listener.failed"

    var classification: PetAttentionClassification {
        switch self {
        case .sshUnexpectedDisconnect, .fileConflict, .serverListenerFailed: return .needsYou
        default: return .completed
        }
    }

    var presentation: PetAttentionPresentation {
        switch self {
        case .gitCompleted:
            return .safe(kind: .gitDelivery(.succeeded))
        case .gitFailed:
            return .safe(kind: .gitDelivery(.failed))
        case .projectScriptCompleted:
            return .safe(kind: .projectScript(.succeeded))
        case .projectScriptFailed:
            return .safe(kind: .projectScript(.failed))
        case .sshTransferCompleted:
            return .safe(kind: .sshTransfer(.succeeded))
        case .sshTransferFailed:
            return .safe(kind: .sshTransfer(.failed))
        case .sshUnexpectedDisconnect:
            return PetAttentionPresentation(title: "SSH connection needs attention", detail: nil)
        case .providerUpdateFailed:
            return .safe(kind: .providerUpdateFailed)
        case .fileConflict:
            return .safe(kind: .fileConflict)
        case .serverListenerFailed:
            return PetAttentionPresentation(title: "Remote access needs attention", detail: nil)
        }
    }
}

public enum PetSettingsRoute: Sendable, Equatable {
    case general
    case providers
}

public enum PetAttentionItemKind: Sendable, Equatable {
    case callback(PetAttentionCallbackKind, isStale: Bool)
    case agentOutcome(PetAttentionOutcome)
    case notification(PetNotificationCategory)

    public var needsUserAction: Bool {
        switch self {
        case .callback:
            return true
        case .agentOutcome:
            return false
        case .notification(let category):
            return category.classification == .needsYou
        }
    }
}

public enum PetAttentionRoute: Sendable, Equatable {
    case agentThread(threadID: AgentThreadID, workspaceID: WorkspaceID?)
    case surface(surfaceID: SurfaceID, workspaceID: WorkspaceID?)
    case workspace(workspaceID: WorkspaceID)
    case settings(PetSettingsRoute)
}

public enum PetAttentionSource: Sendable, Equatable {
    case callback(threadID: AgentThreadID, requestID: String, kind: PetAttentionCallbackKind)
    case agentThread(threadID: AgentThreadID)
    case notification(id: String)
}

public struct PetAttentionItem: Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: PetAttentionItemKind
    public let title: String
    public let detail: String?
    public let createdAt: Date
    public let route: PetAttentionRoute
    public let source: PetAttentionSource

    public init(
        id: String,
        kind: PetAttentionItemKind,
        title: String,
        detail: String?,
        createdAt: Date,
        route: PetAttentionRoute,
        source: PetAttentionSource
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.createdAt = createdAt
        self.route = route
        self.source = source
    }

    public var classification: PetAttentionClassification {
        kind.needsUserAction ? .needsYou : .completed
    }
}

public struct PetAttentionSnapshot: Sendable, Equatable {
    public let items: [PetAttentionItem]

    public init(items: [PetAttentionItem]) {
        self.items = items
    }

    public var count: Int { items.count }
}

/// In-flight agent thread row for the pet popover. Titles are fixed privacy-safe
/// copy; membership is supplied by the live active-run projection, not thread
/// status rows that can lag after crashes.
public struct PetActiveThreadItem: Sendable, Equatable, Identifiable {
    public let id: String
    public let threadID: AgentThreadID
    public let title: String
    public let detail: String?
    public let route: PetAttentionRoute

    public init(
        threadID: AgentThreadID,
        workspaceID: WorkspaceID?,
        providerName: String?
    ) {
        self.id = "active:\(threadID.value.uuidString)"
        self.threadID = threadID
        let presentation = PetAttentionPresentation.safe(
            kind: .agentRunning,
            context: PetAttentionContext(providerName: providerName)
        )
        self.title = presentation.title
        self.detail = presentation.detail
        self.route = .agentThread(threadID: threadID, workspaceID: workspaceID)
    }
}

public enum PetActiveThreadProjector {
    public static func items(
        threadIDs: [AgentThreadID],
        lookup: (AgentThreadID) -> (workspaceID: WorkspaceID?, providerName: String?)?
    ) -> [PetActiveThreadItem] {
        let unique = Array(Set(threadIDs)).sorted {
            $0.value.uuidString < $1.value.uuidString
        }
        return unique.map { threadID in
            let meta = lookup(threadID)
            return PetActiveThreadItem(
                threadID: threadID,
                workspaceID: meta?.workspaceID,
                providerName: meta?.providerName
            )
        }
    }

    public static func providerLabel(_ provider: AgentProvider) -> String {
        switch provider {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .grok: return "Grok"
        }
    }
}

public enum PetAttentionMarkResult: Sendable, Equatable {
    case marked
    case retainedBlocker
    case routeRejected
    case notFound
}

public enum PetTerminalNotificationKind: Sendable, Equatable {
    case gitDelivery(PetAttentionOperationOutcome)
    case projectScript(PetAttentionOperationOutcome)
    case sshTransfer(PetAttentionOperationOutcome)
    case sshUnexpectedDisconnect
    case providerUpdateFailed
    case fileConflict
}

public struct PetTerminalEvent: Sendable, Equatable {
    public let sequence: Int64
    public let kind: PetTerminalNotificationKind
    public let workspaceID: WorkspaceID?
    public let surfaceID: SurfaceID?
    public let createdAt: Date

    public init(
        sequence: Int64,
        kind: PetTerminalNotificationKind,
        workspaceID: WorkspaceID?,
        surfaceID: SurfaceID?,
        createdAt: Date
    ) {
        self.sequence = sequence
        self.kind = kind
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.createdAt = createdAt
    }
}
