import AppKit
import AgentRuntime
import CoreModel
import DesignSystemKit
import Persistence
import SocketServer
import Surfaces
import SwiftUI
import WebKit

// MARK: - Drafts & rows

public struct BotQueuedFollowUp: Equatable, Identifiable, Codable {
    public let id: UUID
    public var text: String
    public var attachments: [AgentAttachment]
    /// Host-catalog sends pin the exact conversation they were accepted for.
    /// Nil preserves the existing Desk queue behavior across older payloads.
    public var conversationID: BotConversationID?
    /// Host sends also freeze the authenticated caller's execution route.
    /// Direct Desk follow-ups keep nil and use the user's current thread chips.
    public var routing: BotDeskRouting?

    public init(
        id: UUID = UUID(),
        text: String,
        attachments: [AgentAttachment] = [],
        conversationID: BotConversationID? = nil,
        routing: BotDeskRouting? = nil
    ) {
        self.id = id
        self.text = text
        self.attachments = attachments
        self.conversationID = conversationID
        self.routing = routing
    }
}

private struct BotQueuedFollowUpStorePayload: Codable {
    var attachments: [AgentAttachment]
    var routing: BotDeskRouting?
}

public struct BotDeskRouting: Equatable, Codable {
    public var provider: AgentProvider
    public var providerInstanceID: String
    public var model: String
    public var routingMode: AgentRoutingMode
    public var permissionMode: AgentPermissionMode
    public var reasoningEffort: AgentReasoningEffort
    public var reasoningModel: String?
    public var distillMainEffortSelection: AgentEffortSelection?
    public var distillReasoningEffortSelection: AgentEffortSelection?
    public var serviceTier: AgentServiceTier
    public var runAsUser: AgentRunAsUser

    public init(
        provider: AgentProvider = .defaultProvider,
        providerInstanceID: String = AgentProvider.defaultProvider.rawValue,
        model: String = "",
        routingMode: AgentRoutingMode = .auto,
        permissionMode: AgentPermissionMode = .supervised,
        reasoningEffort: AgentReasoningEffort = .medium,
        reasoningModel: String? = nil,
        distillMainEffortSelection: AgentEffortSelection? = nil,
        distillReasoningEffortSelection: AgentEffortSelection? = nil,
        serviceTier: AgentServiceTier = .auto,
        runAsUser: AgentRunAsUser? = nil
    ) {
        self.provider = provider
        self.providerInstanceID = providerInstanceID
        self.model = model
        self.routingMode = provider == .distill ? .manual : routingMode
        self.permissionMode = permissionMode
        self.reasoningEffort = reasoningEffort
        self.reasoningModel = reasoningModel
        self.distillMainEffortSelection = distillMainEffortSelection
        self.distillReasoningEffortSelection = distillReasoningEffortSelection
        self.serviceTier = serviceTier
        self.runAsUser = runAsUser ?? AgentRunAsUser.current()
        migrateLegacyProvider()
    }

    /// RemoteCode runs Distill only: a saved Codex/Claude/Grok route becomes Distill defaults.
    private mutating func migrateLegacyProvider() {
        guard !provider.isSelectable else { return }
        provider = .distill
        providerInstanceID = AgentProvider.distill.rawValue
        model = ""
        routingMode = .manual
        reasoningEffort = .medium
        reasoningModel = nil
        distillMainEffortSelection = nil
        distillReasoningEffortSelection = nil
        serviceTier = .auto
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decode(AgentProvider.self, forKey: .provider)
        providerInstanceID = try container.decode(String.self, forKey: .providerInstanceID)
        model = try container.decode(String.self, forKey: .model)
        let restoredRoutingMode = try container.decode(AgentRoutingMode.self, forKey: .routingMode)
        routingMode = provider == .distill ? .manual : restoredRoutingMode
        permissionMode = try container.decode(AgentPermissionMode.self, forKey: .permissionMode)
        reasoningEffort = try container.decodeIfPresent(AgentReasoningEffort.self, forKey: .reasoningEffort) ?? .medium
        reasoningModel = try container.decodeIfPresent(String.self, forKey: .reasoningModel)
        distillMainEffortSelection = try container.decodeIfPresent(AgentEffortSelection.self, forKey: .distillMainEffortSelection)
        distillReasoningEffortSelection = try container.decodeIfPresent(AgentEffortSelection.self, forKey: .distillReasoningEffortSelection)
        serviceTier = try container.decodeIfPresent(AgentServiceTier.self, forKey: .serviceTier) ?? .auto
        runAsUser = try container.decodeIfPresent(AgentRunAsUser.self, forKey: .runAsUser)
            ?? AgentRunAsUser.current()
        migrateLegacyProvider()
    }

    /// A Bot has no provider of its own. Existing Desk threads restore the
    /// user's thread route; delegated calls freeze the exact provider/model
    /// selected for the active caller run so Auto cannot choose a new one.
    public init(thread: AgentThread, activeRun: AgentRun? = nil) {
        let route: AgentRunRepository.RouteChrome? = {
            guard let run = activeRun, run.threadId == thread.id else { return nil }
            return AgentRunRepository.RouteChrome(
                threadId: run.threadId,
                provider: run.provider,
                providerInstanceId: run.providerInstanceId ?? run.provider.rawValue,
                model: run.model
            )
        }()
        self.init(thread: thread, activeRunRoute: route)
    }

    public init(thread: AgentThread, activeRunRoute: AgentRunRepository.RouteChrome?) {
        let run = activeRunRoute?.threadId == thread.id ? activeRunRoute : nil
        let provider = run?.provider ?? thread.provider
        self.init(
            provider: provider,
            providerInstanceID: run?.providerInstanceId
                ?? (thread.provider == provider ? thread.providerInstanceId : nil)
                ?? provider.rawValue,
            model: run?.model ?? thread.model,
            routingMode: run == nil ? thread.effectiveRoutingConfiguration.mode : .manual,
            permissionMode: thread.permissionMode,
            reasoningEffort: thread.reasoningEffort,
            reasoningModel: thread.reasoningModel,
            distillMainEffortSelection: thread.modelSelection.distillMainEffortSelection,
            distillReasoningEffortSelection: thread.modelSelection.distillReasoningEffortSelection,
            serviceTier: thread.serviceTier,
            runAsUser: thread.runAsUser
        )
    }

    public init(
        route: AgentRunRepository.RouteChrome,
        policy: AgentThreadRepository.DeskPolicyChrome
    ) {
        self.init(
            provider: route.provider,
            providerInstanceID: route.providerInstanceId,
            model: route.model,
            routingMode: .manual,
            permissionMode: policy.permissionMode,
            reasoningEffort: policy.reasoningEffort,
            serviceTier: policy.serviceTier,
            runAsUser: policy.runAsUser
        )
    }

    /// 1.2: `auto` is honest — it resolves to the provider default and never
    /// pretends to run a Token Saver / eligibleProviders router. Renaming
    /// the wire value would break persisted routing; keep `auto` but make the
    /// contract explicit in code and UI.
    public var isAutoRouting: Bool { routingMode == .auto }

    public var modelSelection: AgentModelSelection {
        AgentModelSelection(
            provider: provider,
            modelId: model,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier,
            distillMainEffortSelection: provider == .distill
                ? (distillMainEffortSelection ?? .fixed(reasoningEffort)) : nil,
            distillReasoningEffortSelection: provider == .distill
                ? (distillReasoningEffortSelection ?? .automatic) : nil
        )
    }

    public func resolvedModel(defaultModel: (AgentProvider) -> String) -> String {
        if isAutoRouting || model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return defaultModel(provider)
        }
        return model
    }
}

public struct BotComposerDraft: Equatable, Codable {
    public var text: String
    public var attachments: [AgentAttachment]

    public init(text: String = "", attachments: [AgentAttachment] = []) {
        self.text = text
        self.attachments = attachments
    }

    public var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
    }

    public var liveAttachments: [AgentAttachment] {
        attachments.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

public struct BotInspectorDraft: Equatable, Codable {
    public var memoryDraft: String
    public var skillDraft: String
    public var routineName: String
    public var routinePrompt: String
    public var routineScheduleNote: String
    public var routineSpec: BotScheduleSpec?

    public init(
        memoryDraft: String = "",
        skillDraft: String = "",
        routineName: String = "",
        routinePrompt: String = "",
        routineScheduleNote: String = "",
        routineSpec: BotScheduleSpec? = nil
    ) {
        self.memoryDraft = memoryDraft
        self.skillDraft = skillDraft
        self.routineName = routineName
        self.routinePrompt = routinePrompt
        self.routineScheduleNote = routineScheduleNote
        self.routineSpec = routineSpec
    }

    public var isEmpty: Bool {
        let textsEmpty = [memoryDraft, skillDraft, routineName, routinePrompt, routineScheduleNote]
            .allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return textsEmpty && routineSpec == nil
    }

    enum CodingKeys: String, CodingKey {
        case memoryDraft, skillDraft, routineName, routinePrompt, routineScheduleNote, routineSpec
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        memoryDraft = try container.decodeIfPresent(String.self, forKey: .memoryDraft) ?? ""
        skillDraft = try container.decodeIfPresent(String.self, forKey: .skillDraft) ?? ""
        routineName = try container.decodeIfPresent(String.self, forKey: .routineName) ?? ""
        routinePrompt = try container.decodeIfPresent(String.self, forKey: .routinePrompt) ?? ""
        routineScheduleNote = try container.decodeIfPresent(String.self, forKey: .routineScheduleNote) ?? ""
        routineSpec = try container.decodeIfPresent(BotScheduleSpec.self, forKey: .routineSpec)
        routineSpec?.migrateLegacyProvider()
    }
}

public struct BotStudioDraft: Equatable, Codable {
    public var botID: BotID?
    public var name: String
    public var title: String
    public var description: String
    public var handle: String
    public var avatarSymbol: String
    public var soul: String
    public var notificationsEnabled: Bool
    public var desktopKind: BotDesktopKind
    public var expectedRevisionID: BotRevisionID?
    /// nil means infer from handle vs name (legacy drafts).
    public var slugFollowsName: Bool? = true

    public init(
        botID: BotID? = nil,
        name: String = "",
        title: String = "",
        description: String = "",
        handle: String = "",
        avatarSymbol: String = BotBlobatarSpec.default.token,
        soul: String = "",
        notificationsEnabled: Bool = true,
        desktopKind: BotDesktopKind = .logicalExecutionSpace,
        expectedRevisionID: BotRevisionID? = nil,
        slugFollowsName: Bool? = true
    ) {
        self.botID = botID
        self.name = name
        self.title = title
        self.description = description
        self.handle = handle
        self.avatarSymbol = avatarSymbol
        self.soul = soul
        self.notificationsEnabled = notificationsEnabled
        self.desktopKind = desktopKind
        self.expectedRevisionID = expectedRevisionID
        self.slugFollowsName = slugFollowsName
    }

    public var isNew: Bool { botID == nil }
}

/// Keeps Studio form edits off the view model that also owns the roster,
/// conversations, schedules, and every other Bots destination.
@MainActor
public final class BotsStudioDraftState: ObservableObject {
    @Published public var draft = BotStudioDraft()
    /// Secret drafts are memory-only. They are never part of the persisted
    /// Studio draft or any bot file.
    @Published public var secretNameDraft = ""
    @Published public var secretValueDraft = ""
    @Published public var editingSecretName: String?
}

public enum BotStudioFilesLocation: String, Codable, Sendable, Equatable {
    case botFiles
    case dockerHome

    public var title: String {
        switch self {
        case .botFiles: return "Bot files"
        case .dockerHome: return "Docker home"
        }
    }
}

private struct BotStudioSupportSnapshot {
    var conversations: [BotConversation]
    var selectedConversation: BotConversation?
    var selectedRevision: BotRevision?
    var skillBindings: [BotSkillBinding]
    var memoryItems: [BotMemoryItem]
    var lastContextReceipt: ContextAssemblyReceipt?
    var routines: [BotRoutine]
}

public struct BotDeskPeer: Equatable, Sendable {
    public enum Direction: String, Sendable {
        case messaged
        case fromPeer
    }

    public var direction: Direction
    public var botID: BotID
    public var name: String
    public var title: String
    public var handle: String
    public var avatarSymbol: String
    public var activityPhase: BotPeerActivityPhase?

    public init(
        direction: Direction,
        bot: BotDefinition,
        activityPhase: BotPeerActivityPhase? = nil
    ) {
        self.direction = direction
        self.botID = bot.id
        self.name = bot.name
        self.title = bot.title
        self.handle = bot.handle
        self.avatarSymbol = bot.avatarSymbol
        self.activityPhase = activityPhase
    }

    public init(
        direction: Direction,
        botID: BotID,
        name: String,
        title: String,
        handle: String,
        avatarSymbol: String = "",
        activityPhase: BotPeerActivityPhase? = nil
    ) {
        self.direction = direction
        self.botID = botID
        self.name = name
        self.title = title
        self.handle = handle
        self.avatarSymbol = avatarSymbol
        self.activityPhase = activityPhase
    }

    public var caption: String {
        switch direction {
        case .messaged: return BotPeerTranscript.mentionedCaption(name: name)
        case .fromPeer: return BotPeerTranscript.fromCaption(name: name)
        }
    }
}

public struct BotDeskMessage: Identifiable, Equatable, Sendable {
    public enum Role: String, Sendable {
        case user
        case assistant
    }

    public let id: UUID
    public let role: Role
    public let text: String
    public let createdAt: Date
    public var peer: BotDeskPeer?
    public var agentMessageID: AgentMessageID?
    public var tokenSaverWireRequest: String?
    public var tokenSaverOriginal: String?
    public var tokenSaverTurnId: String?

    public init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        createdAt: Date = Date(),
        peer: BotDeskPeer? = nil,
        agentMessageID: AgentMessageID? = nil,
        tokenSaverWireRequest: String? = nil,
        tokenSaverOriginal: String? = nil,
        tokenSaverTurnId: String? = nil
    ) {
        self.id = agentMessageID?.value ?? id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.peer = peer
        self.agentMessageID = agentMessageID
        self.tokenSaverWireRequest = tokenSaverWireRequest
        self.tokenSaverOriginal = tokenSaverOriginal
        self.tokenSaverTurnId = tokenSaverTurnId
    }
}

enum BotPeerHandoffPhase: String, Codable, Equatable {
    case peerPrepared
    case peerRunning
    case peerCompleted
    case hostPrepared
    case hostRunning
    case completed
    case needsAttention
}

struct BotPeerHandoffSnapshot: Equatable {
    let activityID: UUID
    let consultationID: UUID?
    let originBotID: BotID?
    let originConversationID: BotConversationID?
    let originThreadID: AgentThreadID?
    let peerBotID: BotID
    let peerConversationID: BotConversationID
    let peerThreadID: AgentThreadID?
    let peerRunID: AgentRunID?
    let inboundMessageID: UUID
    let outboundText: String
    let hostInstructionText: String
    let hostThreadID: AgentThreadID?
    let hostRunID: AgentRunID?
    let phase: BotPeerHandoffPhase
    let peerProvider: AgentProvider
    let peerModel: String
    let hostProvider: AgentProvider?
    let hostModel: String?
}

private struct BotPeerHandoffRoute: Codable, Equatable {
    let provider: AgentProvider
    let providerInstanceID: String
    let model: String
    let permissionMode: AgentPermissionMode
    let reasoningEffort: AgentReasoningEffort
    let serviceTier: AgentServiceTier
    let runAsUser: AgentRunAsUser
    let routingConfiguration: AgentRoutingConfiguration?

    private enum CodingKeys: String, CodingKey {
        case provider
        case providerInstanceID
        case model
        case permissionMode
        case reasoningEffort
        case serviceTier
        case runAsUser
        case routingConfiguration
    }

    @MainActor
    init(_ routing: BotDeskRouting) {
        provider = routing.provider
        providerInstanceID = routing.providerInstanceID
        model = routing.resolvedModel(defaultModel: BotsViewModel.defaultModel(for:))
        permissionMode = routing.permissionMode
        reasoningEffort = routing.reasoningEffort
        serviceTier = routing.serviceTier
        runAsUser = routing.runAsUser
        routingConfiguration = nil
    }

    init(_ thread: AgentThread) {
        provider = thread.provider
        providerInstanceID = thread.providerInstanceId ?? thread.provider.rawValue
        model = thread.model
        permissionMode = thread.permissionMode
        reasoningEffort = thread.reasoningEffort
        serviceTier = thread.serviceTier
        runAsUser = thread.runAsUser ?? AgentRunAsUser.current()
        routingConfiguration = thread.routingConfiguration
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decode(AgentProvider.self, forKey: .provider)
        providerInstanceID = try container.decodeIfPresent(String.self, forKey: .providerInstanceID)
            ?? provider.rawValue
        model = try container.decode(String.self, forKey: .model)
        permissionMode = try container.decodeIfPresent(AgentPermissionMode.self, forKey: .permissionMode)
            ?? .supervised
        reasoningEffort = try container.decodeIfPresent(AgentReasoningEffort.self, forKey: .reasoningEffort)
            ?? .medium
        serviceTier = try container.decodeIfPresent(AgentServiceTier.self, forKey: .serviceTier) ?? .auto
        runAsUser = try container.decode(AgentRunAsUser.self, forKey: .runAsUser)
        routingConfiguration = try container.decodeIfPresent(
            AgentRoutingConfiguration.self,
            forKey: .routingConfiguration
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider, forKey: .provider)
        if providerInstanceID != provider.rawValue {
            try container.encode(providerInstanceID, forKey: .providerInstanceID)
        }
        try container.encode(model, forKey: .model)
        if permissionMode != .supervised {
            try container.encode(permissionMode, forKey: .permissionMode)
        }
        if reasoningEffort != .medium {
            try container.encode(reasoningEffort, forKey: .reasoningEffort)
        }
        if serviceTier != .auto {
            try container.encode(serviceTier, forKey: .serviceTier)
        }
        try container.encode(runAsUser, forKey: .runAsUser)
        try container.encodeIfPresent(routingConfiguration, forKey: .routingConfiguration)
    }
}

private struct PersistedBotPeerHandoff: Codable, Equatable {
    let version: Int
    let activityID: UUID
    let consultationID: UUID?
    let originBotID: BotID?
    let originConversationID: BotConversationID?
    let originAgentThreadID: AgentThreadID?
    let peerBotID: BotID
    let peerConversationID: BotConversationID
    let peerThreadID: AgentThreadID?
    let peerRunID: AgentRunID?
    let inboundMessageID: UUID
    let peerName: String
    let peerTitle: String
    let peerHandle: String
    var peerAvatarSymbol: String? = nil
    let outboundText: String
    var hostInstructionText: String? = nil
    let createdAt: Date
    let peerRoute: BotPeerHandoffRoute
    var hostContinuationRequired: Bool? = nil
    var hostThreadID: AgentThreadID?
    var hostRunID: AgentRunID?
    var hostRoute: BotPeerHandoffRoute?
    var replyText: String?
    var replyCreatedAt: Date?
    var phase: BotPeerHandoffPhase

    var requiresHostContinuation: Bool { hostContinuationRequired ?? true }
    var resolvedHostInstructionText: String { hostInstructionText ?? outboundText }
}

private struct BotStartedRun {
    let conversation: BotConversation
    let thread: AgentThread
    let runID: AgentRunID
    let routing: BotDeskRouting
}

private struct BotPeerRunPlan {
    let bot: BotDefinition
    let revision: BotRevision
    let started: BotStartedRun
    let memoryFiles: [BotMemoryFileText]
    let skills: [BotSkillBinding]
    let ownedSkills: [BotOwnedSkillText]
    let routines: [BotRoutine]
    let browser: BotBrowserTarget?
    let attachments: [AgentAttachment]
    let providerSnapshots: [AgentProviderSnapshot]
    let executionCwd: String?

    func receipt(userText: String) -> ContextAssemblyReceipt {
        BotBrainCompiler.assemble(
            bot: bot,
            revision: revision,
            userText: userText,
            memoryFiles: memoryFiles,
            skills: skills,
            ownedSkills: ownedSkills,
            routines: routines,
            workspace: nil,
            browser: browser,
            conversationID: started.conversation.id,
            liveRunMode: started.routing.permissionMode,
            runProvider: started.routing.provider,
            runModel: started.routing.resolvedModel(defaultModel: BotsViewModel.defaultModel(for:))
        )
    }
}

private struct BotPeerAgentAppHostPlan {
    let thread: AgentThread
    let runID: AgentRunID
}

private enum BotPeerHostContinuation {
    case desk(BotPeerRunPlan)
    case agentApp(BotPeerAgentAppHostPlan)

    var runID: AgentRunID {
        switch self {
        case .desk(let plan): plan.started.runID
        case .agentApp(let plan): plan.runID
        }
    }
}

private struct BotPeerExecutionPlan {
    let activityID: UUID
    let peer: BotDefinition
    let peerRun: BotPeerRunPlan
    let peerReceipt: ContextAssemblyReceipt
    let host: BotPeerHostContinuation?
}

private struct BotPeerHandoffDelta {
    let activityID: UUID
    let previous: PersistedBotPeerHandoff?
    let current: PersistedBotPeerHandoff?
    let errorMessage: String?
}

private enum BotPeerRunStartDeadlineError: Error {
    case exceeded
}

/// One-shot race whose deadline can settle the handoff even when provider
/// preparation ignores cooperative task cancellation.
private final class BotPeerRunStartRace: @unchecked Sendable {
    typealias Outcome = Result<AgentMessageSendResult, Error>

    private let lock = NSLock()
    private var outcome: Outcome?
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var tasks: [Task<Void, Never>] = []

    func install(_ continuation: CheckedContinuation<Outcome, Never>) {
        lock.lock()
        if let outcome {
            lock.unlock()
            continuation.resume(returning: outcome)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func add(_ task: Task<Void, Never>) {
        lock.lock()
        if outcome == nil {
            tasks.append(task)
            lock.unlock()
        } else {
            lock.unlock()
            task.cancel()
        }
    }

    func resolve(_ outcome: Outcome) {
        lock.lock()
        guard self.outcome == nil else {
            lock.unlock()
            return
        }
        self.outcome = outcome
        let continuation = self.continuation
        self.continuation = nil
        let tasks = self.tasks
        self.tasks.removeAll()
        lock.unlock()

        tasks.forEach { $0.cancel() }
        continuation?.resume(returning: outcome)
    }
}

@MainActor
private protocol BotPeerHandoffAuthorityObserver: AnyObject {
    func botPeerHandoffAuthority(
        _ authority: BotPeerHandoffAuthority,
        didApply delta: BotPeerHandoffDelta
    )
}

@MainActor
final class BotPeerHandoffAuthority: AgentRunObserver {
    private final class WeakObserver {
        weak var value: (any BotPeerHandoffAuthorityObserver)?

        init(_ value: any BotPeerHandoffAuthorityObserver) {
            self.value = value
        }
    }

    // PERF: share JSON codec
    private static let sharedEncoder = JSONEncoder()
    private static let sharedDecoder = JSONDecoder()
    private static let codecLock = NSLock()
    private static func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
        Self.codecLock.lock()
        defer { Self.codecLock.unlock() }
        return try Self.sharedEncoder.encode(value)
    }
    private static func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        Self.codecLock.lock()
        defer { Self.codecLock.unlock() }
        return try Self.sharedDecoder.decode(type, from: data)
    }

    private static let defaultsKey = "bots.peerTurns.v2"
    private static let canonicalPrefix = "base64:"
    private static let emptyPayload = Data("[]".utf8)
    private static let peerRunStartTimeout: TimeInterval = 60
    private static let knownRecordFields: Set<String> = [
        "version", "activityID", "consultationID", "originBotID", "originConversationID",
        "originAgentThreadID", "peerBotID", "peerConversationID", "peerThreadID",
        "peerRunID", "inboundMessageID", "peerName", "peerTitle", "peerHandle",
        "peerAvatarSymbol",
        "outboundText", "hostInstructionText", "createdAt", "peerRoute", "hostThreadID", "hostRunID",
        "hostContinuationRequired", "hostRoute", "replyText", "replyCreatedAt", "phase",
    ]

    private struct StoredPayload {
        let rows: [UUID: PersistedBotPeerHandoff]
        let isSupported: Bool
    }

    private enum StorageError: Error {
        case mirrorCommitFailed
    }

    private struct DeletionFence {
        let originBotID: BotID?
        let threadIDs: Set<AgentThreadID>
        let rows: [UUID: PersistedBotPeerHandoff]

        var activityIDs: Set<UUID> { Set(rows.keys) }

        func matches(_ handoff: PersistedBotPeerHandoff) -> Bool {
            if let originBotID, handoff.originBotID == originBotID {
                return true
            }
            return [
                handoff.originAgentThreadID,
                handoff.peerThreadID,
                handoff.hostThreadID,
            ].compactMap { $0 }.contains { threadIDs.contains($0) }
        }
    }

    private let botStore: BotStore
    private let threadRepo: AgentThreadRepository
    private let runRepo: AgentRunRepository
    private let messageRepo: AgentMessageRepository
    private let queuedMessageRepo: AgentQueuedMessageRepository
    private let checkpointRepo: AgentTurnCheckpointRepository
    private let settingsRepo: SettingsRepository
    private let coordinator: AgentRunCoordinator
    /// Telemetry-only Subagents receipts for delegated peer runs. Nil in
    /// fixtures that predate the wiring; delegation still works without rows.
    private let orchestrationRuntime: AgentOrchestrationRuntime?
    private let appSupportDirectory: URL
    weak var router: AppCommandRouter?

    private var handoffs: [UUID: PersistedBotPeerHandoff] = [:]
    private var activeConsultationClaims: Set<UUID> = []
    /// Telemetry receipt id per delegated peer run, so finalization targets the
    /// exact bot row even when routing admission wrote a second receipt under
    /// the same runId.
    private var delegationReceiptIDs: [AgentRunID: UUID] = [:]
    private var tasksByActivityID: [UUID: Task<Void, Never>] = [:]
    private var armedRunIDs: Set<AgentRunID> = []
    private var exactRunWaiters: [AgentRunID: [CheckedContinuation<AgentRun?, Never>]] = [:]
    private var observedTerminalRuns: [AgentRunID: AgentRun] = [:]
    private var agentAppDispatchWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    /// EV-21: stamped from the coordinator's stream thread for EVERY event of
    /// EVERY run (~90/s with 3 runs). It used to be MainActor state written via
    /// `Task { @MainActor }`, i.e. one main-queue hop per token. A lock-guarded
    /// box lets the stream thread write in place; only `latestPeerProgress`
    /// reads it, on the main actor.
    private final class PeerProgressStamps: @unchecked Sendable {
        private let lock = NSLock()
        private var dates: [AgentRunID: Date] = [:]

        func stamp(_ run: AgentRunID) {
            lock.lock(); defer { lock.unlock() }
            dates[run] = Date()
        }

        func date(for run: AgentRunID) -> Date? {
            lock.lock(); defer { lock.unlock() }
            return dates[run]
        }

        func remove(_ run: AgentRunID) {
            lock.lock(); defer { lock.unlock() }
            dates.removeValue(forKey: run)
        }

        var countForTesting: Int {
            lock.lock(); defer { lock.unlock() }
            return dates.count
        }
    }

    private nonisolated let peerProgress = PeerProgressStamps()
    var peerProgressStampCountForTesting: Int { peerProgress.countForTesting }
    private var deletionFences: [UUID: DeletionFence] = [:]
    private var deletionResolutionWaiters: [UUID: [CheckedContinuation<Bool, Never>]] = [:]
    private var retiredActivityIDs: Set<UUID> = []
    private var peerQueueLifecycleSubscription: UUID?
    private var canonicalSettingsValue: String?
    private var canonicalPayloadData: Data?
    private var storageAllowsMutation = false
    private var observers: [WeakObserver] = []

    var beforeBotRunDispatchForTesting: ((AgentRunID) -> Void)?
    var peerRunStartTimeoutForTesting: TimeInterval?
    #if DEBUG
    var peerHandoffMirrorCommitGateForTesting: ((Data) throws -> Void)?
    #endif

    init(
        botStore: BotStore,
        threadRepo: AgentThreadRepository,
        runRepo: AgentRunRepository,
        messageRepo: AgentMessageRepository,
        queuedMessageRepo: AgentQueuedMessageRepository,
        checkpointRepo: AgentTurnCheckpointRepository,
        settingsRepo: SettingsRepository,
        coordinator: AgentRunCoordinator,
        appSupportDirectory: URL,
        orchestrationRuntime: AgentOrchestrationRuntime? = nil
    ) {
        self.botStore = botStore
        self.threadRepo = threadRepo
        self.runRepo = runRepo
        self.messageRepo = messageRepo
        self.queuedMessageRepo = queuedMessageRepo
        self.checkpointRepo = checkpointRepo
        self.settingsRepo = settingsRepo
        self.coordinator = coordinator
        self.orchestrationRuntime = orchestrationRuntime
        self.appSupportDirectory = appSupportDirectory
        coordinator.addObserver(self)
        observePeerQueueLifecycle()
        reconcilePeerHandoffs()
    }

    deinit {
        tasksByActivityID.values.forEach { $0.cancel() }
        agentAppDispatchWaiters.values.flatMap { $0 }.forEach { $0.resume() }
        if let peerQueueLifecycleSubscription {
            EventBus.shared.unsubscribe(peerQueueLifecycleSubscription)
        }
        coordinator.removeObserver(self)
    }

    fileprivate func addObserver(_ observer: any BotPeerHandoffAuthorityObserver) {
        observers.removeAll { $0.value == nil || $0.value === observer }
        observers.append(WeakObserver(observer))
    }

    fileprivate func removeObserver(_ observer: any BotPeerHandoffAuthorityObserver) {
        observers.removeAll { $0.value == nil || $0.value === observer }
    }

    fileprivate func snapshot() -> [UUID: PersistedBotPeerHandoff] {
        refreshStorageProjection()
        return handoffs
    }

    func remoteAttentionOwnershipSnapshots() -> [[String: Any]] {
        refreshStorageProjection()
        var latestByPeer: [BotID: PersistedBotPeerHandoff] = [:]
        for handoff in handoffs.values where handoff.originBotID != nil {
            guard let existing = latestByPeer[handoff.peerBotID] else {
                latestByPeer[handoff.peerBotID] = handoff
                continue
            }
            if existing.createdAt < handoff.createdAt
                || (existing.createdAt == handoff.createdAt
                    && existing.activityID.uuidString < handoff.activityID.uuidString) {
                latestByPeer[handoff.peerBotID] = handoff
            }
        }
        return latestByPeer.values.compactMap(Self.remoteAttentionOwnershipSnapshot)
    }

    private static func remoteAttentionOwnershipSnapshot(
        _ handoff: PersistedBotPeerHandoff
    ) -> [String: Any]? {
        guard let peerThreadID = handoff.peerThreadID,
              let peerRunID = handoff.peerRunID,
              let originBotID = handoff.originBotID,
              let originConversationID = handoff.originConversationID else { return nil }
        let state: String
        let finishedAt: Any
        switch handoff.phase {
        case .peerPrepared, .peerRunning:
            state = "working"
            finishedAt = NSNull()
        case .needsAttention:
            state = "needs_attention"
            finishedAt = NSNull()
        case .peerCompleted, .hostPrepared, .hostRunning, .completed:
            guard let replyCreatedAt = handoff.replyCreatedAt else { return nil }
            state = "finished"
            finishedAt = replyCreatedAt.timeIntervalSince1970
        }
        var item: [String: Any] = [
            "id": handoff.activityID.uuidString.lowercased(),
            "lifecycle_receipt_id": handoff.activityID.uuidString.lowercased(),
            "bot_id": handoff.peerBotID.value.uuidString.lowercased(),
            "conversation_id": handoff.peerConversationID.value.uuidString.lowercased(),
            "thread_id": peerThreadID.value.uuidString.lowercased(),
            "run_id": peerRunID.value.uuidString.lowercased(),
            "owner_bot_id": originBotID.value.uuidString.lowercased(),
            "owner_conversation_id": originConversationID.value.uuidString.lowercased(),
            "state": state,
            "finished_at": finishedAt,
            "ownership": "delegated",
            "primary": false,
            "delegated": true,
            "source": "bot_peer_handoff",
            "peer_phase": handoff.phase.rawValue,
        ]
        if let ownerThreadID = handoff.hostThreadID {
            item["owner_thread_id"] = ownerThreadID.value.uuidString.lowercased()
        }
        if let ownerRunID = handoff.hostRunID {
            item["owner_run_id"] = ownerRunID.value.uuidString.lowercased()
        }
        return item
    }

    func claimContinuation(
        consultationID: UUID,
        callerThread: AgentThreadID,
        hostRunID: AgentRunID,
        peerBotID: BotID
    ) throws {
        refreshStorageProjection()
        if activeConsultationClaims.contains(consultationID)
            || handoffs.values.contains(where: {
                $0.consultationID == consultationID
                    && ($0.phase == .peerPrepared || $0.phase == .peerRunning)
            }) {
            throw JSONRPCError(
                code: -32051,
                message: "This Bot consultation already has a peer run in progress."
            )
        }
        guard continuationHandoff(
            consultationID: consultationID,
            callerThread: callerThread,
            hostRunID: hostRunID,
            peerBotID: peerBotID
        ) != nil else {
            throw JSONRPCError(
                code: -32050,
                message: "The consultation id is not valid for this active run and Bot."
            )
        }
        activeConsultationClaims.insert(consultationID)
    }

    func releaseContinuation(consultationID: UUID) {
        activeConsultationClaims.remove(consultationID)
    }

    private func continuationHandoff(
        consultationID: UUID,
        callerThread: AgentThreadID,
        hostRunID: AgentRunID,
        peerBotID: BotID
    ) -> PersistedBotPeerHandoff? {
        let candidates = handoffs.values.filter {
            $0.consultationID == consultationID
                && $0.peerBotID == peerBotID
                && $0.hostThreadID == callerThread
                && $0.hostRunID == hostRunID
                && $0.requiresHostContinuation
                && ($0.phase == .peerCompleted || $0.phase == .completed)
        }
        guard let handoff = candidates.max(by: { lhs, rhs in
            lhs.createdAt == rhs.createdAt
                ? lhs.activityID.uuidString < rhs.activityID.uuidString
                : lhs.createdAt < rhs.createdAt
        }),
              let conversation = try? botStore.conversation(id: handoff.peerConversationID),
              conversation.botID == peerBotID,
              let peerThreadID = handoff.peerThreadID,
              conversation.linkedAgentThreadID == peerThreadID,
              (try? threadRepo.status(of: peerThreadID)) != nil else {
            return nil
        }
        return handoff
    }

    /// Grants an active primary run access only to peers it actually consulted.
    /// A requested id is required when that run consulted more than one peer.
    func delegatedBotID(forHostRunID runID: AgentRunID, requestedBotID: BotID? = nil) -> BotID? {
        refreshStorageProjection()
        let ids = Set(handoffs.values.compactMap { handoff -> BotID? in
            guard handoff.requiresHostContinuation,
                  handoff.hostRunID == runID,
                  (handoff.phase == .peerCompleted
                    || handoff.phase == .hostPrepared
                    || handoff.phase == .hostRunning
                    || handoff.phase == .completed) else { return nil }
            return handoff.peerBotID
        })
        if let requestedBotID { return ids.contains(requestedBotID) ? requestedBotID : nil }
        return ids.count == 1 ? ids.first : nil
    }

    func delegatedBotID(forAgentAppHostRunID runID: AgentRunID) -> BotID? {
        delegatedBotID(forHostRunID: runID)
    }

    func replyText(forActivityID activityID: UUID) -> String? {
        refreshStorageProjection()
        return handoffs[activityID]?.replyText
    }

    func submitAgentAppMention(
        peer: BotDefinition,
        text: String,
        peerText: String,
        originThread: AgentThread,
        activityID: AgentMessageID,
        hostRunID: AgentRunID?,
        providerSnapshots: [AgentProviderSnapshot],
        resumeHostAfterPeer: Bool,
        originBot: BotDefinition? = nil,
        originConversation: BotConversation? = nil,
        consultationID: UUID? = nil,
        continuationConversationID: BotConversationID? = nil,
        continuationPeerThreadID: AgentThreadID? = nil
    ) -> Task<Void, Never>? {
        let display = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let peerDisplay = peerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !display.isEmpty,
              !peerDisplay.isEmpty,
              let router,
              let revisionID = peer.currentRevisionID,
              let revision = try? botStore.getRevision(id: revisionID) else {
            if originConversation == nil {
                projectAgentAppNeedsAttention(peer: peer, threadID: originThread.id, activityID: activityID)
            }
            return nil
        }

        let activeCallerRoute: AgentRunRepository.RouteChrome?
        if let hostRunID,
           let route = try? runRepo.route(of: hostRunID),
           route.threadId == originThread.id {
            activeCallerRoute = route
        } else {
            activeCallerRoute = nil
        }
        var conversation = BotConversation(
            botID: peer.id,
            title: Self.titleFromFirstMessage(peerDisplay)
        )
        let peerRunID = AgentRunID()
        do {
            let thread: AgentThread
            let routing: BotDeskRouting
            if let continuationConversationID {
                guard let existing = try botStore.conversation(id: continuationConversationID),
                      existing.botID == peer.id,
                      let existingThreadID = existing.linkedAgentThreadID,
                      existingThreadID == continuationPeerThreadID,
                      let existingThread = try threadRepo.get(id: existingThreadID) else {
                    return nil
                }
                conversation = existing
                thread = existingThread
                routing = BotDeskRouting(thread: existingThread)
            } else {
                conversation = BotConversation(
                    botID: peer.id,
                    title: Self.titleFromFirstMessage(peerDisplay)
                )
                routing = BotDeskRouting(thread: originThread, activeRunRoute: activeCallerRoute)
                var peerInheritanceContext = originThread
                peerInheritanceContext.workspaceId = nil
                try botStore.upsertConversation(conversation)
                thread = try router.createAgentThread(
                    workspace: nil,
                    title: conversation.title,
                    provider: routing.provider,
                    model: routing.resolvedModel(defaultModel: BotsViewModel.defaultModel(for:)),
                    permissionMode: routing.permissionMode,
                    reasoningEffort: routing.reasoningEffort,
                    serviceTier: routing.serviceTier,
                    modelSelection: AgentModelSelection(
                        provider: routing.provider,
                        modelId: routing.resolvedModel(defaultModel: BotsViewModel.defaultModel(for:)),
                        reasoningEffort: routing.reasoningEffort,
                        serviceTier: routing.serviceTier,
                        distillMainEffortSelection: routing.provider == .distill
                            ? (routing.distillMainEffortSelection ?? .fixed(routing.reasoningEffort)) : nil,
                        distillReasoningEffortSelection: routing.provider == .distill
                            ? (routing.distillReasoningEffortSelection ?? .automatic) : nil
                    ),
                    providerInstanceId: routing.providerInstanceID,
                    runAsUser: routing.runAsUser,
                    surfaceID: nil,
                    routingConfiguration: peerRoutingConfiguration(routing),
                    quiet: true,
                    inheriting: peerInheritanceContext
                )
                conversation.linkedAgentThreadID = thread.id
                try botStore.upsertConversation(conversation)
            }

            let createdAt = originConversation == nil
                ? ((try? messageRepo.get(id: activityID))?.createdAt ?? Date())
                : Date()
            let handoff = PersistedBotPeerHandoff(
                version: 2,
                activityID: activityID.value,
                consultationID: consultationID ?? UUID(),
                originBotID: originBot?.id,
                originConversationID: originConversation?.id,
                originAgentThreadID: originConversation == nil ? originThread.id : nil,
                peerBotID: peer.id,
                peerConversationID: conversation.id,
                peerThreadID: thread.id,
                peerRunID: peerRunID,
                inboundMessageID: originConversation == nil ? activityID.value : UUID(),
                peerName: peer.name,
                peerTitle: peer.title,
                peerHandle: peer.handle,
                peerAvatarSymbol: peer.avatarSymbol,
                outboundText: peerDisplay,
                hostInstructionText: hostRunID == nil ? nil : display,
                createdAt: createdAt,
                peerRoute: BotPeerHandoffRoute(routing),
                hostContinuationRequired: hostRunID != nil,
                hostThreadID: hostRunID == nil ? nil : originThread.id,
                hostRunID: hostRunID,
                hostRoute: hostRunID == nil ? nil : BotPeerHandoffRoute(routing),
                replyText: nil,
                replyCreatedAt: nil,
                phase: .peerPrepared
            )
            var candidate = handoffs
            candidate[activityID.value] = handoff
            guard replaceSnapshot(candidate) else {
                markConversationNeedsAttention(conversation, detail: display)
                if originConversation == nil {
                    projectAgentAppNeedsAttention(peer: peer, threadID: originThread.id, activityID: activityID)
                }
                return nil
            }

            if let hostRunID {
                // Delegated worker, not a primary thread: excluded from the
                // Active Threads badge and stopped when the host stops. The
                // thread id lets the cascade arm a stop even before the
                // provider start finishes (pendingThreadStops).
                coordinator.registerDelegatedRun(
                    peerRunID,
                    threadId: thread.id,
                    parentRunId: hostRunID
                )
                // Telemetry-only Subagents row on the HOST thread (no
                // capability digests — can never authorize descendants).
                if let telemetry = try? orchestrationRuntime?.recordBotDelegationTelemetry(
                    runId: peerRunID,
                    hostThreadId: originThread.id,
                    nodeId: "bot.\(peer.handle).\(peerRunID.value.uuidString)",
                    provider: routing.provider,
                    providerInstanceId: routing.providerInstanceID,
                    model: routing.resolvedModel(defaultModel: BotsViewModel.defaultModel(for:)),
                    reasoningEffort: routing.reasoningEffort,
                    permissionMode: routing.permissionMode
                ) {
                    delegationReceiptIDs[peerRunID] = telemetry.id
                }
                // Race guard: a Stop that landed between handoff persist and
                // registration already fired its cascade without seeing this
                // child. Abort dispatch only on durable PROOF the host was
                // stopped — cancelled/interrupted terminal row. Completed and
                // unknown hosts still dispatch (late replies stay useful).
                if let status = try? runRepo.status(of: hostRunID),
                   status == .cancelled || status == .interrupted {
                    coordinator.stopRun(threadId: thread.id)
                    finalizeDelegationTelemetry(runID: peerRunID, status: .cancelled)
                    markConversationNeedsAttention(conversation, detail: display)
                    if originConversation == nil {
                        setPhase(activityID.value, .needsAttention)
                    }
                    return nil
                }
            }

            let home = BotHome(appSupportDirectory: appSupportDirectory, bot: peer)
            let memoryFiles = ((try? home.readBootstrapMemory()) ?? []).map {
                BotMemoryFileText(path: $0.path, body: $0.body)
            }
            let ownedSkills = ((try? home.listOwnedSkills()) ?? []).map {
                BotOwnedSkillText(slug: $0.slug, body: $0.body)
            }
            let browserStore = BotBrowserStore(appSupportDirectory: appSupportDirectory)
            let browser = try? browserStore.loadTarget(botID: peer.id)
            let executionCwd: String?
            if originConversation == nil,
               originThread.workspaceId != nil || originThread.executionMode == .worktree {
                executionCwd = try router.effectiveAgentExecutionCwd(for: originThread)
            } else {
                executionCwd = nil
            }
            let started = BotStartedRun(
                conversation: conversation,
                thread: thread,
                runID: peerRunID,
                routing: routing
            )
            let peerPlan = BotPeerRunPlan(
                bot: peer,
                revision: revision,
                started: started,
                memoryFiles: memoryFiles,
                skills: (try? botStore.listSkillBindings(botID: peer.id)) ?? [],
                ownedSkills: ownedSkills,
                routines: (try? botStore.listRoutines(botID: peer.id)) ?? [],
                browser: browser ?? nil,
                attachments: [],
                providerSnapshots: providerSnapshots,
                executionCwd: executionCwd
            )
            submit(
                BotPeerExecutionPlan(
                    activityID: activityID.value,
                    peer: peer,
                    peerRun: peerPlan,
                    peerReceipt: peerPlan.receipt(userText: peerDisplay),
                    host: resumeHostAfterPeer ? hostRunID.map {
                        .agentApp(BotPeerAgentAppHostPlan(thread: originThread, runID: $0))
                    } : nil
                )
            )
            return Task { @MainActor [weak self] in
                await self?.awaitAgentAppDispatch(activityID: activityID.value)
            }
        } catch {
            markConversationNeedsAttention(conversation, detail: display)
            if originConversation == nil {
                projectAgentAppNeedsAttention(peer: peer, threadID: originThread.id, activityID: activityID)
            }
            return nil
        }
    }

    func askPeerFromActiveProvider(
        peer: BotDefinition,
        prompt: String,
        originThread: AgentThread,
        hostRunID: AgentRunID,
        providerSnapshots: [AgentProviderSnapshot],
        consultationID: UUID? = nil
    ) async -> (
        activityID: UUID,
        reply: String,
        consultationID: UUID,
        peerConversationID: BotConversationID,
        peerThreadID: AgentThreadID,
        peerRunID: AgentRunID
    )? {
        refreshStorageProjection()
        let originConversation = try? botStore.conversationLinked(to: originThread.id)
        let originBot = originConversation.flatMap { try? botStore.get(id: $0.botID) }
        if originConversation != nil, originBot == nil { return nil }
        let continuation = consultationID.flatMap {
            continuationHandoff(
                consultationID: $0,
                callerThread: originThread.id,
                hostRunID: hostRunID,
                peerBotID: peer.id
            )
        }
        if let consultationID {
            guard continuation != nil,
                  activeConsultationClaims.contains(consultationID) else { return nil }
        }

        let activityID = AgentMessageID()
        if originConversation == nil {
            guard persistAgentAppProjection(
                peer: peer,
                threadID: originThread.id,
                activityID: activityID,
                content: BotPeerTranscript.encodeActivity(peer: peer, phase: .waiting),
                createdAt: Date()
            ) else { return nil }
        }
        guard let milestone = submitAgentAppMention(
            peer: peer,
            text: prompt,
            peerText: prompt,
            originThread: originThread,
            activityID: activityID,
            hostRunID: hostRunID,
            providerSnapshots: providerSnapshots,
            resumeHostAfterPeer: false,
            originBot: originBot,
            originConversation: originConversation,
            consultationID: consultationID,
            continuationConversationID: continuation?.peerConversationID,
            continuationPeerThreadID: continuation?.peerThreadID
        ) else { return nil }
        await milestone.value
        guard let reply = replyText(forActivityID: activityID.value),
              let handoff = handoffs[activityID.value],
              let consultationID = handoff.consultationID,
              let peerThreadID = handoff.peerThreadID,
              let peerRunID = handoff.peerRunID else { return nil }
        return (
            activityID.value,
            reply,
            consultationID,
            handoff.peerConversationID,
            peerThreadID,
            peerRunID
        )
    }

    private func awaitAgentAppDispatch(activityID: UUID) async {
        await withCheckedContinuation { continuation in
            agentAppDispatchWaiters[activityID, default: []].append(continuation)
            if agentAppDispatchReachedMilestone(activityID) {
                resolveAgentAppDispatchWaiters(activityID: activityID)
            }
        }
    }

    /// Marks the delegated peer's Subagents telemetry row terminal, targeting
    /// the exact receipt id recorded at dispatch. Safe when no row exists
    /// (fixtures, pre-wiring handoffs, relaunch — the 4h lease demotes those).
    private func finalizeDelegationTelemetry(runID: AgentRunID, status: AgentRunStatus) {
        guard let orchestrationRuntime,
              let receiptID = delegationReceiptIDs.removeValue(forKey: runID) else { return }
        let terminal: AgentRunStatus
        switch status {
        case .completed, .failed, .cancelled, .interrupted:
            terminal = status
        case .pending, .running:
            terminal = .interrupted
        }
        try? orchestrationRuntime.finalizeBotDelegationReceipt(id: receiptID, status: terminal)
    }

    /// A host run that stopped (user Stop / relaunch interrupt) must not leave
    /// its consulted peers running: their waiting rows would spin forever and
    /// the bot desks would stay "working" with nobody to consume the reply.
    /// Completed/failed hosts keep peers alive — a late reply still lands in
    /// the transcript and is useful. Pre-start children are covered by the
    /// coordinator's registered-thread cascade; this backstop stops by run.
    private func stopOrphanedPeerRuns(hostRunID: AgentRunID, status: AgentRunStatus) {
        guard status == .cancelled || status == .interrupted else { return }
        for handoff in handoffs.values
        where handoff.hostRunID == hostRunID
            && (handoff.phase == .peerPrepared || handoff.phase == .peerRunning) {
            if let peerRunID = handoff.peerRunID {
                coordinator.stopRun(peerRunID)
            }
        }
    }

    private func agentAppDispatchReachedMilestone(_ activityID: UUID) -> Bool {
        guard let phase = handoffs[activityID]?.phase else { return true }
        return phase == .hostRunning || phase == .completed || phase == .needsAttention
    }

    private func resolveAgentAppDispatchWaiters(activityID: UUID, force: Bool = false) {
        guard force || agentAppDispatchReachedMilestone(activityID) else { return }
        let waiters = agentAppDispatchWaiters.removeValue(forKey: activityID) ?? []
        waiters.forEach { $0.resume() }
    }

    private static func titleFromFirstMessage(_ text: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.count <= 72 ? collapsed : String(collapsed.prefix(72))
    }

    func beginDeletion(originBotID: BotID) -> UUID {
        beginDeletion(originBotID: originBotID, threadIDs: [])
    }

    func beginDeletion(threadIDs: Set<AgentThreadID>) -> UUID {
        beginDeletion(originBotID: nil, threadIDs: threadIDs)
    }

    func rollbackDeletion(_ token: UUID) {
        guard deletionFences.removeValue(forKey: token) != nil else { return }
        resolveDeletionWaiters()
    }

    @discardableResult
    func commitDeletion(_ token: UUID) -> Bool {
        guard let fence = deletionFences[token] else { return true }
        var rows = fence.rows
        for (activityID, handoff) in handoffs where fence.matches(handoff) {
            rows[activityID] = handoff
        }

        let activityIDs = Set(rows.keys)
        retiredActivityIDs.formUnion(activityIDs)
        deletionFences[token] = nil

        var candidate = handoffs
        for activityID in activityIDs {
            candidate[activityID] = nil
        }
        let persisted = replaceSnapshot(candidate)

        var runIDs: Set<AgentRunID> = []
        for (activityID, handoff) in rows {
            tasksByActivityID.removeValue(forKey: activityID)?.cancel()
            resolveAgentAppDispatchWaiters(activityID: activityID, force: true)
            if let peerRunID = handoff.peerRunID {
                cancelExactRunWait(peerRunID)
                runIDs.insert(peerRunID)
                // The execute() loop was cancelled above, so it can no longer
                // finalize the Subagents telemetry row itself.
                finalizeDelegationTelemetry(runID: peerRunID, status: .cancelled)
            }
            if let hostRunID = handoff.hostRunID {
                cancelExactRunWait(hostRunID)
                runIDs.insert(hostRunID)
            }
        }
        runIDs.forEach(coordinator.stopRun)
        resolveDeletionWaiters()
        return persisted
    }

    private func beginDeletion(
        originBotID: BotID?,
        threadIDs: Set<AgentThreadID>
    ) -> UUID {
        let token = UUID()
        let selector = DeletionFence(originBotID: originBotID, threadIDs: threadIDs, rows: [:])
        let rows = handoffs.filter { selector.matches($0.value) }
        deletionFences[token] = DeletionFence(
            originBotID: originBotID,
            threadIDs: threadIDs,
            rows: rows
        )
        return token
    }

    private func isDeletionBlocked(_ activityID: UUID) -> Bool {
        if retiredActivityIDs.contains(activityID) { return true }
        return deletionFences.values.contains { fence in
            fence.activityIDs.contains(activityID)
                || handoffs[activityID].map(fence.matches) == true
        }
    }

    private func awaitDeletionResolution(activityID: UUID) async -> Bool {
        if retiredActivityIDs.contains(activityID) { return false }
        guard isDeletionBlocked(activityID) else { return true }
        return await withCheckedContinuation { continuation in
            if retiredActivityIDs.contains(activityID) {
                continuation.resume(returning: false)
            } else if isDeletionBlocked(activityID) {
                deletionResolutionWaiters[activityID, default: []].append(continuation)
            } else {
                continuation.resume(returning: true)
            }
        }
    }

    private func resolveDeletionWaiters() {
        for activityID in Array(deletionResolutionWaiters.keys) {
            let result: Bool?
            if retiredActivityIDs.contains(activityID) {
                result = false
            } else if !isDeletionBlocked(activityID) {
                result = true
            } else {
                result = nil
            }
            guard let result else { continue }
            let waiters = deletionResolutionWaiters.removeValue(forKey: activityID) ?? []
            waiters.forEach { $0.resume(returning: result) }
        }
    }

    @discardableResult
    fileprivate func replaceSnapshot(_ candidate: [UUID: PersistedBotPeerHandoff]) -> Bool {
        guard storageAllowsMutation,
              let expectedValue = canonicalSettingsValue,
              let expectedData = canonicalPayloadData,
              candidate.allSatisfy({ $0.value.version == 2 && $0.value.activityID == $0.key }),
              let data = try? Self.encodeJSON(candidate) else { return false }
        let nextValue = Self.canonicalValue(for: data)
        do {
            let committed = try settingsRepo.compareAndSetTransactionally(
                Self.defaultsKey,
                expectedValue: expectedValue,
                value: nextValue
            ) { [self] in
                try commitCandidateMirror(data, expectedData: expectedData)
            }
            guard committed else {
                refreshStorageProjection()
                return false
            }
            canonicalSettingsValue = nextValue
            canonicalPayloadData = data
            storageAllowsMutation = true
            adoptStorageRows(candidate)
            return true
        } catch {
            refreshStorageProjection()
            return false
        }
    }

    private func refreshStorageProjection() {
        canonicalPayloadData = nil
        storageAllowsMutation = false
        var storedValue = try? settingsRepo.get(Self.defaultsKey)
        let initialMirror = UserDefaults.standard.data(forKey: Self.defaultsKey)
        if storedValue == nil {
            let initialData = initialMirror ?? Self.emptyPayload
            let initialValue = Self.canonicalValue(for: initialData)
            do {
                let inserted = try settingsRepo.compareAndSetTransactionally(
                    Self.defaultsKey,
                    expectedValue: nil,
                    value: initialValue
                ) {
                    if initialMirror == initialData { return }
                    guard Self.writeMirror(initialData) else {
                        throw StorageError.mirrorCommitFailed
                    }
                }
                storedValue = inserted ? initialValue : try settingsRepo.get(Self.defaultsKey)
            } catch {
                storedValue = try? settingsRepo.get(Self.defaultsKey)
            }
        }

        guard let storedValue else {
            canonicalSettingsValue = nil
            adoptStorageRows(Self.decodePayload(initialMirror ?? Data()).rows)
            return
        }
        canonicalSettingsValue = storedValue
        guard let canonicalData = Self.rawData(from: storedValue) else {
            adoptStorageRows(Self.decodePayload(initialMirror ?? Data()).rows)
            return
        }

        let canonical = Self.decodePayload(canonicalData)
        let mirror = UserDefaults.standard.data(forKey: Self.defaultsKey)
        if mirror == canonicalData {
            canonicalPayloadData = canonical.isSupported ? canonicalData : nil
            storageAllowsMutation = canonical.isSupported
            adoptStorageRows(canonical.rows)
            return
        }

        guard canonical.isSupported else {
            adoptStorageRows(Self.decodePayload(mirror ?? canonicalData).rows)
            return
        }
        if let mirror {
            let mirrored = Self.decodePayload(mirror)
            guard mirrored.isSupported else {
                adoptStorageRows(mirrored.rows)
                return
            }
        }
        guard Self.writeMirror(canonicalData) else {
            adoptStorageRows(canonical.rows)
            return
        }
        canonicalPayloadData = canonicalData
        storageAllowsMutation = true
        adoptStorageRows(canonical.rows)
    }

    private func commitCandidateMirror(_ data: Data, expectedData: Data) throws {
        guard UserDefaults.standard.data(forKey: Self.defaultsKey) == expectedData else {
            throw StorageError.mirrorCommitFailed
        }
        #if DEBUG
        if let peerHandoffMirrorCommitGateForTesting {
            try peerHandoffMirrorCommitGateForTesting(data)
            return
        }
        #endif
        guard Self.writeMirror(data) else { throw StorageError.mirrorCommitFailed }
    }

    private static func writeMirror(_ data: Data) -> Bool {
        UserDefaults.standard.set(data, forKey: defaultsKey)
        return UserDefaults.standard.synchronize()
            && UserDefaults.standard.data(forKey: defaultsKey) == data
    }

    private static func canonicalValue(for data: Data) -> String {
        canonicalPrefix + data.base64EncodedString()
    }

    private static func rawData(from value: String) -> Data? {
        guard value.hasPrefix(canonicalPrefix) else { return nil }
        return Data(base64Encoded: String(value.dropFirst(canonicalPrefix.count)))
    }

    private static func decodePayload(_ data: Data) -> StoredPayload {
        guard let decoded = try? Self.decodeJSON(
            [UUID: PersistedBotPeerHandoff].self,
            from: data
        ) else {
            return StoredPayload(rows: [:], isSupported: false)
        }
        let rows = decoded.filter { $0.value.version == 2 }
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [Any],
              entries.count.isMultiple(of: 2) else {
            return StoredPayload(rows: rows, isSupported: false)
        }
        var keyCount = 0
        var recordCount = 0
        for entry in entries {
            if let key = entry as? String, UUID(uuidString: key) != nil {
                keyCount += 1
                continue
            }
            guard let record = entry as? [String: Any],
                  Set(record.keys).isSubset(of: knownRecordFields),
                  (record["version"] as? NSNumber)?.intValue == 2 else {
                return StoredPayload(rows: rows, isSupported: false)
            }
            recordCount += 1
        }
        return StoredPayload(
            rows: rows,
            isSupported: keyCount == recordCount && recordCount == decoded.count
        )
    }

    private func adoptStorageRows(_ candidate: [UUID: PersistedBotPeerHandoff]) {
        let adopted: [UUID: PersistedBotPeerHandoff]
        if retiredActivityIDs.contains(where: { candidate[$0] != nil }) {
            var filtered = candidate
            for activityID in retiredActivityIDs {
                filtered[activityID] = nil
            }
            adopted = filtered
        } else {
            adopted = candidate
        }
        let previous = handoffs
        handoffs = adopted
        observers.removeAll { $0.value == nil }
        guard !observers.isEmpty else { return }
        let activityIDs = Set(previous.keys).union(adopted.keys).sorted {
            $0.uuidString < $1.uuidString
        }
        for activityID in activityIDs where previous[activityID] != adopted[activityID] {
            publish(
                BotPeerHandoffDelta(
                    activityID: activityID,
                    previous: previous[activityID],
                    current: adopted[activityID],
                    errorMessage: nil
                )
            )
        }
    }

    fileprivate func submit(_ plan: BotPeerExecutionPlan) {
        guard tasksByActivityID[plan.activityID] == nil else { return }
        armExactRun(plan.peerRun.started.runID)
        if let host = plan.host {
            armExactRun(host.runID)
        }
        tasksByActivityID[plan.activityID] = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.execute(plan)
            self.tasksByActivityID[plan.activityID] = nil
        }
    }

    private func execute(_ plan: BotPeerExecutionPlan) async {
        guard await awaitDeletionResolution(activityID: plan.activityID) else { return }
        guard await start(plan.peerRun, receipt: plan.peerReceipt, activityID: plan.activityID) else {
            // The run never started, so no coordinator terminal will ever fire:
            // settle the Subagents telemetry row here or it stays Working.
            finalizeDelegationTelemetry(runID: plan.peerRun.started.runID, status: .failed)
            guard await awaitDeletionResolution(activityID: plan.activityID) else { return }
            markConversationNeedsAttention(
                plan.peerRun.started.conversation,
                detail: plan.peerReceipt.compiledPayload
            )
            setPhase(plan.activityID, .needsAttention)
            return
        }
        setPhase(plan.activityID, .peerRunning)
        let peerRun = await awaitExactRunTerminal(
            runID: plan.peerRun.started.runID,
            threadID: plan.peerRun.started.thread.id
        )
        finalizeDelegationTelemetry(
            runID: plan.peerRun.started.runID,
            status: peerRun?.status ?? .cancelled
        )
        guard await awaitDeletionResolution(activityID: plan.activityID) else { return }
        settleConversation(plan.peerRun.started.conversation, run: peerRun)
        guard peerRun?.status == .completed,
              let replyMessage = exactAssistantMessage(
                threadID: plan.peerRun.started.thread.id,
                runID: plan.peerRun.started.runID
              ),
              setReply(plan.activityID, message: replyMessage) else {
            setPhase(plan.activityID, .needsAttention)
            return
        }
        if handoffs[plan.activityID]?.originAgentThreadID != nil,
           !projectAgentAppReply(activityID: plan.activityID) {
            projectAgentAppNeedsAttention(activityID: plan.activityID)
            setPhase(plan.activityID, .needsAttention, projectAttention: false)
            resolveAgentAppDispatchWaiters(activityID: plan.activityID, force: true)
            return
        }
        guard let host = plan.host else {
            setPhase(plan.activityID, .completed)
            return
        }

        let hop = BotPeerTranscript.hostHopPrompt(
            peerName: plan.peer.name,
            reply: replyMessage.content,
            userText: handoffs[plan.activityID]?.resolvedHostInstructionText ?? ""
        )
        switch host {
        case .desk(let hostRun):
            setPhase(plan.activityID, .hostPrepared)
            let hostReceipt = hostRun.receipt(userText: hop)
            guard await start(hostRun, receipt: hostReceipt, activityID: plan.activityID) else {
                guard await awaitDeletionResolution(activityID: plan.activityID) else { return }
                markConversationNeedsAttention(hostRun.started.conversation, detail: hop)
                setPhase(plan.activityID, .needsAttention)
                return
            }
            setPhase(plan.activityID, .hostRunning)
            let finishedHostRun = await awaitExactRunTerminal(
                runID: hostRun.started.runID,
                threadID: hostRun.started.thread.id
            )
            guard await awaitDeletionResolution(activityID: plan.activityID),
                  let current = handoffs[plan.activityID],
                  (current.phase == .peerCompleted
                    || current.phase == .hostPrepared
                    || current.phase == .hostRunning),
                  current.hostThreadID == hostRun.started.thread.id,
                  current.hostRunID == hostRun.started.runID else { return }
            settleConversation(hostRun.started.conversation, run: finishedHostRun)
            setPhase(
                plan.activityID,
                hostRunCompletedExactly(
                    finishedHostRun,
                    threadID: hostRun.started.thread.id,
                    runID: hostRun.started.runID
                ) ? .completed : .needsAttention
            )
        case .agentApp(let hostRun):
            setPhase(plan.activityID, .hostPrepared)
            guard await startAgentAppHost(
                hostRun,
                hop: hop,
                activityID: plan.activityID
            ) else {
                guard await awaitDeletionResolution(activityID: plan.activityID) else { return }
                setPhase(plan.activityID, .needsAttention)
                return
            }
            setPhase(plan.activityID, .hostRunning)
            let finishedHostRun = await awaitExactRunTerminal(
                runID: hostRun.runID,
                threadID: hostRun.thread.id
            )
            guard await awaitDeletionResolution(activityID: plan.activityID),
                  let current = handoffs[plan.activityID],
                  (current.phase == .peerCompleted
                    || current.phase == .hostPrepared
                    || current.phase == .hostRunning),
                  current.hostThreadID == hostRun.thread.id,
                  current.hostRunID == hostRun.runID else { return }
            setPhase(
                plan.activityID,
                hostRunCompletedExactly(
                    finishedHostRun,
                    threadID: hostRun.thread.id,
                    runID: hostRun.runID
                ) ? .completed : .needsAttention
            )
        }
    }

    private func start(
        _ plan: BotPeerRunPlan,
        receipt: ContextAssemblyReceipt,
        activityID: UUID
    ) async -> Bool {
        guard await awaitDeletionResolution(activityID: activityID) else { return false }
        guard let router else { return false }
        if !plan.providerSnapshots.isEmpty {
            router.rememberProviderSnapshotsForSend(plan.providerSnapshots)
        }
        beforeBotRunDispatchForTesting?(plan.started.runID)
        do {
            let result = try await sendPeerRunWithDeadline(
                plan,
                receipt: receipt,
                router: router
            )
            guard result.runId == plan.started.runID else {
                cancelExactRunWait(plan.started.runID)
                return false
            }
            guard await awaitDeletionResolution(activityID: activityID) else {
                coordinator.stopRun(plan.started.runID)
                cancelExactRunWait(plan.started.runID)
                return false
            }
            markConversationWorking(plan.started.conversation)
            var persistedReceipt = receipt
            _ = try? botStore.insertContextReceipt(persistedReceipt)
            persistedReceipt.runID = plan.started.runID
            _ = try? botStore.insertContextReceipt(persistedReceipt)
            return true
        } catch {
            cancelExactRunWait(plan.started.runID)
            return false
        }
    }

    private func sendPeerRunWithDeadline(
        _ plan: BotPeerRunPlan,
        receipt: ContextAssemblyReceipt,
        router: AppCommandRouter
    ) async throws -> AgentMessageSendResult {
        let threadID = plan.started.thread.id
        let runID = plan.started.runID
        let timeout = max(
            0.001,
            peerRunStartTimeoutForTesting ?? Self.peerRunStartTimeout
        )
        let race = BotPeerRunStartRace()
        coordinator.reserveProviderStart(threadId: threadID, runId: runID)

        let outcome: BotPeerRunStartRace.Outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.install(continuation)

                let sendTask = Task { @MainActor [coordinator] in
                    defer {
                        coordinator.discardProviderStartReservation(
                            threadId: threadID,
                            runId: runID
                        )
                    }
                    do {
                        let routing = plan.started.routing
                        let result = try await router.sendAgentMessage(
                            thread: threadID,
                            text: receipt.compiledPayload,
                            provider: routing.provider,
                            model: routing.resolvedModel(
                                defaultModel: BotsViewModel.defaultModel(for:)
                            ),
                            permissionMode: routing.permissionMode,
                            reasoningEffort: routing.reasoningEffort,
                            serviceTier: routing.serviceTier,
                            modelSelection: AgentModelSelection(
                                provider: routing.provider,
                                modelId: routing.resolvedModel(
                                    defaultModel: BotsViewModel.defaultModel(for:)
                                ),
                                reasoningEffort: routing.reasoningEffort,
                                serviceTier: routing.serviceTier,
                                distillMainEffortSelection: routing.provider == .distill
                                    ? (routing.distillMainEffortSelection ?? .fixed(routing.reasoningEffort)) : nil,
                                distillReasoningEffortSelection: routing.provider == .distill
                                    ? (routing.distillReasoningEffortSelection ?? .automatic) : nil
                            ),
                            providerInstanceId: routing.providerInstanceID,
                            attachments: plan.attachments,
                            requestedRunID: runID,
                            orchestrationRoutingSnapshot: peerOrchestrationRoutingSnapshot(plan),
                            executionCwdOverride: plan.executionCwd,
                            allowProviderCatalogListingDuringPreflight: false
                        )
                        race.resolve(.success(result))
                    } catch {
                        race.resolve(.failure(error))
                    }
                }
                race.add(sendTask)

                let timeoutTask = Task { [coordinator] in
                    let nanoseconds = UInt64(
                        min(Double(UInt64.max), timeout * 1_000_000_000)
                    )
                    do {
                        try await Task.sleep(nanoseconds: nanoseconds)
                    } catch {
                        return
                    }
                    coordinator.stopRun(threadId: threadID)
                    race.resolve(.failure(BotPeerRunStartDeadlineError.exceeded))
                }
                race.add(timeoutTask)
            }
        } onCancel: {
            coordinator.stopRun(threadId: threadID)
            race.resolve(.failure(CancellationError()))
        }
        return try outcome.get()
    }

    private func peerRoutingConfiguration(
        _ routing: BotDeskRouting
    ) -> AgentRoutingConfiguration? {
        guard routing.routingMode == .auto else { return nil }
        let model = routing.resolvedModel(defaultModel: BotsViewModel.defaultModel(for:))
        return AgentRoutingConfiguration(
            mode: .auto,
            manualSelection: AgentModelSelection(
                provider: routing.provider,
                modelId: model,
                reasoningEffort: routing.reasoningEffort,
                serviceTier: routing.serviceTier,
                distillMainEffortSelection: routing.provider == .distill
                    ? (routing.distillMainEffortSelection ?? .fixed(routing.reasoningEffort)) : nil,
                distillReasoningEffortSelection: routing.provider == .distill
                    ? (routing.distillReasoningEffortSelection ?? .automatic) : nil
            ),
            manualProviderInstanceId: routing.providerInstanceID,
            eligibleProviders: [routing.provider],
            policyDigest: orchestrationRuntime?.policyDigest ?? "",
            revision: 1
        )
    }

    private func peerOrchestrationRoutingSnapshot(
        _ plan: BotPeerRunPlan
    ) -> AgentOrchestrationRoutingSnapshot? {
        let configuration = plan.started.thread.effectiveRoutingConfiguration
        guard configuration.mode == .auto else { return nil }
        let snapshots: [AgentProviderSnapshot]
        if plan.providerSnapshots.isEmpty {
            let routing = plan.started.routing
            let model = routing.resolvedModel(defaultModel: BotsViewModel.defaultModel(for:))
            snapshots = [AgentProviderSnapshotFactory.snapshot(
                provider: routing.provider,
                models: [AgentModelDescriptor(
                    id: model,
                    label: model,
                    provider: routing.provider,
                    supportsReasoning: true
                )],
                id: routing.providerInstanceID,
                modelDiscoverySource: .builtInFallback
            )]
        } else {
            snapshots = plan.providerSnapshots
        }
        return AgentOrchestrationRoutingSnapshot(
            configuration: configuration,
            providerSnapshots: snapshots
        )
    }

    private func startAgentAppHost(
        _ plan: BotPeerAgentAppHostPlan,
        hop: String,
        activityID: UUID
    ) async -> Bool {
        guard await awaitDeletionResolution(activityID: activityID), let router else { return false }
        let thread = plan.thread
        router.recordAgentAppHop(hop)
        do {
            let result = try await router.sendAgentMessage(
                thread: thread.id,
                text: hop,
                provider: thread.provider,
                model: thread.model,
                permissionMode: thread.permissionMode,
                reasoningEffort: thread.reasoningEffort,
                serviceTier: thread.serviceTier,
                interactionMode: thread.effectiveInteractionMode,
                modelSelection: thread.modelSelection,
                providerInstanceId: thread.providerInstanceId,
                requestedRunID: plan.runID,
                routingSnapshot: AgentQueuedMessageRoutingSnapshot(
                    configuration: thread.effectiveRoutingConfiguration,
                    permissionMode: thread.permissionMode
                )
            )
            guard result.runId == plan.runID else {
                cancelExactRunWait(plan.runID)
                return false
            }
            guard await awaitDeletionResolution(activityID: activityID) else {
                coordinator.stopRun(plan.runID)
                cancelExactRunWait(plan.runID)
                return false
            }
            return true
        } catch {
            cancelExactRunWait(plan.runID)
            return false
        }
    }

    private func projectAgentAppReply(activityID: UUID) -> Bool {
        guard let handoff = handoffs[activityID],
              let threadID = handoff.originAgentThreadID,
              let reply = handoff.replyText else { return false }
        let peer = BotDefinition(
            id: handoff.peerBotID,
            handle: handoff.peerHandle,
            name: handoff.peerName,
            title: handoff.peerTitle,
            description: "",
            avatarSymbol: handoff.peerAvatarSymbol ?? "person.crop.circle"
        )
        return persistAgentAppProjection(
            peer: peer,
            threadID: threadID,
            activityID: AgentMessageID(handoff.inboundMessageID),
            content: BotPeerTranscript.encode(peer: peer, text: reply),
            createdAt: handoff.replyCreatedAt ?? handoff.createdAt,
            terminalStatus: handoff.requiresHostContinuation ? nil : .completed
        )
    }

    private func projectAgentAppNeedsAttention(activityID: UUID) {
        guard let handoff = handoffs[activityID],
              let threadID = handoff.originAgentThreadID else { return }
        let peer = BotDefinition(
            id: handoff.peerBotID,
            handle: handoff.peerHandle,
            name: handoff.peerName,
            title: handoff.peerTitle,
            description: ""
        )
        projectAgentAppNeedsAttention(
            peer: peer,
            threadID: threadID,
            activityID: AgentMessageID(handoff.inboundMessageID),
            terminalStatus: handoff.requiresHostContinuation ? nil : .failed
        )
    }

    private func projectAgentAppNeedsAttention(
        peer: BotDefinition,
        threadID: AgentThreadID,
        activityID: AgentMessageID,
        terminalStatus: AgentRunStatus? = .failed
    ) {
        _ = persistAgentAppProjection(
            peer: peer,
            threadID: threadID,
            activityID: activityID,
            content: BotPeerTranscript.encodeActivity(peer: peer, phase: .needsAttention),
            createdAt: (try? messageRepo.get(id: activityID))?.createdAt ?? Date(),
            terminalStatus: terminalStatus
        )
    }

    private func persistAgentAppProjection(
        peer _: BotDefinition,
        threadID: AgentThreadID,
        activityID: AgentMessageID,
        content: String,
        createdAt: Date,
        terminalStatus: AgentRunStatus? = nil
    ) -> Bool {
        let message = AgentMessage(
            id: activityID,
            threadId: threadID,
            role: .assistant,
            content: content,
            createdAt: createdAt
        )
        do {
            try messageRepo.append(message)
            guard let stored = try messageRepo.get(id: activityID),
                  stored.threadId == threadID,
                  stored.role == .assistant,
                  stored.content == content else { return false }
            let markUnread = router?.agentAppThreadIsSelected(threadID) != true
            if let terminalStatus {
                if markUnread {
                    try threadRepo.updateStatus(
                        id: threadID,
                        status: terminalStatus,
                        hasUnread: true
                    )
                } else {
                    try threadRepo.updateStatusPreservingUnread(
                        id: threadID,
                        status: terminalStatus
                    )
                }
            } else if markUnread {
                _ = try threadRepo.markUnreadUpdatingActivity(of: threadID)
            }
            router?.projectAgentAppPeerMessage(
                threadID: threadID,
                messageID: activityID,
                terminalStatus: terminalStatus
            )
            return true
        } catch {
            return false
        }
    }

    private func setReply(_ activityID: UUID, message: AgentMessage) -> Bool {
        guard !isDeletionBlocked(activityID),
              var handoff = handoffs[activityID],
              !message.content.isEmpty else { return false }
        handoff.replyText = message.content
        handoff.replyCreatedAt = message.createdAt
        handoff.phase = .peerCompleted
        var candidate = handoffs
        candidate[activityID] = handoff
        return replaceSnapshot(candidate)
    }

    private func setPhase(
        _ activityID: UUID,
        _ phase: BotPeerHandoffPhase,
        projectAttention: Bool = true
    ) {
        var persistedHandoff: PersistedBotPeerHandoff?
        for _ in 0..<2 {
            guard !isDeletionBlocked(activityID), var handoff = handoffs[activityID] else { return }
            handoff.phase = phase
            var candidate = handoffs
            candidate[activityID] = handoff
            if replaceSnapshot(candidate) {
                persistedHandoff = handoff
                break
            }
        }
        guard let handoff = persistedHandoff else {
            let stored = handoffs[activityID]
            publish(
                BotPeerHandoffDelta(
                    activityID: activityID,
                    previous: stored,
                    current: stored,
                    errorMessage: "The bot handoff state could not be saved."
                )
            )
            return
        }
        resolveAgentAppDispatchWaiters(activityID: activityID)
        if phase == .needsAttention {
            if let peerRunID = handoff.peerRunID { cancelExactRunWait(peerRunID) }
            if let hostRunID = handoff.hostRunID { cancelExactRunWait(hostRunID) }
            if projectAttention {
                projectAgentAppNeedsAttention(activityID: activityID)
            }
        }
    }

    private func markConversationWorking(_ conversation: BotConversation) {
        var next = conversation
        next.attentionState = .working
        next.updatedAt = Date()
        try? botStore.upsertConversation(next)
    }

    private func markConversationNeedsAttention(_ conversation: BotConversation, detail: String) {
        var next = conversation
        next.attentionState = .needsAttention
        next.updatedAt = Date()
        do {
            try botStore.upsertConversation(next)
            try botStore.upsertAttention(
                BotAttentionItem(
                    botID: next.botID,
                    conversationID: next.id,
                    kind: .question,
                    title: "Needs you",
                    detail: detail
                )
            )
            BotsViewModel.publishDestAttentionChanged()
        } catch {
            return
        }
    }

    private func settleConversation(_ conversation: BotConversation, run: AgentRun?) {
        let status = run?.status ?? .interrupted
        let reason = run?.terminalReason
        var next = conversation
        next.attentionState = BotsDeskFollowThrough.conversationState(
            for: status,
            viewingDesk: false,
            terminalReason: reason
        )
        next.unread = status == .completed
        next.updatedAt = Date()
        do {
            try botStore.upsertConversation(next)
            if let kind = BotsDeskFollowThrough.attentionKind(for: status, terminalReason: reason) {
                try botStore.upsertAttention(
                    BotAttentionItem(
                        botID: next.botID,
                        conversationID: next.id,
                        kind: kind,
                        title: BotsDeskFollowThrough.attentionTitle(for: status, terminalReason: reason),
                        detail: run?.errorMessage ?? "The supervised turn ended without a clean completion."
                    )
                )
            }
            BotsViewModel.publishDestAttentionChanged()
        } catch {
            return
        }
    }

    private func exactAssistantMessage(threadID: AgentThreadID, runID: AgentRunID) -> AgentMessage? {
        guard let checkpoint = (try? checkpointRepo.list(threadId: threadID))?
            .last(where: { $0.runId == runID }),
              checkpoint.threadId == threadID,
              let messageID = checkpoint.assistantMessageId,
              let message = try? messageRepo.get(id: messageID),
              message.threadId == threadID,
              message.role == .assistant,
              !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return message
    }

    private func hostRunCompletedExactly(
        _ run: AgentRun?,
        threadID: AgentThreadID,
        runID: AgentRunID
    ) -> Bool {
        guard run?.id == runID,
              run?.threadId == threadID,
              run?.status == .completed else { return false }
        return exactAssistantMessage(threadID: threadID, runID: runID) != nil
    }

    private func armExactRun(_ runID: AgentRunID) {
        armedRunIDs.insert(runID)
    }

    private func cancelExactRunWait(_ runID: AgentRunID) {
        armedRunIDs.remove(runID)
        observedTerminalRuns[runID] = nil
        let waiters = exactRunWaiters.removeValue(forKey: runID) ?? []
        waiters.forEach { $0.resume(returning: nil) }
    }

    private func resumeExactRunWaiters(runID: AgentRunID, run: AgentRun) {
        armedRunIDs.remove(runID)
        observedTerminalRuns[runID] = nil
        let waiters = exactRunWaiters.removeValue(forKey: runID) ?? []
        waiters.forEach { $0.resume(returning: run) }
    }

    private func awaitExactRunTerminal(
        runID: AgentRunID,
        threadID: AgentThreadID
    ) async -> AgentRun? {
        await withCheckedContinuation { continuation in
            exactRunWaiters[runID, default: []].append(continuation)
            if let run = try? runRepo.get(id: runID),
               run.threadId == threadID,
               BotsDeskFollowThrough.isTerminal(run.status),
               run.status != .completed
                    || exactAssistantMessage(threadID: threadID, runID: runID) != nil {
                resumeExactRunWaiters(runID: runID, run: run)
                return
            }
            if let observed = observedTerminalRuns[runID] {
                resumeExactRunWaiters(runID: runID, run: observed)
            }
        }
    }

    private func reconcilePeerHandoffs() {
        refreshStorageProjection()
        for activityID in handoffs.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let handoff = handoffs[activityID] else { continue }
            if let conversationID = handoff.originConversationID,
               (try? botStore.conversation(id: conversationID)) == nil {
                removeRestoredHandoff(activityID: activityID, handoff: handoff)
                continue
            }
            if let threadID = handoff.originAgentThreadID,
               (try? threadRepo.status(of: threadID)) == nil {
                removeRestoredHandoff(activityID: activityID, handoff: handoff)
                continue
            }
            guard tasksByActivityID[activityID] == nil else { continue }

            switch handoff.phase {
            case .peerPrepared, .peerRunning:
                guard let peerThreadID = handoff.peerThreadID,
                      let peerRunID = handoff.peerRunID else {
                    setPhase(activityID, .needsAttention)
                    continue
                }
                let restoredRun: AgentRun?
                do {
                    restoredRun = try runRepo.get(id: peerRunID)
                } catch {
                    setPhase(activityID, .needsAttention)
                    continue
                }
                guard let run = restoredRun else {
                    finalizeRestoredMissingPeerRunTelemetry(runID: peerRunID)
                    setPhase(activityID, .needsAttention)
                    continue
                }
                guard
                      run.threadId == peerThreadID,
                      BotsDeskFollowThrough.isTerminal(run.status),
                      run.status == .completed,
                      let reply = exactAssistantMessage(threadID: peerThreadID, runID: peerRunID) else {
                    setPhase(activityID, .needsAttention)
                    continue
                }
                guard setReply(activityID, message: reply),
                      importRestoredPeerReply(activityID: activityID) else { continue }
                setPhase(
                    activityID,
                    handoffs[activityID]?.requiresHostContinuation == false
                        ? .completed
                        : .needsAttention,
                    projectAttention: false
                )

            case .peerCompleted, .hostPrepared, .hostRunning:
                guard importRestoredPeerReply(activityID: activityID) else { continue }
                guard let current = handoffs[activityID] else { continue }
                if !current.requiresHostContinuation {
                    setPhase(activityID, .completed, projectAttention: false)
                    continue
                }
                guard let hostThreadID = current.hostThreadID,
                      let hostRunID = current.hostRunID else {
                    setPhase(activityID, .needsAttention, projectAttention: false)
                    continue
                }
                if let run = try? runRepo.get(id: hostRunID) {
                    guard run.threadId == hostThreadID,
                          BotsDeskFollowThrough.isTerminal(run.status) else {
                        setPhase(activityID, .needsAttention, projectAttention: false)
                        continue
                    }
                    setPhase(
                        activityID,
                        hostRunCompletedExactly(
                            run,
                            threadID: hostThreadID,
                            runID: hostRunID
                        ) ? .completed : .needsAttention,
                        projectAttention: false
                    )
                    continue
                }
                guard observeRestoredQueuedHostIfPresent(
                    activityID: activityID,
                    threadID: hostThreadID,
                    runID: hostRunID
                ) else {
                    setPhase(activityID, .needsAttention, projectAttention: false)
                    continue
                }

            case .completed, .needsAttention:
                break
            }
        }
    }

    private func finalizeRestoredMissingPeerRunTelemetry(runID: AgentRunID) {
        guard let orchestrationRuntime,
              let receipts = try? orchestrationRuntime.recentReceipts(limit: 10_000) else {
            return
        }
        for receipt in receipts where receipt.runId == runID
            && receipt.decisionReason == AgentOrchestrationRuntime.botDelegationDecisionReason
            && receipt.lifecycleStatus == .accepted {
            try? orchestrationRuntime.finalizeBotDelegationReceipt(
                id: receipt.id,
                status: .failed
            )
        }
    }

    private func removeRestoredHandoff(
        activityID: UUID,
        handoff: PersistedBotPeerHandoff
    ) {
        var candidate = handoffs
        candidate[activityID] = nil
        guard replaceSnapshot(candidate) else { return }
        tasksByActivityID.removeValue(forKey: activityID)?.cancel()
        if let peerRunID = handoff.peerRunID { cancelExactRunWait(peerRunID) }
        if let hostRunID = handoff.hostRunID { cancelExactRunWait(hostRunID) }
    }

    private func importRestoredPeerReply(activityID: UUID) -> Bool {
        guard let handoff = handoffs[activityID], handoff.replyText != nil else { return false }
        guard handoff.originAgentThreadID != nil else { return true }
        guard projectAgentAppReply(activityID: activityID) else {
            projectAgentAppNeedsAttention(activityID: activityID)
            return false
        }
        return true
    }

    private func observeRestoredQueuedHost(
        activityID: UUID,
        threadID: AgentThreadID,
        runID: AgentRunID
    ) {
        guard tasksByActivityID[activityID] == nil else { return }
        armExactRun(runID)
        tasksByActivityID[activityID] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.tasksByActivityID[activityID] = nil }
            let run = await self.awaitExactRunTerminal(runID: runID, threadID: threadID)
            guard await self.awaitDeletionResolution(activityID: activityID),
                  let handoff = self.handoffs[activityID],
                  handoff.hostThreadID == threadID,
                  handoff.hostRunID == runID,
                  handoff.phase == .peerCompleted
                    || handoff.phase == .hostPrepared
                    || handoff.phase == .hostRunning else { return }
            self.setPhase(
                activityID,
                self.hostRunCompletedExactly(run, threadID: threadID, runID: runID)
                    ? .completed
                    : .needsAttention,
                projectAttention: false
            )
        }
    }

    private func observeRestoredQueuedHostIfPresent(
        activityID: UUID,
        threadID: AgentThreadID,
        runID: AgentRunID
    ) -> Bool {
        let queuedID = AgentQueuedMessageID(runID.value)
        guard let queued = try? queuedMessageRepo.get(id: queuedID),
              queued.threadId == threadID else { return false }
        observeRestoredQueuedHost(activityID: activityID, threadID: threadID, runID: runID)
        return true
    }

    private func observePeerQueueLifecycle() {
        let subscription = EventBus.shared.subscribeFromCurrent(filter: .agentThreadAndQueue) { [weak self] event in
            guard event.kind == AgentQueueEventKinds.cancelled,
                  let payload = event.payload.objectValue,
                  let rawQueuedID = payload["queued_message_id"]?.stringValue,
                  let queuedUUID = UUID(uuidString: rawQueuedID),
                  let rawThreadID = payload["thread_id"]?.stringValue,
                  let threadUUID = UUID(uuidString: rawThreadID) else { return }
            Task { @MainActor [weak self] in
                self?.settleCancelledQueuedHost(
                    runID: AgentRunID(queuedUUID),
                    threadID: AgentThreadID(threadUUID)
                )
            }
        }
        peerQueueLifecycleSubscription = subscription.id
    }

    private func settleCancelledQueuedHost(runID: AgentRunID, threadID: AgentThreadID) {
        let queuedID = AgentQueuedMessageID(runID.value)
        guard (try? runRepo.status(of: runID)) == nil,
              (try? queuedMessageRepo.get(id: queuedID)) == nil else { return }
        let activityIDs = handoffs.compactMap { activityID, handoff -> UUID? in
            guard handoff.hostRunID == runID,
                  handoff.hostThreadID == threadID,
                  handoff.phase == .peerCompleted
                    || handoff.phase == .hostPrepared
                    || handoff.phase == .hostRunning else { return nil }
            return activityID
        }
        guard !activityIDs.isEmpty else { return }
        cancelExactRunWait(runID)
        activityIDs.forEach { setPhase($0, .needsAttention, projectAttention: false) }
    }

    fileprivate func reconcilePeerHandoffsForTesting() {
        reconcilePeerHandoffs()
    }

    private func resolveExactRunWaiters(
        runID: AgentRunID,
        threadID: AgentThreadID,
        finalMessage _: String?,
        providerThreadID _: String?
    ) {
        guard armedRunIDs.contains(runID),
              let run = try? runRepo.get(id: runID),
              run.threadId == threadID,
              BotsDeskFollowThrough.isTerminal(run.status) else { return }
        if exactRunWaiters[runID]?.isEmpty == false {
            resumeExactRunWaiters(runID: runID, run: run)
        } else {
            observedTerminalRuns[runID] = run
        }
    }

    private func publish(_ delta: BotPeerHandoffDelta) {
        observers.removeAll { $0.value == nil }
        for observer in observers.compactMap(\.value) {
            observer.botPeerHandoffAuthority(self, didApply: delta)
        }
    }

    func latestPeerProgress(hostRunID: AgentRunID) -> Date? {
        var dates: [Date] = []
        for handoff in handoffs.values where handoff.hostRunID == hostRunID {
            switch handoff.phase {
            case .peerPrepared, .peerRunning:
                dates.append(handoff.createdAt)
                if let peerRunID = handoff.peerRunID,
                   let stamped = peerProgress.date(for: peerRunID) {
                    dates.append(stamped)
                }
                if let threadID = handoff.peerThreadID,
                   let updatedAt = try? threadRepo.updatedAt(of: threadID) {
                    dates.append(updatedAt)
                }
            default:
                break
            }
        }
        return dates.max()
    }

    nonisolated func runCoordinator(
        _ coordinator: AgentRunCoordinator,
        didReceive event: AssistantEvent,
        run: AgentRunID,
        threadId: AgentThreadID
    ) {
        // EV-21: no MainActor hop per stream event; write in place.
        peerProgress.stamp(run)
    }

    nonisolated func runCoordinator(
        _ coordinator: AgentRunCoordinator,
        didFinish runId: AgentRunID,
        threadId: AgentThreadID,
        status: AgentRunStatus,
        finalMessage: String?,
        providerThreadId: String?
    ) {
        peerProgress.remove(runId)
        Task { @MainActor [weak self] in
            self?.stopOrphanedPeerRuns(hostRunID: runId, status: status)
            self?.resolveExactRunWaiters(
                runID: runId,
                threadID: threadId,
                finalMessage: finalMessage,
                providerThreadID: providerThreadId
            )
        }
    }

    nonisolated func runCoordinator(
        _ coordinator: AgentRunCoordinator,
        didChangeStatus status: AgentRunStatus,
        runId: AgentRunID,
        threadId: AgentThreadID
    ) {}
}

public struct BotDeskWorkLogRow: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let detail: String
    public let statusLabel: String
    public let createdAt: Date
    public let runID: AgentRunID

    public init(
        id: UUID = UUID(),
        title: String,
        detail: String,
        statusLabel: String,
        createdAt: Date = Date(),
        runID: AgentRunID
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.statusLabel = statusLabel
        self.createdAt = createdAt
        self.runID = runID
    }
}

public enum BotDeskTimelineItem: Identifiable, Equatable, Sendable {
    case message(BotDeskMessage)
    case workLog(BotDeskWorkLogRow)
    case liveTurn(AssistantTurnSnapshot, hideAssistantOutput: Bool)
    /// One chronological slice of a turn split around interleaved peer rows so
    /// desk chat appends in arrival order (work → peer reply → more work).
    case liveTurnSegment(AgentChatTurnSegmentation.TurnSegment, hideAssistantOutput: Bool)

    public var id: String {
        switch self {
        case .message(let message): return "msg-\(message.id.uuidString)"
        case .workLog(let row): return "log-\(row.id.uuidString)"
        case .liveTurn(let turn, _): return "turn-\(turn.turnId)"
        case .liveTurnSegment(let segment, _): return segment.rowId
        }
    }

    public var createdAt: Date {
        switch self {
        case .message(let message): return message.createdAt
        case .workLog(let row): return row.createdAt
        case .liveTurn(let turn, _): return AgentChatLiveTurnChrome.turnSortDate(turn)
        case .liveTurnSegment(let segment, _):
            return AgentChatLiveTurnChrome.turnSortDate(segment.snapshot)
        }
    }

    var turnID: String? {
        switch self {
        case .liveTurn(let turn, _): return turn.turnId
        case .liveTurnSegment(let segment, _): return segment.snapshot.turnId
        case .message, .workLog: return nil
        }
    }

    var stableOrder: Int {
        switch self {
        case .message(let message):
            return message.role == .user ? 0 : 3
        case .liveTurn, .liveTurnSegment:
            return 1
        case .workLog:
            return 2
        }
    }
}

public enum BotsScreen: String, Equatable {
    case fleet
    case studio
    case desk
    case attention
    case activeBots
    case scheduleTasks

    /// Home/fleet and the old Attention full-screen are not destinations.
    /// Leftover persist remaps them to Chat.
    public var resolvedDestination: BotsScreen {
        switch self {
        case .studio:
            return .studio
        case .activeBots:
            return .activeBots
        case .scheduleTasks:
            return .scheduleTasks
        case .desk, .fleet, .attention:
            return .desk
        }
    }
}

public enum BotDeskInspectorTab: String, CaseIterable, Identifiable {
    /// Compile inspector. Not user-facing — leftover persist remaps to Routines.
    case brain
    case routines

    public var id: String { rawValue }

    public var isUserFacing: Bool {
        switch self {
        case .brain: return false
        case .routines: return true
        }
    }

    public var title: String {
        switch self {
        case .brain: return BotsChrome.Label.brain
        case .routines: return BotsChrome.Label.routines
        }
    }

    public var accessibilityIdentifier: String {
        switch self {
        case .brain: return "bots.desk.inspector.tab.brain"
        case .routines: return "bots.desk.inspector.tab.routines"
        }
    }
}

public enum BotStudioTab: String, CaseIterable, Identifiable {
    case profile
    /// Compile inspector. Not user-facing — leftover persist remaps to Profile.
    case brain
    case files
    case routines
    /// Security also hosts the read-only Desktop honesty card — both were
    /// tiny read-only panels, so one tab keeps the strip simple.
    case security

    public var id: String { rawValue }

    public var isUserFacing: Bool {
        switch self {
        case .brain: return false
        case .profile, .files, .routines, .security: return true
        }
    }

    public var title: String {
        switch self {
        case .profile: return "Profile"
        case .brain: return BotsChrome.Label.brain
        case .files: return BotsChrome.Label.files
        case .routines: return BotsChrome.Label.routines
        case .security: return BotsChrome.Label.security
        }
    }

    public var accessibilityIdentifier: String {
        switch self {
        case .profile: return "bots.studio.tab.profile"
        case .brain: return "bots.studio.tab.brain"
        case .files: return "bots.studio.tab.files"
        case .routines: return "bots.studio.tab.routines"
        case .security: return "bots.studio.tab.security"
        }
    }

    public var symbol: String {
        switch self {
        case .profile: return "person.crop.circle"
        case .brain: return "brain.head.profile"
        case .files: return "folder"
        case .routines: return "clock.arrow.2.circlepath"
        case .security: return "lock.shield"
        }
    }
}

public enum BotBrainInspectorPane: String, CaseIterable, Identifiable {
    case source
    case effective

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .source: return BotsChrome.Label.source
        case .effective: return BotsChrome.Label.effective
        }
    }

    public var accessibilityIdentifier: String {
        switch self {
        case .source: return "bots.brain.pane.source"
        case .effective: return "bots.brain.pane.effective"
        }
    }
}

// MARK: - View model

/// Provider · model chip data for one desk thread-rail row.
public struct BotDeskThreadRailRouting: Equatable {
    public let provider: AgentProvider
    public let model: String

    public init(provider: AgentProvider, model: String) {
        self.provider = provider
        self.model = model
    }
}

/// Identity token so overlapping sends compare-and-remove instead of overwriting one slot.
private final class DeskSendWork {
    var task: Task<Void, Never>!
    var threadID: AgentThreadID?
    var runID: AgentRunID?
}

/// One in-flight stop join per bot so concurrent stops share the same await.
private final class DeskStopJoin {
    var task: Task<Bool, Never>!
}

struct BotDraftPersistenceMetrics: Equatable {
    var encodeCount = 0
    var setCount = 0
    var encodedBytes = 0
    var searchTextWrites = 0
}

/// One persistence owner per AppContext. Bot windows keep their visible fields
/// locally, while this authority orders the canonical draft maps and performs
/// lifecycle/deadline writes once for every surface sharing that context.
@MainActor
final class BotDraftPersistenceAuthority {
    private static let delayNanoseconds: UInt64 = 250_000_000

    private(set) var composerDraftsByBot: [BotID: BotComposerDraft] = [:]
    private(set) var inspectorDraftsByBot: [BotID: BotInspectorDraft] = [:]
    private(set) var studioDraftsByBot: [BotID: BotStudioDraft] = [:]
    private var metrics = BotDraftPersistenceMetrics()
    private var composerDirty = false
    private var inspectorDirty = false
    private var studioDirty = false
    private var searchDirty = false
    private var searchText = ""
    private var flushScheduled = false
    private var flushGeneration: UInt64 = 0
    private var flushTask: Task<Void, Never>?
    private var lifecycleObservers: [NSObjectProtocol] = []
    var scheduleForTesting: ((UInt64, @escaping () -> Void) -> Void)?

    init() {
        reloadFromUserDefaults()
        let center = NotificationCenter.default
        for name in [
            NSApplication.willHideNotification,
            NSWindow.willCloseNotification,
            NSApplication.willTerminateNotification,
        ] {
            lifecycleObservers.append(center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.flushPending()
                }
            })
        }
    }

    deinit {
        flushTask?.cancel()
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func updateComposer(_ draft: BotComposerDraft?, for botID: BotID) {
        composerDraftsByBot[botID] = draft.flatMap { $0.isEmpty ? nil : $0 }
        composerDirty = true
        scheduleFlush()
    }

    func updateInspector(_ draft: BotInspectorDraft?, for botID: BotID) {
        inspectorDraftsByBot[botID] = draft.flatMap { $0.isEmpty ? nil : $0 }
        inspectorDirty = true
        scheduleFlush()
    }

    func updateStudio(_ draft: BotStudioDraft, for botID: BotID) {
        studioDraftsByBot[botID] = draft
        studioDirty = true
        scheduleFlush()
    }

    /// Roster search is a per-keystroke write: the field must paint every key
    /// but the plist only sees the query once the typing settles.
    func updateSearchText(_ text: String) {
        searchText = text
        searchDirty = true
        scheduleFlush()
    }

    /// Latest query for this context: the pending one while a write is scheduled,
    /// else the stored one. Surfaces must not read UserDefaults behind a pending write.
    var currentSearchText: String { searchText }

    func removeDrafts(for botID: BotID) {
        if composerDraftsByBot.removeValue(forKey: botID) != nil {
            composerDirty = true
        }
        if inspectorDraftsByBot.removeValue(forKey: botID) != nil {
            inspectorDirty = true
        }
        if studioDraftsByBot.removeValue(forKey: botID) != nil {
            studioDirty = true
        }
        if composerDirty || inspectorDirty || studioDirty {
            scheduleFlush()
        }
    }

    @discardableResult
    func retainComposerDrafts(for liveBotIDs: Set<BotID>) -> Bool {
        let next = composerDraftsByBot.filter { liveBotIDs.contains($0.key) }
        guard next.count != composerDraftsByBot.count else { return false }
        composerDraftsByBot = next
        composerDirty = true
        scheduleFlush()
        return true
    }

    @discardableResult
    func retainInspectorDrafts(for liveBotIDs: Set<BotID>) -> Bool {
        let next = inspectorDraftsByBot.filter { liveBotIDs.contains($0.key) }
        guard next.count != inspectorDraftsByBot.count else { return false }
        inspectorDraftsByBot = next
        inspectorDirty = true
        scheduleFlush()
        return true
    }

    @discardableResult
    func retainStudioDrafts(for liveBotIDs: Set<BotID>) -> Bool {
        let next = studioDraftsByBot.filter { liveBotIDs.contains($0.key) }
        guard next.count != studioDraftsByBot.count else { return false }
        studioDraftsByBot = next
        studioDirty = true
        scheduleFlush()
        return true
    }

    func flushPending() {
        flushTask?.cancel()
        flushTask = nil
        flushScheduled = false
        flushGeneration &+= 1
        if composerDirty {
            persistComposerDrafts()
        }
        if inspectorDirty {
            persistInspectorDrafts()
        }
        if studioDirty {
            persistStudioDrafts()
        }
        if searchDirty {
            persistSearchText()
        }
    }

    func resetMetricsForTesting() {
        metrics = BotDraftPersistenceMetrics()
    }

    var metricsForTesting: BotDraftPersistenceMetrics {
        metrics
    }

    func reloadFromUserDefaultsForTesting() {
        flushTask?.cancel()
        flushTask = nil
        flushScheduled = false
        flushGeneration &+= 1
        composerDirty = false
        inspectorDirty = false
        studioDirty = false
        searchDirty = false
        reloadFromUserDefaults()
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        flushGeneration &+= 1
        let generation = flushGeneration
        let action = { [weak self] in
            guard let self,
                  self.flushScheduled,
                  self.flushGeneration == generation
            else { return }
            self.flushPending()
        }
        if let schedule = scheduleForTesting {
            schedule(Self.delayNanoseconds, action)
            return
        }
        flushTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: Self.delayNanoseconds)
            } catch {
                return
            }
            action()
        }
    }

    private func persistComposerDrafts() {
        composerDirty = false
        let payload = Dictionary(uniqueKeysWithValues: composerDraftsByBot.map {
            ($0.key.value.uuidString.lowercased(), $0.value)
        })
        persist(payload, key: BotsViewModel.composerDraftsDefaultsKey)
    }

    private func persistInspectorDrafts() {
        inspectorDirty = false
        let payload = Dictionary(uniqueKeysWithValues: inspectorDraftsByBot.map {
            ($0.key.value.uuidString.lowercased(), $0.value)
        })
        persist(payload, key: BotsViewModel.inspectorDraftsDefaultsKey)
    }

    private func persistSearchText() {
        searchDirty = false
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: BotsViewModel.searchTextDefaultsKey)
        } else {
            UserDefaults.standard.set(searchText, forKey: BotsViewModel.searchTextDefaultsKey)
        }
        metrics.searchTextWrites += 1
    }

    private func persistStudioDrafts() {
        studioDirty = false
        let payload = Dictionary(uniqueKeysWithValues: studioDraftsByBot.map {
            ($0.key.value.uuidString.lowercased(), $0.value)
        })
        persist(payload, key: BotsViewModel.studioDraftDefaultsKey)
    }

    private func persist<T: Encodable>(_ payload: [String: T], key: String) {
        guard !payload.isEmpty else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        if let data = try? BotsViewModel.encodeJSON(payload) {
            metrics.encodeCount += 1
            metrics.encodedBytes += data.count
            UserDefaults.standard.set(data, forKey: key)
            metrics.setCount += 1
        }
    }

    private func reloadFromUserDefaults() {
        composerDraftsByBot = decodeDraftMap(
            BotComposerDraft.self,
            key: BotsViewModel.composerDraftsDefaultsKey
        ).filter { !$0.value.isEmpty }
        inspectorDraftsByBot = decodeDraftMap(
            BotInspectorDraft.self,
            key: BotsViewModel.inspectorDraftsDefaultsKey
        ).filter { !$0.value.isEmpty }
        studioDraftsByBot = decodeDraftMap(
            BotStudioDraft.self,
            key: BotsViewModel.studioDraftDefaultsKey
        )
        if studioDraftsByBot.isEmpty,
           let data = UserDefaults.standard.data(forKey: BotsViewModel.studioDraftDefaultsKey),
           let draft = try? BotsViewModel.decodeJSON(BotStudioDraft.self, from: data),
           let botID = draft.botID {
            studioDraftsByBot = [botID: draft]
        }
        searchText = UserDefaults.standard.string(forKey: BotsViewModel.searchTextDefaultsKey) ?? ""
    }

    private func decodeDraftMap<T: Decodable>(_ type: T.Type, key: String) -> [BotID: T] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let payload = try? BotsViewModel.decodeJSON([String: T].self, from: data)
        else { return [:] }
        return Dictionary(uniqueKeysWithValues: payload.compactMap { raw, draft in
            guard let uuid = UUID(uuidString: raw) else { return nil }
            return (BotID(uuid), draft)
        })
    }
}

/// Facts `BotsViewModel.linkedRun` needs from `agent_runs`, resolved without
/// main-actor state so a live poller can read them off MainActor.
struct DeskLinkedRunProbe: Sendable {
    var run: AgentRun?
    var memoizedRunID: AgentRunID?
    var scannedFinished: Bool
}

/// Facts one desk watch tick reads from SQLite, resolved together off
/// MainActor: the coordinator's stream cursor and the linked run.
private struct DeskLiveTurnWatchProbe: Sendable {
    var cursor: AgentRunRepository.StreamEventCursor
    var linkedRun: DeskLinkedRunProbe
}

@MainActor
public final class BotsViewModel: ObservableObject {
    // PERF: share JSON codec to avoid per-call allocation (many UserDefaults encode/decode per UI update).
    private static let sharedEncoder = JSONEncoder()
    private static let sharedDecoder = JSONDecoder()
    private static let codecLock = NSLock()
    fileprivate static func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
        Self.codecLock.lock()
        defer { Self.codecLock.unlock() }
        return try Self.sharedEncoder.encode(value)
    }
    fileprivate static func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        Self.codecLock.lock()
        defer { Self.codecLock.unlock() }
        return try Self.sharedDecoder.decode(type, from: data)
    }

    public static let assistantPlaceholder = BotsDeskFollowThrough.noRouterPlaceholder

    @Published public private(set) var bots: [BotDefinition] = [] {
        didSet {
            selectedBotFallbackCache = nil
            refreshActiveBotCount()
        }
    }
    /// Stored working-bot count so roster/Active Bots bodies never run the
    /// `liveWorkingBots()` SQLite reads (perf BT-01). Refreshed only where the
    /// inputs change — see `refreshActiveBotCount()`.
    @Published public private(set) var activeBotCount: Int = 0
    /// Stored roster snapshot so ForEach does not re-filter/sort `fleet` on
    /// unrelated @Published writes (desk timeline, inspector, Token Saver).
    @Published public private(set) var publishedRoster: [BotDefinition] = []
    @Published public var searchText: String = "" {
        didSet {
            persistSearchText()
            publishRosterIfNeeded()
        }
    }
    @Published public var showHidden: Bool = false {
        didSet {
            persistShowHidden()
            if showHidden == oldValue { return }
            // Dest first. Show hidden used to reloadFleet (every teammate's
            // conversations + recent messages) before the roster could
            // paint. Off filters locally; on lists hidden rows only.
            applyShowHiddenLocally()
            publishRosterIfNeeded()
        }
    }
    @Published public var selectedBotID: BotID?
    @Published public var screen: BotsScreen = .desk {
        didSet {
            let resolved = screen.resolvedDestination
            if screen != resolved {
                screen = resolved
                return
            }
            persistScreen()
            router?.windowController?.refreshBotsChromeTitle()
            publishInterestedDeskThreadID()
            syncDeskAgentVM()
        }
    }
    @Published public var activeBotsTab: ActiveBotsTab = .active
    @Published public var activeBotsSearchText: String = ""
    @Published public private(set) var activeBotItems: [ActiveBotScreenItem] = []
    @Published public private(set) var finishedBotItems: [FinishedBotScreenItem] = []
    @Published public var scheduleTaskSearchText: String = "" { didSet { applyScheduleTaskFilters() } }
    @Published public var scheduleTaskStatusFilter: ScheduledTaskStatusFilter = .all { didSet { applyScheduleTaskFilters() } }
    @Published public private(set) var scheduleTaskItems: [BotScheduleTaskItem] = []
    @Published public private(set) var scheduleTaskFilterCounts: (all: Int, active: Int, paused: Int) = (0, 0, 0)
    @Published public var scheduleTaskDraft: BotScheduleTaskDraft?
    @Published public var inspectorTab: BotDeskInspectorTab = .routines {
        didSet { persistInspectorTab() }
    }
    @Published public var studioTab: BotStudioTab = .profile {
        didSet { persistStudioTab() }
    }
    /// Whole Desk side pane (Desktop row + inspector) is collapsible.
    @Published public var isDeskSidePaneVisible: Bool = true {
        didSet { persistDeskSidePane() }
    }
    @Published public var deskSidePaneWidth: CGFloat = BotsChrome.desktopPaneWidth {
        didSet { persistDeskSidePaneWidth() }
    }
    /// Dest thread rail is collapsible. Desk header always keeps the toggle.
    @Published public var isDeskThreadRailVisible: Bool = true {
        didSet { persistDeskThreadRail() }
    }
    @Published public var deskThreadRailWidth: CGFloat = BotsChrome.threadRailWidth {
        didSet { persistDeskThreadRailWidth() }
    }
    @Published public var deskThreadSearchQuery: String = ""
    /// Shell sidebar collapse. Desk only bleeds into the titlebar while
    /// the sidebar is open; collapsed keeps the 34pt toggle bar visible.
    @Published public var isShellSidebarCollapsed: Bool = false
    /// Detached Desk windows hide the pop-out control so they do not nest.
    public var presentsAsDetachedWindow: Bool = false
    public let studioState = BotsStudioDraftState()
    public var studioDraft: BotStudioDraft {
        get { studioState.draft }
        set {
            studioState.draft = newValue
            persistStudioDraftIfHydrated()
        }
    }
    /// Keep live composer edits and caret movement off the Desk view model that
    /// owns the transcript and live timeline. The computed proxies preserve the
    /// existing API while publishing both fields only to the composer subtree.
    public let composerState = BotsComposerState()
    public var composerText: String {
        get { composerState.text }
        set {
            composerState.text = newValue
            persistComposerIfHydrated()
        }
    }
    public var composerCursorOffset: Int? {
        get { composerState.cursorOffset }
        set { composerState.cursorOffset = newValue }
    }
    @Published public var attachments: [AgentAttachment] = [] {
        didSet { persistComposerIfHydrated() }
    }
    /// User-selected route for the current Desk thread. Never sourced from or
    /// persisted on the Bot definition/revision.
    @Published public var deskRouting = BotDeskRouting() {
        didSet { persistDeskRoutingIfHydrated() }
    }
    @Published public var availableRunAsUsers: [AgentRunAsUser] = MacOSLocalUserCatalog.listEligibleUsers()
    public var deskRunAsUser: AgentRunAsUser { deskRouting.runAsUser }
    public private(set) var lastDeskRunProviderForTesting: AgentProvider?
    public private(set) var lastDeskRunModelForTesting: String?
    public private(set) var lastDeskRunPermissionForTesting: AgentPermissionMode?
    public private(set) var lastDeskRunReasoningForTesting: AgentReasoningEffort?
    public private(set) var lastMentionedBotIDForTesting: BotID?
    public var activeThreadIDsOverrideForTesting: Set<AgentThreadID>? {
        didSet { refreshActiveBotCount() }
    }
    public private(set) var lastHopUserTextForTesting: String?
    public private(set) var lastSupervisedRunUserTextForTesting: String?
    public private(set) var supervisedRunBotIDsForTesting: [BotID] = []
    @Published public var isStopping = false
    @Published public private(set) var queuedFollowUps: [BotQueuedFollowUp] = []
    @Published public private(set) var deskMessages: [BotDeskMessage] = [] {
        didSet {
            // BT-27: `tokenSaverMessage(forTurnId:)` ran once per turn per body
            // pass as a filter over every desk message. Index on assignment.
            var index: [String: [BotDeskMessage]] = [:]
            for message in deskMessages {
                guard let turnId = message.tokenSaverTurnId else { continue }
                index[turnId, default: []].append(message)
            }
            tokenSaverMessagesByTurnId = index
        }
    }
    private var tokenSaverMessagesByTurnId: [String: [BotDeskMessage]] = [:]
    /// Same Token Saver footer figures Agent App shows, from the same calculator.
    @Published public private(set) var tokenSaverFooterEnabled = false
    @Published public private(set) var tokenSaverFooterSnapshotReady = false
    @Published public private(set) var tokenSaverThreadMeasuredTokens = 0
    @Published public private(set) var tokenSaverThreadSavedTokens = 0
    @Published public private(set) var tokenSaverOriginalDisplayMessageIds: Set<AgentMessageID> = []
    private var tokenSaverDisplayModeWriteGeneration: [AgentMessageID: UInt64] = [:]
    private var tokenSaverDisplayModeWriteTasks: [AgentMessageID: Task<Void, Never>] = [:]
    @Published public private(set) var deskWorkLog: [BotDeskWorkLogRow] = []
    @Published public private(set) var deskLiveTimeline = AssistantTimelineState()
    @Published public private(set) var deskStreamEventCount = 0
    @Published public private(set) var deskSendInFlight = false
    @Published public private(set) var deskSendInFlightStartedAt: Date?
    @Published public private(set) var deskTimelineRejoinToken = 0
    /// Owner of the in-flight send so roster switch does not paint Loading on the wrong desk.
    private var deskSendInFlightBotID: BotID?
    private var deskSendTasks: [BotID: [DeskSendWork]] = [:]
    private var deskStopEpoch: [BotID: Int] = [:]
    private var deskStopJoins: [BotID: DeskStopJoin] = [:]
    /// Test seam: force `liveThreadIDs` to throw so stop must still await cancelled sends.
    public var liveThreadDiscoveryErrorForTesting: Error?
    public private(set) var deskStopJoinStartCountForTesting = 0
    /// Snapshot-time `stopRun` calls issued before awaiting a blocked send.
    public private(set) var deskStopRunIssuedCountForTesting = 0
    /// Test seam: how many times Desk actually decoded stream events.
    public private(set) var deskLiveReplayFetchCountForTesting = 0
    /// Test seam: MainActor Tasks scheduled from the coordinator stream observer.
    public var deskStreamMainHopCountForTesting: Int {
        interestedDeskThread.hopCountValue()
    }
    public func resetDeskStreamMainHopCountForTesting() {
        interestedDeskThread.resetHopCount()
    }
    /// Test seam: `applyIncomingDeskEvent` entries, including unmatched guards.
    public private(set) var applyIncomingDeskEventCountForTesting = 0
    /// Test seam: fallback live-turn poll bodies that hit coordinator/run SQLite.
    public private(set) var deskLiveTurnWatchApplyCountForTesting = 0
    /// BT-23: full hot-window replays the watch fetched + decoded off the main actor.
    public private(set) var deskLiveReplayOffMainFetchCountForTesting = 0
    private var deskLiveReplayGeneration = 0
    private var lastDeskStreamPushAt: Date?
    /// Cross-thread mirror of the selected desk `linkedAgentThreadID` so
    /// nonisolated stream delivery can drop other threads without a MainActor hop.
    private let interestedDeskThread = InterestedDeskThreadBox()
    nonisolated private let deskStreamEventBatch = DeskStreamEventBatchBox()
    /// Events applied since the last aggregate hot-text budget walk (shared cadence with Agent App).
    private var deskStreamAggregateBudgetOps = 0
    /// Test seams: persisted suffix work used to confirm an observer watermark.
    public private(set) var deskLiveIncrementalDecodeEventCountForTesting = 0
    public private(set) var deskLiveIncrementalDecodeBytesForTesting: Int64 = 0
    var deskLiveObservedEventByteLimitForTesting: Int?
    /// Test seam: dest at the moment send first acknowledged the click.
    public private(set) var lastSendAcknowledgedOnScreenForTesting: BotsScreen?
    /// Test seam: dest at the moment Attention acknowledge ran. Dest-first
    /// must already be Chat so the row click does not wait on the store.
    public private(set) var lastAttentionAcknowledgedOnScreenForTesting: BotsScreen?
    /// Test seam: full-fleet reloads. Roster dest must not increment this.
    public private(set) var fleetReloadCountForTesting = 0
#if DEBUG
    public private(set) var reloadSelectedBotCountForTesting = 0
#endif
#if DEBUG
    public private(set) var liveWorkingBotsCountForTesting = 0
#endif
    /// Test seam: actual Active Bots store hydration passes, excluding
    /// generation-coalesced appearance/tab requests.
    public private(set) var activeBotsHydrationCountForTesting = 0
    /// Test seam: thread message rereads. Warm-cache dest must not increment this.
    public private(set) var deskMessageRestoreCountForTesting = 0
    /// Test seam: listRecentFinished scans. Dest after first lookup must not increment this.
    public private(set) var deskFinishedRunScanCountForTesting = 0
    /// Test seam: Brain assemble calls. Unchanged dest must not increment this.
    public private(set) var previewBrainAssembleCountForTesting = 0
    /// Test seam: inspector store rereads. Warm-cache dest must not increment this.
    public private(set) var studioSupportReloadCountForTesting = 0
    /// Test seam: inspector rereads already done when dest dests Chat.
    /// First paint dest must dest Chat before dest dests inspector.
    public private(set) var lastDeskRestoreStudioSupportCountForTesting = 0
    /// Test seam: inbox rereads already done when dest dests Chat.
    /// First paint dest must dest Chat before dest dests inbox.
    public private(set) var lastDeskRestoreAttentionListCountForTesting = 0
    /// Test seam: roster-preview conversation lists already done when
    /// dest dests Chat. First paint dest must dest Chat before dest
    /// dests dest preview.
    public private(set) var lastDeskRestoreConversationListCountForTesting = 0
    /// Test seam: dest thread rereads already done when dest dests Chat.
    /// First paint dest must dest Chat from dest title before dest dests dest thread.
    public private(set) var lastDeskRestoreMessageListCountForTesting = 0
    /// Test seam: dest dests Chat restore. First paint dest must dest
    /// this bubble even when dest dests Chat from dest title.
    public private(set) var deskRestoreInvokedCountForTesting = 0
    /// Test seam: mark-read store rereads. Already-read dest must not increment this.
    public private(set) var deskMarkReadStoreCountForTesting = 0
    /// Test seam: revision store rereads. Warm dest chips must not increment this.
    public private(set) var rosterRevisionFetchCountForTesting = 0
    /// Test seam: listMemory rereads. Add/send dest must not increment this.
    public private(set) var memoryListCountForTesting = 0
    /// Test seam: listRoutines rereads. Save/enable/test dest must not increment this.
    public private(set) var routineListCountForTesting = 0
    /// Test seam: listSkillBindings rereads. Add/enable/send dest must not increment this.
    public private(set) var skillListCountForTesting = 0
    /// Test seam: send dest used dest brain cache instead of listing.
    public private(set) var lastSendUsedDestBrainForTesting = false
    /// Test seam: listConversations rereads. Persist dest must not increment this.
    public private(set) var conversationListCountForTesting = 0
    /// Test seam: listAttention rereads. Acknowledge dest must not increment this.
    public private(set) var attentionListCountForTesting = 0
    private var cachedPreviewBrain: ContextAssemblyReceipt?
    private var cachedPreviewBrainKey: String?
    private var cachedClaudeSlashEntries: (
        home: String,
        revision: String,
        refreshedAt: TimeInterval,
        entries: [String]
    )?
    var claudeSlashDiscoveryForTesting: ((String) -> [String])? {
        didSet { cachedClaudeSlashEntries = nil }
    }
    var claudeSlashCatalogRevisionForTesting: ((String) -> String)? {
        didSet { cachedClaudeSlashEntries = nil }
    }
    var claudeSlashCacheTimeForTesting: (() -> TimeInterval)? {
        didSet { cachedClaudeSlashEntries = nil }
    }
    private var studioSupportByBot: [BotID: BotStudioSupportSnapshot] = [:]
    private var revisionByID: [BotRevisionID: BotRevision] = [:]
    @Published public private(set) var conversations: [BotConversation] = []
    @Published public private(set) var selectedConversation: BotConversation? {
        didSet {
            let previousThreadID = oldValue?.linkedAgentThreadID
            if let previousThreadID,
               previousThreadID != selectedConversation?.linkedAgentThreadID {
                clearDeskObservedEvents(threadID: previousThreadID)
            }
            publishInterestedDeskThreadID()
            syncDeskAgentVM()
        }
    }
    @Published public private(set) var attentionItems: [BotAttentionItem] = []
    /// Agent App VM pinned to the selected conversation's linked thread.
    @Published public private(set) var deskAgentVM: AgentAppViewModel?
    @Published public private(set) var memoryItems: [BotMemoryItem] = []
    @Published public private(set) var skillBindings: [BotSkillBinding] = []
    @Published public private(set) var selectedRevision: BotRevision?
    @Published public private(set) var lastContextReceipt: ContextAssemblyReceipt?
    @Published public var brainPane: BotBrainInspectorPane = .source {
        didSet { persistBrainPane() }
    }
    @Published public private(set) var routines: [BotRoutine] = []
    @Published public var memoryDraft: String = "" {
        didSet { persistInspectorIfHydrated() }
    }
    @Published public var skillDraft: String = "" {
        didSet { persistInspectorIfHydrated() }
    }
    @Published public private(set) var homeFiles: [String] = []
    @Published public var selectedHomePath: String?
    @Published public var homeDraft: String = ""
    @Published public private(set) var homeOriginal: String = ""
    @Published private(set) var homeFilesModel: FilesViewModel?
    @Published public private(set) var studioFilesLocation: BotStudioFilesLocation = .botFiles
    private var homeFilesRouter: BotHomeFilesRouter?
    @Published public var thisBotSkillDraft: String = ""
    @Published public var routineName: String = "" {
        didSet { persistInspectorIfHydrated() }
    }
    @Published public var routinePrompt: String = "" {
        didSet { persistInspectorIfHydrated() }
    }
    @Published public var routineScheduleNote: String = "" {
        didSet { persistInspectorIfHydrated() }
    }
    @Published public var routineSpec = BotScheduleSpec() {
        didSet { persistInspectorIfHydrated() }
    }
    @Published public var errorMessage: String?
    @Published public private(set) var botSecrets: [BotSecretMetadata] = []
    @Published public private(set) var isBotSecretsLoading = false
    @Published public private(set) var botSecretsLoadFailed = false
    @Published public private(set) var providers: [AgentProviderSnapshot] = []
    @Published public private(set) var isControlPlaneActive = true
    @Published public private(set) var isMemoryActive = true
    @Published public private(set) var isAutonomyActive = false
    @Published public private(set) var lastSendStartedProviderRun = false
    @Published public var pendingDeleteID: BotID?
    @Published public var pendingSecretDeleteName: String?
    @Published public var pendingUnsavedNewBotConfirm = false
    public var onLeaveBots: (() -> Void)?
    private var unpublishedNewBotIDs: Set<BotID> = []
    private var pendingUnsavedNewBotLeave: (() -> Void)?
    private var botIDBeforeCreate: BotID?

    public var displayedDesktopKind: BotDesktopKind {
        if screen == .studio {
            return resolvedDesktopKind(studioDraft.desktopKind)
        }
        return resolvedDesktopKind(selectedRevision?.desktopKind ?? .logicalExecutionSpace)
    }

    public var desktopHonestyLabel: String {
        displayedDesktopKind.honestyLabel
    }

    public var desktopStatusPill: String {
        displayedDesktopKind.statusPill
    }

    private let context: AppContext
    private let router: AppCommandRouter?
    private let botStore: BotStore
    private let botSecretStore: any BotSecretStore
    private let settingsStore: SettingsStore
    private let draftPersistenceAuthority: BotDraftPersistenceAuthority
    private var messagesByBot: [BotID: [BotDeskMessage]] = [:]
    private var messagesConversationIDByBot: [BotID: BotConversationID] = [:]
    /// Last painted transcript per conversation. `messagesByBot` is only the
    /// last-viewed conversation of that teammate; switching threads must not
    /// reuse it or flash empty while SQLite hydrates.
    private var messagesByConversation: [BotConversationID: [BotDeskMessage]] = [:]
    private var selectedConversationByBot: [BotID: BotConversationID] = [:]
    private var attentionStateByBot: [BotID: BotAttentionState] = [:] {
        didSet { refreshActiveBotCount() }
    }
    private var lastPreviewByBot: [BotID: String] = [:]
    private var lastUpdatedByBot: [BotID: Date] = [:]
    private var lastLinkedRunIDByBot: [BotID: AgentRunID] = [:]
    private var lastStartedConversationByBot: [BotID: BotConversation] = [:]
    private var liveTimelineByThread: [AgentThreadID: AssistantTimelineState] = [:]
    /// BT-26: recency for `liveTimelineByThread`. Each state is bounded at
    /// 32 MiB of hot text but the map itself grew for every thread the VM ever
    /// touched (detached windows multiply it). Keep a small LRU; the selected
    /// thread is pinned and the SQLite replay path rehydrates evicted ones.
    private var liveTimelineRecency: [AgentThreadID] = []
    static let liveTimelineCacheLimit = 6
    var liveTimelineCacheCountForTesting: Int { liveTimelineByThread.count }
    /// Resident cache entry counts. Each maps 1:1 to one dictionary on purpose:
    /// a sum would let one cache cover for another, and delete specs must prove
    /// the deleted teammate's entries go while the remaining teammate's stay.
    var studioSupportCacheCountForTesting: Int { studioSupportByBot.count }
    var revisionCacheCountForTesting: Int { revisionByID.count }
    var attentionStateCacheCountForTesting: Int { attentionStateByBot.count }
    var lastPreviewCacheCountForTesting: Int { lastPreviewByBot.count }
    var transcriptCacheCountForTesting: Int { messagesByConversation.count }

    private func storeLiveTimeline(_ state: AssistantTimelineState, for threadID: AgentThreadID) {
        liveTimelineByThread[threadID] = state
        liveTimelineRecency.removeAll { $0 == threadID }
        liveTimelineRecency.append(threadID)
        for evicted in Self.lruEvictions(
            recency: liveTimelineRecency,
            limit: Self.liveTimelineCacheLimit,
            pinned: selectedConversation?.linkedAgentThreadID
        ) {
            liveTimelineByThread.removeValue(forKey: evicted)
            liveStreamCountByThread.removeValue(forKey: evicted)
            liveStreamCursorByThread.removeValue(forKey: evicted)
            liveTimelineRecency.removeAll { $0 == evicted }
        }
    }

    /// Oldest-first ids to evict so at most `limit` remain, never the pinned id.
    nonisolated static func lruEvictions(
        recency: [AgentThreadID],
        limit: Int,
        pinned: AgentThreadID?
    ) -> [AgentThreadID] {
        guard recency.count > limit else { return [] }
        var evictions: [AgentThreadID] = []
        var remaining = recency.count
        for candidate in recency where remaining > limit {
            if candidate == pinned { continue }
            evictions.append(candidate)
            remaining -= 1
        }
        return evictions
    }
    private var liveStreamCountByThread: [AgentThreadID: Int] = [:]
    private var liveStreamCursorByThread: [AgentThreadID: AgentRunRepository.StreamEventCursor] = [:]
    private var liveObservedEventsByThread: [AgentThreadID: [AssistantEvent]] = [:]
    private var liveObservedEventBytesByThread: [AgentThreadID: Int] = [:]
    private var liveObservedEventBytesTotal = 0
    private var liveObservedEventOverflowThreads: Set<AgentThreadID> = []
    private var settledTerminalRunIDByThread: [AgentThreadID: AgentRunID] = [:]
    private var queuedFollowUpsByBot: [BotID: [BotQueuedFollowUp]] = [:]
    private var composerDraftsByBot: [BotID: BotComposerDraft] = [:]
    private var composerHydrated = false
    private var isApplyingComposerDraft = false
    private var deskRoutingHydrated = false
    private var isApplyingDeskRouting = false
    private var deskRoutingByConversation: [BotConversationID: BotDeskRouting] = [:]
    private var peerHandoffs: [UUID: PersistedBotPeerHandoff] = [:] {
        didSet { refreshActiveBotCount() }
    }
    private var armedRunIDs: Set<AgentRunID> = []
    private var exactRunWaiters: [AgentRunID: [CheckedContinuation<AgentRun?, Never>]] = [:]
    private var observedTerminalRuns: [AgentRunID: AgentRun] = [:]
    var beforeBotRunDispatchForTesting: ((AgentRunID) -> Void)? {
        get { context.botPeerHandoffAuthority.beforeBotRunDispatchForTesting }
        set { context.botPeerHandoffAuthority.beforeBotRunDispatchForTesting = newValue }
    }
    private var studioFilesLocationsByBot: [BotID: BotStudioFilesLocation] = [:]
    private var inspectorDraftsByBot: [BotID: BotInspectorDraft] = [:]
    private var inspectorHydrated = false
    private var isApplyingInspectorDraft = false
    private var studioDraftsByBot: [BotID: BotStudioDraft] = [:]
    private var studioDraftHydrated = false
    private var isApplyingStudioDraft = false
    private var botSecretsReloadGeneration: UInt64 = 0
    private var botSecretsReloadTask: Task<Void, Never>?
    var draftPersistenceScheduleForTesting: ((UInt64, @escaping () -> Void) -> Void)? {
        get { draftPersistenceAuthority.scheduleForTesting }
        set { draftPersistenceAuthority.scheduleForTesting = newValue }
    }
    private var shellSidebarVisibilityObserver: NSObjectProtocol?
    private var deskLiveTurnWatch: Task<Void, Never>?
    private var tokenSaverFooterReloadTask: Task<Void, Never>?
    private var navigationFreshnessTask: Task<Void, Never>?
    private var navigationFreshnessGeneration: UInt64 = 0
    private var detachedDeskBotID: BotID?
    var navigationFirstFrameDeferral = false
    private var tokenSaverFooterObserver: NSObjectProtocol?
    private var tokenSaverFooterAccountObserver: NSObjectProtocol?
    private var tokenSaverFooterStatusObserver: NSObjectProtocol?
    public var computerGuestService: BotComputerGuestService?

    public init(
        context: AppContext,
        router: AppCommandRouter? = nil,
        loadImmediately: Bool = true,
        secretStore: any BotSecretStore = BotKeychainSecretStore()
    ) {
        self.context = context
        self.router = router
        self.botStore = context.botStore
        self.botSecretStore = secretStore
        self.settingsStore = SettingsStore(db: context.db)
        self.draftPersistenceAuthority = context.botDraftPersistenceAuthority
        context.botPeerHandoffAuthority.router = router ?? context.router
        self.computerGuestService = BotComputerGuestService(
            appSupport: context.appSupportDirectory,
            docker: BotComputerDockerCLI(),
            recipeContext: AppShellResourceBundle.computerGuestRecipeURL()
        )
        context.botPeerHandoffAuthority.addObserver(self)
        // Queued bot-thread sends can drain before any desk is opened.
        if let router { installBotQueueHooks(on: router) }
        restoreQueuedFollowUpsIfNeeded()
        restoreComposerDraftsIfNeeded()
        restoreInspectorDraftsIfNeeded()
        restoreStudioDraftIfNeeded()
        restoreInspectorTabIfNeeded()
        restoreStudioTabIfNeeded()
        restoreShowHiddenIfNeeded()
        restoreBrainPaneIfNeeded()
        restoreDeskSidePaneIfNeeded()
        restoreDeskSidePaneWidthIfNeeded()
        restoreDeskThreadRailIfNeeded()
        restoreDeskThreadRailWidthIfNeeded()
        restoreSearchTextIfNeeded()
        restoreDeskRoutingIfNeeded()
        restorePeerHandoffsIfNeeded()
        restoreStudioFilesLocationsIfNeeded()
        restoreUnpublishedNewBotIDsIfNeeded()
        restoreShellSidebarCollapsedIfNeeded()
        observeShellSidebarVisibility()
        bindTokenSaverThreadFooter()
        if loadImmediately {
            reload()
        }
        restoreScreenIfNeeded()
        studioDraftHydrated = true
        if !composerHydrated {
            applyComposerDraft(for: selectedBotID)
        }
        if !inspectorHydrated {
            applyInspectorDraft(for: selectedBotID)
        }
        if !deskRoutingHydrated {
            applyDeskRouting(for: selectedConversation)
        }
        publishInterestedDeskThreadID()
        context.coordinator.addObserver(self)
    }

    deinit {
        deskLiveTurnWatch?.cancel()
        tokenSaverFooterReloadTask?.cancel()
        navigationFreshnessTask?.cancel()
        if let shellSidebarVisibilityObserver {
            NotificationCenter.default.removeObserver(shellSidebarVisibilityObserver)
        }
        if let tokenSaverFooterObserver {
            NotificationCenter.default.removeObserver(tokenSaverFooterObserver)
        }
        if let tokenSaverFooterAccountObserver {
            NotificationCenter.default.removeObserver(tokenSaverFooterAccountObserver)
        }
        if let tokenSaverFooterStatusObserver {
            NotificationCenter.default.removeObserver(tokenSaverFooterStatusObserver)
        }
        context.coordinator.removeObserver(self)
    }

    /// Shell and detached hosts opt into cache-first selection. Direct model
    /// callers retain eager loading for backwards-compatible unit semantics.
    public func enableNavigationFirstFrameDeferral() {
        navigationFirstFrameDeferral = true
    }

    /// Detached windows seed only the requested identity for first paint. The
    /// normal Desk side effects run from `scheduleFreshnessPass` after SwiftUI
    /// has had one turn to mount the exact destination.
    func prepareDetachedDesk(botID: BotID) {
        detachedDeskBotID = botID
        if let bot = try? botStore.get(id: botID), bot.deletedAt == nil {
            openDeskFromCache(bot)
        } else {
            adoptSelectedBot(botID)
            screen = .desk
        }
    }

    public func scheduleFreshnessPass() {
        guard navigationFirstFrameDeferral else { return }
        if let botID = detachedDeskBotID {
            scheduleNavigationFreshness(.desk(botID: botID, reloadFirst: true))
        } else {
            scheduleNavigationFreshness(.reload)
        }
    }

    func waitForNavigationFreshnessForTesting() async {
        while let task = navigationFreshnessTask {
            let generation = navigationFreshnessGeneration
            await task.value
            if navigationFreshnessGeneration == generation,
               navigationFreshnessTask == nil {
                return
            }
        }
    }

    /// BT-28: the SQLite fallback below ran from the view body on every pass
    /// whenever the selected bot was not in `bots` (detached windows, filtered
    /// rosters). Cache it per id; `bots` reloads invalidate.
    private var selectedBotFallbackCache: (id: BotID, bot: BotDefinition?)?

    public var selectedBot: BotDefinition? {
        if let bot = bots.first(where: { $0.id == selectedBotID }) { return bot }
        guard let selectedBotID else { return nil }
        if let cached = selectedBotFallbackCache, cached.id == selectedBotID {
            return cached.bot
        }
        let bot = try? botStore.get(id: selectedBotID)
        selectedBotFallbackCache = (selectedBotID, bot)
        return bot
    }

    public var fleet: [BotDefinition] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered: [BotDefinition]
        if query.isEmpty {
            filtered = bots
        } else {
            filtered = bots.filter { bot in
                bot.name.range(of: query, options: .caseInsensitive) != nil
                    || bot.handle.range(of: query, options: .caseInsensitive) != nil
                    || bot.title.range(of: query, options: .caseInsensitive) != nil
                    || bot.description.range(of: query, options: .caseInsensitive) != nil
            }
        }
        var result = filtered.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned && !rhs.pinned }
            return lhs.updatedAt > rhs.updatedAt
        }
        // Search must not hide the open teammate while Chat still shows them.
        if let id = selectedBotID,
           let selected = bots.first(where: { $0.id == id }),
           !result.contains(where: { $0.id == id }) {
            result.insert(selected, at: 0)
        }
        return result
    }

    private func publishRosterIfNeeded() {
        let next = fleet
        guard next != publishedRoster else { return }
        publishedRoster = next
    }

    public var openAttentionCount: Int { attentionItems.count }

    public var chromeTitle: String {
        switch screen.resolvedDestination {
        case .activeBots: return BotsChrome.Label.activeBots
        case .scheduleTasks: return BotsChrome.Label.scheduleTasks
        default: return BotsChrome.Label.bots
        }
    }

    /// Bots that are actually running — same idea as Active Threads.
    /// Needs-you is not a live run.
    /// Recomputes the stored `activeBotCount`. Called only where the inputs
    /// change: roster/attention/handoff writes (didSet), run status transitions,
    /// and the Active Bots screen reload. Bodies read the stored count —
    /// `liveWorkingBots()` costs two SQLite queries plus a coordinator lock
    /// (perf BT-01).
    public func refreshActiveBotCount() {
        let next = liveWorkingBots().count
        if next != activeBotCount {
            activeBotCount = next
        }
    }

    public var activeBotsFooterLine: String {
        let activeLabel = activeBotCount == 1 ? "1 active" : "\(activeBotCount) active"
        let finishedLabel = finishedBotItems.count == 1
            ? "1 recent finished"
            : "\(finishedBotItems.count) recent finished"
        return "\(activeLabel) · \(finishedLabel)"
    }

    public var activeBotsSubtitle: String {
        if activeBotCount == 0 {
            return "No bots running right now"
        }
        return activeBotCount == 1
            ? "1 bot is running"
            : "\(activeBotCount) bots are running"
    }

    public func filteredActiveBotItems() -> [ActiveBotScreenItem] {
        filterActiveBotSearch(activeBotItems)
    }

    public func filteredFinishedBotItems() -> [FinishedBotScreenItem] {
        let query = activeBotsSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return finishedBotItems }
        return finishedBotItems.filter {
            $0.title.range(of: query, options: .caseInsensitive) != nil || $0.detail.range(of: query, options: .caseInsensitive) != nil
        }
    }

    private func filterActiveBotSearch(_ items: [ActiveBotScreenItem]) -> [ActiveBotScreenItem] {
        let query = activeBotsSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return items }
        return items.filter {
            $0.title.range(of: query, options: .caseInsensitive) != nil
                || $0.handle.range(of: query, options: .caseInsensitive) != nil
                || $0.detail.range(of: query, options: .caseInsensitive) != nil
                || ($0.preview?.range(of: query, options: .caseInsensitive) != nil)
        }
    }

    public func openScheduleTasks() {
        requestLeaveUnsavedNewBot { [weak self] in
            self?.openScheduleTasksNow()
        }
    }

    private func openScheduleTasksNow() {
        screen = .scheduleTasks
        if navigationFirstFrameDeferral {
            scheduleFreshnessPass()
        } else {
            reloadScheduleTasks()
        }
    }

    public func reloadScheduleTasks() {
        let rows: [BotScheduleTaskItem] = bots.flatMap { bot in
            ((try? botStore.listRoutines(botID: bot.id)) ?? []).map { routine in
                BotScheduleTaskItem(routine: routine, bot: bot)
            }
        }
        .sorted { lhs, rhs in
            if lhs.isEnabled != rhs.isEnabled { return lhs.isEnabled && !rhs.isEnabled }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        scheduleTaskSource = rows
        applyScheduleTaskFilters()
    }

    public func createScheduleTask() {
        guard let bot = selectedBot ?? bots.first else {
            errorMessage = "Create a bot before adding a scheduled task."
            return
        }
        scheduleTaskDraft = BotScheduleTaskDraft(botID: bot.id)
    }

    public func editScheduleTask(_ item: BotScheduleTaskItem) {
        scheduleTaskDraft = BotScheduleTaskDraft(item: item)
    }

    /// Studio and the Desk inspector only listed Test run / Active.
    /// Open the same Edit Scheduled Task screen the fleet dest already uses.
    public func editRoutine(_ routine: BotRoutine) {
        guard let bot = bots.first(where: { $0.id == routine.definition.botID }) else {
            errorMessage = "Pick a bot for this scheduled task."
            return
        }
        editScheduleTask(BotScheduleTaskItem(routine: routine, bot: bot))
        openScheduleTasks()
    }

    public func saveScheduleTask(_ draft: BotScheduleTaskDraft) {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !prompt.isEmpty else {
            errorMessage = "Task name and instruction are required."
            return
        }
        guard bots.contains(where: { $0.id == draft.botID }) else {
            errorMessage = "Pick a bot for this scheduled task."
            return
        }
        do {
            let spec = draft.spec
            _ = try spec.makeRecurrence()
            let definition = BotRoutineDefinition(
                id: draft.id,
                botID: draft.botID,
                name: name,
                prompt: prompt,
                scheduleNote: spec.displayNote(),
                scheduleSpecJSON: spec.encodedJSON()
            )
            try botStore.saveRoutine(definition)
            try botStore.setRoutineEnabled(id: definition.id, enabled: draft.isEnabled)
            if selectedBotID == draft.botID {
                adoptWrittenRoutine(definition)
                adoptEnabledRoutine(id: definition.id, enabled: draft.isEnabled)
            }
            scheduleTaskDraft = nil
            reloadScheduleTasks()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func deleteScheduleTask(_ item: BotScheduleTaskItem) {
        do {
            try botStore.deleteRoutine(id: item.id)
            if selectedBotID == item.botID {
                routines.removeAll { $0.definition.id == item.id }
            }
            reloadScheduleTasks()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func setAutonomyActive(_ on: Bool) {
        settingsStore.update { $0.botsAutonomyEnabled = on }
        refreshFlags()
    }

    public var scheduleTasksFooterLine: String {
        let all = scheduleTaskFilterCounts.all
        let active = scheduleTaskFilterCounts.active
        let tasks = all == 1 ? "1 task" : "\(all) tasks"
        let live = active == 1 ? "1 active" : "\(active) active"
        return "\(tasks) · \(live)"
    }

    public var scheduleTasksSubtitle: String {
        if isAutonomyActive {
            return "Automate recurring bot work"
        }
        return "Automatic runs paused — turn Active on when you're back"
    }

    private var scheduleTaskSource: [BotScheduleTaskItem] = []

    private func applyScheduleTaskFilters() {
        let query = scheduleTaskSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let searched: [BotScheduleTaskItem]
        if query.isEmpty {
            searched = scheduleTaskSource
        } else {
            searched = scheduleTaskSource.filter { item in
                item.name.range(of: query, options: .caseInsensitive) != nil
                    || item.botName.range(of: query, options: .caseInsensitive) != nil
                    || item.prompt.range(of: query, options: .caseInsensitive) != nil
                    || item.scheduleNote.range(of: query, options: .caseInsensitive) != nil
            }
        }
        // PERF: single pass derives counts + the status-filtered list
        // instead of two counting filters plus a third listing filter.
        var activeCount = 0
        var visible: [BotScheduleTaskItem] = []
        let showAll = scheduleTaskStatusFilter == .all
        let wantActive = scheduleTaskStatusFilter == .active
        if !showAll {
            visible.reserveCapacity(searched.count)
        }
        for item in searched {
            if item.isEnabled { activeCount += 1 }
            if showAll || item.isEnabled == wantActive {
                if !showAll { visible.append(item) }
            }
        }
        scheduleTaskFilterCounts = (
            all: searched.count,
            active: activeCount,
            paused: searched.count - activeCount
        )
        switch scheduleTaskStatusFilter {
        case .all:
            scheduleTaskItems = searched
        case .active, .paused:
            scheduleTaskItems = visible
        }
    }

    /// Dest to the Active Bots overview (Active / Last Finished), not a desk.
    public func openActiveBots() {
        requestLeaveUnsavedNewBot { [weak self] in
            self?.openActiveBotsNow()
        }
    }

    private func openActiveBotsNow() {
        screen = .activeBots
        scheduleActiveBotsFreshness()
    }

    public func scheduleActiveBotsFreshness() {
        if navigationFirstFrameDeferral {
            scheduleNavigationFreshness(.activeBots)
        } else {
            reloadActiveBotsScreen()
        }
    }

    public func openActiveBotItem(_ item: ActiveBotScreenItem) {
        if let bot = bots.first(where: { $0.id == item.botID }) ?? (try? botStore.get(id: item.botID)) {
            openDesk(bot)
        }
    }

    public func openFinishedBotItem(_ item: FinishedBotScreenItem) {
        if let bot = bots.first(where: { $0.id == item.botID }) ?? (try? botStore.get(id: item.botID)) {
            openDesk(bot)
        }
    }

    public func reloadActiveBotsScreen() {
        guard screen.resolvedDestination == .activeBots else { return }
        activeBotsHydrationCountForTesting += 1
        settleTerminalWorkingConversations()
        let liveBots = liveWorkingBots()
        if activeBotCount != liveBots.count {
            activeBotCount = liveBots.count
        }
        let inMemoryStartedAt = Dictionary(uniqueKeysWithValues: liveBots.compactMap { bot in
            inMemoryStartedAtForLiveBot(bot).map { (bot.id, $0) }
        })
        let fallbackBotIDs = Set(liveBots.map(\.id)).subtracting(Set(inMemoryStartedAt.keys))
        let persistedStartedAt = (
            try? botStore.latestConversationUpdatedAt(botIDs: fallbackBotIDs)
        ) ?? [:]
        activeBotItems = liveBots.map { bot in
            ActiveBotScreenItem(
                bot: bot,
                preview: rosterPreview(for: bot),
                providerName: PetActiveThreadProjector.providerLabel(
                    resolvedProvider(for: bot) ?? deskRouting.provider
                ),
                startedAt: inMemoryStartedAt[bot.id] ?? persistedStartedAt[bot.id]
            )
        }
        reloadFinishedBots()
    }

    public func liveWorkingBots() -> [BotDefinition] {
#if DEBUG
        liveWorkingBotsCountForTesting += 1
#endif
        var seen = Set<BotID>()
        var result: [BotDefinition] = []
        let handoffBotIDs = activeHandoffBotIDs()
        let rosterBotIDs = Set(bots.map(\.id))
        let missingHandoffBotIDs = handoffBotIDs.subtracting(rosterBotIDs)
        let missingHandoffBots = (try? botStore.bots(ids: missingHandoffBotIDs)) ?? [:]
        for botID in handoffBotIDs {
            guard let bot = bots.first(where: { $0.id == botID })
                    ?? missingHandoffBots[botID] else { continue }
            seen.insert(botID)
            result.append(bot)
        }
        for bot in bots {
            guard !seen.contains(bot.id) else { continue }
            if attentionState(for: bot) == .working {
                seen.insert(bot.id)
                result.append(bot)
            }
        }
        let activeThreadIDs = activeThreadIDsOverrideForTesting
            ?? context.coordinator.activeThreadIdsSnapshot()
        let linkedConversations = (try? botStore.conversationsLinked(to: activeThreadIDs)) ?? [:]
        for threadID in activeThreadIDs {
            guard let conversation = linkedConversations[threadID] else { continue }
            guard !seen.contains(conversation.botID) else { continue }
            guard let bot = bots.first(where: { $0.id == conversation.botID }) else { continue }
            seen.insert(bot.id)
            result.append(bot)
        }
        return result
    }

    private func inMemoryStartedAtForLiveBot(_ bot: BotDefinition) -> Date? {
        if let handoff = peerHandoffs.values
            .filter({ activeBotIDs(for: $0).contains(bot.id) })
            .min(by: { $0.createdAt < $1.createdAt }) {
            return handoff.createdAt
        }
        return lastUpdatedByBot[bot.id]
    }

    private func reloadFinishedBots() {
        let runs = (try? context.runRepo.listRecentFinished(limit: 200)) ?? []
        let linkedConversations = (
            try? botStore.conversationsLinked(to: Set(runs.map(\.threadId)))
        ) ?? [:]
        let rosterBotIDs = Set(bots.map(\.id))
        let missingBotIDs = Set(linkedConversations.values.map(\.botID)).subtracting(rosterBotIDs)
        let missingBots = (try? botStore.bots(ids: missingBotIDs)) ?? [:]
        var items: [FinishedBotScreenItem] = []
        var seen = Set<AgentRunID>()
        for run in runs {
            guard items.count < 50 else { break }
            guard !seen.contains(run.id) else { continue }
            guard let conversation = linkedConversations[run.threadId] else { continue }
            let bot = bots.first(where: { $0.id == conversation.botID })
                ?? missingBots[conversation.botID]
            guard let bot else { continue }
            seen.insert(run.id)
            items.append(
                FinishedBotScreenItem(
                    run: run,
                    bot: bot,
                    conversationTitle: conversation.title
                )
            )
        }
        finishedBotItems = items
    }

    public func attentionState(for bot: BotDefinition) -> BotAttentionState {
        let state = attentionStateByBot[bot.id] ?? .none
        if isViewing(bot.id), state == .unreadActivity { return .none }
        if isViewing(bot.id), state == .needsAttention, !viewingConversationNeedsYou(bot) {
            return .none
        }
        return state
    }

    /// A leftover failed/interrupted run on another thread is not a live ask.
    /// Keep Needs you while this conversation is the failed one, or while a
    /// question/approval is still open for this teammate.
    private func viewingConversationNeedsYou(_ bot: BotDefinition) -> Bool {
        if let selected = selectedConversation, selected.botID == bot.id,
           selected.attentionState == .needsAttention {
            return true
        }
        return attentionItems.contains { item in
            guard item.acknowledgedAt == nil, item.botID == bot.id else { return false }
            switch item.kind {
            case .question, .approval:
                return true
            case .handoff, .unread, .blocked, .unknownEffect:
                return false
            }
        }
    }

    public func isViewing(_ botID: BotID) -> Bool {
        selectedBotID == botID && screen == .desk
    }

    public func rosterPreview(for bot: BotDefinition) -> String {
        if let preview = lastPreviewByBot[bot.id], !preview.isEmpty {
            return BotsDeskFollowThrough.displayUserText(from: preview)
        }
        if !bot.title.isEmpty { return bot.title }
        return "No job yet"
    }

    public func rosterTimestamp(for bot: BotDefinition) -> Date? {
        lastUpdatedByBot[bot.id]
    }

    public func currentGoal(for bot: BotDefinition) -> String {
        if let conversation = selectedConversation, conversation.botID == bot.id,
           !conversation.title.isEmpty {
            return BotsDeskFollowThrough.displayUserText(from: conversation.title)
        }
        let preview = rosterPreview(for: bot)
        if preview == "No job yet" { return "No current goal" }
        return preview
    }

    public func activityRows(for bot: BotDefinition) -> [BotActivityRow] {
        let cached = messagesByBot[bot.id] ?? []
        let source = cached.isEmpty && selectedBotID == bot.id ? deskMessages : cached
        let rows = source.suffix(4).map { message in
            BotActivityRow(id: message.id, text: message.text, createdAt: message.createdAt)
        }
        if !rows.isEmpty { return Array(rows) }
        if let preview = lastPreviewByBot[bot.id], let stamp = lastUpdatedByBot[bot.id] {
            return [BotActivityRow(text: preview, createdAt: stamp)]
        }
        return []
    }

    public var deskPaintsLiveTurnChrome: Bool {
        AgentChatLiveTurnChrome.paintsLiveTurnChrome(deskLiveTimeline)
    }

    public var deskHasStreamingTools: Bool {
        AgentChatLiveTurnChrome.hasStreamingTools(in: deskLiveTimeline)
    }

    /// BT-22: `BotsDeskFollowThrough.timeline` rebuilds the whole transcript
    /// model — with a `messages × turns × items × bytes` duplicate scan and a
    /// sort whose comparator walks each turn's items — and it used to run on
    /// EVERY body pass. Memoize on a structural key; token deltas keep the key
    /// and only rematerialize the live turn snapshots so streamed text is fresh.
    private final class DeskTimelineCache {
        var key = ""
        var items: [BotDeskTimelineItem] = []
        var hasUnfinishedSegments = false
    }
    private let deskTimelineCache = DeskTimelineCache()
    public private(set) var deskTimelineComputeCountForTesting = 0

    public var deskTimeline: [BotDeskTimelineItem] {
        let paintsLiveChrome = deskPaintsLiveTurnChrome
        let key = cacheKeyForDeskTimeline(paintsLiveChrome: paintsLiveChrome)
        if deskTimelineCache.key == key, !deskTimelineCache.hasUnfinishedSegments {
            var liveById = [String: AssistantTurnSnapshot](minimumCapacity: deskLiveTimeline.turns.count)
            for turn in deskLiveTimeline.turns { liveById[turn.turnId] = turn }
            return deskTimelineCache.items.map { item in
                if case .liveTurn(let turn, let hide) = item, let live = liveById[turn.turnId] {
                    return .liveTurn(live, hideAssistantOutput: hide)
                }
                return item
            }
        }
        deskTimelineComputeCountForTesting += 1
        let items = BotsDeskFollowThrough.timeline(
            messages: deskMessages,
            workLog: deskWorkLog,
            turns: deskLiveTimeline.turns,
            hideWorkLog: paintsLiveChrome,
            hideWorkingPlaceholder: paintsLiveChrome || deskRunIsLive
        )
        deskTimelineCache.key = key
        deskTimelineCache.items = items
        // Segments embed item slices that cannot be rematerialized by turn id;
        // while a split turn is still streaming, fall back to recomputing.
        deskTimelineCache.hasUnfinishedSegments = items.contains {
            if case .liveTurnSegment(let segment, _) = $0 { return !segment.snapshot.finished }
            return false
        }
        return items
    }

    /// Everything `BotsDeskFollowThrough.timeline` reads except live bodies:
    /// message identities/lengths/roles, work-log rows, turn structure,
    /// completion and finals, plus whether the live turn has any assistant text.
    private func cacheKeyForDeskTimeline(paintsLiveChrome: Bool) -> String {
        var hasher = Hasher()
        hasher.combine(deskMessages.count)
        for message in deskMessages {
            hasher.combine(message.id)
            hasher.combine(message.text.utf8.count)
            hasher.combine(message.role == .assistant)
            hasher.combine(message.role == .user)
            hasher.combine(message.createdAt.timeIntervalSinceReferenceDate)
        }
        hasher.combine(deskWorkLog.count)
        for row in deskWorkLog {
            hasher.combine(row.id)
            hasher.combine(row.statusLabel)
        }
        let turns = deskLiveTimeline.turns
        hasher.combine(turns.count)
        for turn in turns {
            hasher.combine(turn.turnId)
            hasher.combine(turn.items.count)
            hasher.combine(turn.finished)
            hasher.combine(turn.finalAssistantMessage?.utf8.count ?? -1)
            hasher.combine(turn.startedAtMs ?? -1)
        }
        if let last = turns.last, !last.finished {
            var assistantBodies = 0
            for item in last.items where item.type == .assistantMessage && !item.body.isEmpty {
                assistantBodies += 1
            }
            hasher.combine(assistantBodies)
        }
        hasher.combine(paintsLiveChrome)
        hasher.combine(deskRunIsLive)
        return String(hasher.finalize())
    }

    public func modelLabel(for bot: BotDefinition) -> String? {
        if bot.id == selectedBotID {
            return deskModelDisplayLabel
        }
        return resolvedThreadRouting(for: bot).flatMap {
            trimmedNonEmpty($0.resolvedModel(defaultModel: Self.defaultModel(for:)))
        }
    }

    public func permissionLabel(for bot: BotDefinition) -> String {
        if bot.id == selectedBotID {
            return deskRouting.permissionMode.displayName
        }
        return AgentPermissionMode.supervised.displayName
    }

    private func trimmedNonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func reload() {
        refreshFlags()
        repairLegacyUserStopAttentionIfNeeded()
        // Dest first. Remount dest used to scan every teammate's
        // conversations + recent messages before dest dested Chat.
        // Dest already has this teammate's thread and dest cache.
        let selectedBotIDBeforeReload = selectedBotID
        let selectedConversationIDBeforeReload = selectedConversation?.id
        if !bots.isEmpty, let selectedBotID {
            reloadSelectedBot(id: selectedBotID)
        }
        reloadFleet()
        restoreSelectedBotIfNeeded()
        if let selectedBotID {
            // Perf BT-12: the pre-fleet pass already restored this exact bot and
            // conversation; a remount that keeps both must not repeat the desk
            // restore reads (messages, work log, live turn, inspector support).
            let conversationChanged = selectedConversation?.id != selectedConversationIDBeforeReload
            if selectedBotID != selectedBotIDBeforeReload || conversationChanged {
                reloadSelectedBot(id: selectedBotID)
            }
        }
        // Dest first. First paint dest used to dest inbox
        // (listAttention) before dest dested Chat. Dest dests
        // this bubble first; dest dests inbox after dest dested Chat.
        reloadAttention()
        settleTerminalWorkingConversations()
        if screen.resolvedDestination == .activeBots {
            reloadActiveBotsScreen()
        }
        if screen.resolvedDestination == .scheduleTasks {
            reloadScheduleTasks()
        }
        Task { [weak self, weak router = resolvedRouter()] in
            guard let router else { return }
            let cached = router.cachedProviderSnapshotsForSend()
            if !cached.isEmpty {
                self?.providers = cached
                return
            }
            let providers = await router.listAgentProviderSnapshots()
            self?.providers = providers
        }
    }

    /// Same eligibility + ledger binding Agent App uses (`wireTokenSaverThreadFooter`).
    func bindTokenSaverThreadFooter() {
        let handler: (Notification) -> Void = { [weak self] _ in
            self?.reloadTokenSaverThreadSavings()
        }
        if tokenSaverFooterObserver == nil {
            tokenSaverFooterObserver = NotificationCenter.default.addObserver(
                forName: Notification.Name("rc2TokenSaverUsageChanged"),
                object: nil,
                queue: .main,
                using: handler
            )
        }
        if tokenSaverFooterAccountObserver == nil {
            tokenSaverFooterAccountObserver = NotificationCenter.default.addObserver(
                forName: Notification.Name("rc2PrivateAccountChanged"),
                object: nil,
                queue: .main,
                using: handler
            )
        }
        if tokenSaverFooterStatusObserver == nil {
            tokenSaverFooterStatusObserver = NotificationCenter.default.addObserver(
                forName: Notification.Name("rc2TokenSaverDistillStatusChanged"),
                object: nil,
                queue: .main,
                using: handler
            )
        }
        reloadTokenSaverThreadSavings()
    }

    private func resetTokenSaverFooterSnapshot() {
        tokenSaverFooterReloadTask?.cancel()
        guard tokenSaverFooterEnabled
            || tokenSaverFooterSnapshotReady
            || tokenSaverThreadMeasuredTokens != 0
            || tokenSaverThreadSavedTokens != 0 else { return }
        tokenSaverFooterEnabled = false
        tokenSaverThreadMeasuredTokens = 0
        tokenSaverThreadSavedTokens = 0
        tokenSaverFooterSnapshotReady = false
    }

    func reloadTokenSaverThreadSavings() {
        tokenSaverFooterReloadTask?.cancel()
        let ownerBotID = selectedBotID
        let ownerConversationID = selectedConversation?.id
        let threadId = selectedConversation?.linkedAgentThreadID
        // PL-02: snapshot on the MainActor, reduce + read off-main. `Task { }`
        // inside a @MainActor class inherits the actor, so the previous "off-main"
        // body ran three SettingsStore loads + the O(messages) reduce on main on
        // every `.rc2TokenSaverUsageChanged` (≥ every 2 s with active runs).
        let messageSnapshot = deskMessages
        let liveTurnCount = deskLiveTimeline.turns.count
        let usage = deskLiveTimeline.tokenUsage
        let autoRoutingActive = deskRouting.routingMode == .auto
        let db = context.db
        let settingsRepo = context.settingsRepo
        let savingsRepo = context.tokenSaverSavingsRepo
        let graphifyRepo = context.graphifyUsageRepo
        tokenSaverFooterReloadTask = Task.detached(priority: .utility) { [weak self] in
            let assistantChars = messageSnapshot
                .filter { $0.role == .assistant }
                .reduce(0) { $0 + $1.text.utf8.count }
            let turnCount = max(
                liveTurnCount,
                messageSnapshot.filter { $0.role == .user }.count
            )
            let observation = TokenSaverThreadFooterReload.Observation(
                assistantChars: assistantChars,
                turnCount: turnCount,
                cacheReadInputTokens: usage?.cacheReadInputTokens ?? 0,
                providerRawTokens: usage.map { max(0, $0.inputTokens) + max(0, $0.outputTokens) } ?? 0,
                providerBilledTokenUnits: usage.map(\.billedTotalTokenUnits).flatMap { $0 > 0 ? $0 : nil },
                autoRoutingActive: autoRoutingActive
            )
            let settings = SettingsStore(db: db).load()
            let eligible = settings.tokenSaverEnabled
                && PrivateAccountSessionStore(repo: settingsRepo).load()?.user.subscribed == true
            let graphifyActive = settings.isGraphifyRuntimeActive
            let total = await TokenSaverThreadFooterReload.loadDeliveredTotal(
                eligible: eligible,
                threadId: threadId,
                repo: savingsRepo
            )
            guard let total else { return }
            guard !Task.isCancelled else { return }
            let next = TokenSaverThreadFooterReload.snapshot(
                measuredDelivered: total.savedTokens,
                eligible: eligible,
                graphifyActive: graphifyActive,
                observation: TokenSaverThreadFooterReload.Observation(
                    assistantChars: observation.assistantChars,
                    turnCount: observation.turnCount,
                    cacheReadInputTokens: observation.cacheReadInputTokens,
                    providerRawTokens: observation.providerRawTokens,
                    providerBilledTokenUnits: observation.providerBilledTokenUnits,
                    autoRoutingActive: observation.autoRoutingActive,
                    graphifySignalCount: TokenSaverThreadFooterReload.currentDayGraphifySignalCount(
                        repo: graphifyRepo
                    )
                ),
                deliveredRuns: total.runs
            )
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                guard self.selectedBotID == ownerBotID,
                      self.selectedConversation?.id == ownerConversationID,
                      self.selectedConversation?.linkedAgentThreadID == threadId else {
                    return
                }
                let current = TokenSaverThreadFooterReload.Snapshot(
                    enabled: self.tokenSaverFooterEnabled,
                    measuredTokens: self.tokenSaverThreadMeasuredTokens,
                    displayTokens: self.tokenSaverThreadSavedTokens
                )
                if TokenSaverThreadFooterReload.shouldPublish(current: current, next: next) {
                    self.tokenSaverFooterEnabled = next.enabled
                    self.tokenSaverThreadMeasuredTokens = next.measuredTokens
                    self.tokenSaverThreadSavedTokens = next.displayTokens
                }
                self.tokenSaverFooterSnapshotReady = true
            }
        }
    }

    func tokenSaverDisplaysOriginal(for messageId: AgentMessageID) -> Bool {
        tokenSaverOriginalDisplayMessageIds.contains(messageId)
    }

    func setTokenSaverDisplaysOriginal(_ displaysOriginal: Bool, for messageId: AgentMessageID) {
        let previousValue = tokenSaverOriginalDisplayMessageIds.contains(messageId)
        guard previousValue != displaysOriginal else { return }
        if displaysOriginal {
            tokenSaverOriginalDisplayMessageIds.insert(messageId)
        } else {
            tokenSaverOriginalDisplayMessageIds.remove(messageId)
        }
        let generation = (tokenSaverDisplayModeWriteGeneration[messageId] ?? 0) &+ 1
        tokenSaverDisplayModeWriteGeneration[messageId] = generation
        let previousTask = tokenSaverDisplayModeWriteTasks[messageId]
        let repository = context.messageRepo
        let mode: AgentMessageTokenSaverDisplayMode = displaysOriginal ? .rcw1 : .human
        tokenSaverDisplayModeWriteTasks[messageId] = Task { @MainActor [weak self] in
            await previousTask?.value
            do {
                try await AgentAppViewModel.persistTokenSaverDisplayModeOffMain(
                    repository: repository,
                    messageId: messageId,
                    mode: mode
                )
            } catch {
                guard let self,
                      self.tokenSaverDisplayModeWriteGeneration[messageId] == generation else {
                    return
                }
                if previousValue {
                    self.tokenSaverOriginalDisplayMessageIds.insert(messageId)
                } else {
                    self.tokenSaverOriginalDisplayMessageIds.remove(messageId)
                }
                self.errorMessage = "Token Saver display choice could not be saved: \(error.localizedDescription)"
            }
            guard let self,
                  self.tokenSaverDisplayModeWriteGeneration[messageId] == generation else {
                return
            }
            self.tokenSaverDisplayModeWriteGeneration.removeValue(forKey: messageId)
            self.tokenSaverDisplayModeWriteTasks.removeValue(forKey: messageId)
        }
    }

    var deskTokenSaverFooterText: String? {
        AgentChatTokenSaverDisplayMode.footerText(
            displayTokens: tokenSaverThreadSavedTokens,
            measuredTokens: tokenSaverThreadMeasuredTokens,
            enabled: tokenSaverFooterEnabled,
            autoRoutingActive: deskRouting.routingMode == .auto,
            snapshotReady: tokenSaverFooterSnapshotReady
        )
    }

    var deskTokenSaverFooterPresentation: AgentChatTokenSaverThreadFooterPresentation? {
        AgentChatTokenSaverDisplayMode.footerPresentation(
            enabled: tokenSaverFooterEnabled,
            measuredTokens: tokenSaverThreadMeasuredTokens,
            snapshotReady: tokenSaverFooterSnapshotReady
        )
    }

    func tokenSaverFooterTextForTesting() -> String? { deskTokenSaverFooterText }

    func applyTokenSaverFooterSnapshotForTesting(_ snapshot: TokenSaverThreadFooterReload.Snapshot) {
        tokenSaverFooterEnabled = snapshot.enabled
        tokenSaverThreadMeasuredTokens = snapshot.measuredTokens
        tokenSaverThreadSavedTokens = snapshot.displayTokens
        tokenSaverFooterSnapshotReady = true
    }

    func awaitTokenSaverFooterReloadForTesting() async {
        await tokenSaverFooterReloadTask?.value
    }

    func replaceDeskMessagesForTesting(_ messages: [BotDeskMessage]) {
        deskMessages = messages
    }

    func replaceDeskLiveTimelineForTesting(_ timeline: AssistantTimelineState) {
        deskLiveTimeline = timeline
    }

    func tokenSaverMessage(forTurnId turnId: String) -> BotDeskMessage? {
        guard let matches = tokenSaverMessagesByTurnId[turnId], matches.count == 1 else { return nil }
        return matches[0]
    }

    public func beginCreate() {
        requestLeaveUnsavedNewBot { [weak self] in
            self?.beginCreateNow()
        }
    }

    private func beginCreateNow() {
        guard isControlPlaneActive else {
            errorMessage = "Turn on Bot control plane in Settings"
            return
        }
        do {
            // New Bot is a configure dest: persist the placeholder, then
            // open Studio Profile so name and role are set before Chat.
            // Hermes seeds SOUL.md on first run — do not start a soulless New Agent.
            // The row stays unpublished until Save Bot. Leaving Studio
            // confirms so Back does not keep a teammate the owner never saved.
            let previous = selectedBotID
            let name = "New Agent"
            let bot = try create(
                name: name,
                title: "",
                description: "",
                soul: BotStandingInstructions.fallback(name: name, title: "", description: ""),
                avatarSymbol: BotBlobatarSpec.default.token
            )
            beginEdit(bot)
            botIDBeforeCreate = previous
            markUnpublishedNewBot(bot.id)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public var needsUnsavedNewBotConfirm: Bool {
        guard screen.resolvedDestination == .studio, let id = selectedBotID else { return false }
        return unpublishedNewBotIDs.contains(id)
    }

    public func requestLeaveUnsavedNewBot(then proceed: @escaping () -> Void) {
        guard needsUnsavedNewBotConfirm else {
            proceed()
            return
        }
        pendingUnsavedNewBotLeave = proceed
        pendingUnsavedNewBotConfirm = true
    }

    public func cancelUnsavedNewBotLeave() {
        pendingUnsavedNewBotLeave = nil
        pendingUnsavedNewBotConfirm = false
    }

    public func discardUnsavedNewBotAndLeave() {
        let id = selectedBotID
        let proceed = pendingUnsavedNewBotLeave
        pendingUnsavedNewBotLeave = nil
        pendingUnsavedNewBotConfirm = false
        if let id, unpublishedNewBotIDs.contains(id) {
            delete(id: id, navigate: false)
        }
        proceed?()
    }

    public func leaveStudioAfterUnsavedGate() {
        if let bot = selectedBot {
            openDesk(bot)
            return
        }
        if let previous = botIDBeforeCreate, let bot = bots.first(where: { $0.id == previous }) {
            openDesk(bot)
            return
        }
        if let next = fleet.first {
            openDesk(next)
            return
        }
        adoptSelectedBot(nil)
        screen = .desk
        persistSelection()
    }

    public func requestLeaveBotsMode() {
        flushPendingDraftPersistence()
        requestLeaveUnsavedNewBot { [weak self] in
            guard let self else { return }
            self.invalidateNavigationFreshness()
            self.onLeaveBots?()
        }
    }

    public func openDeskFromRoster(_ bot: BotDefinition) {
        requestLeaveUnsavedNewBot { [weak self] in
            guard let self else { return }
            if self.bots.contains(where: { $0.id == bot.id }) {
                self.openDesk(bot)
            } else {
                self.leaveStudioAfterUnsavedGate()
            }
        }
    }

    public func beginEdit(_ bot: BotDefinition) {
        let fresh = refreshPublishedIdentity(for: bot.id) ?? bot
        loadStudioDraft(fresh)
        studioTab = .profile
        screen = .studio
        reloadBotSecrets(for: fresh)
        ensureBotHome(fresh, revision: selectedRevision)
        persistSelection()
        leaveDeskLiveWatch()
        reloadStudioSupport(id: fresh.id)
        refreshDockerGuestProbe()
    }

    public var studioSlugFollowsName: Bool {
        studioDraft.slugFollowsName
            ?? BotHandle.shouldFollowName(handle: studioDraft.handle, name: studioDraft.name)
    }

    public func didEditStudioName(_ name: String) {
        var next = studioDraft
        let followsName = next.slugFollowsName
            ?? BotHandle.shouldFollowName(handle: next.handle, name: next.name)
        next.name = name
        if followsName, let derived = BotHandle.derive(from: name) {
            next.handle = derived
            next.slugFollowsName = true
        }
        if BotStandingInstructions.looksGenerated(next.soul) {
            next.soul = BotStandingInstructions.fallback(
                name: next.name,
                title: next.title,
                description: next.description
            )
        }
        studioDraft = next
    }

    public func didEditStudioSlug(_ raw: String) {
        studioDraft.handle = raw
        studioDraft.slugFollowsName = false
    }

    /// Keep the starter soul aligned with Role & Identity until the user writes their own.
    public func refreshGeneratedStandingInstructions() {
        guard BotStandingInstructions.looksGenerated(studioDraft.soul) else { return }
        studioDraft.soul = BotStandingInstructions.fallback(
            name: studioDraft.name,
            title: studioDraft.title,
            description: studioDraft.description
        )
    }

    /// Desk inspector lists tasks. Creating one is a Studio dest.
    public func openStudioToAddRoutine() {
        guard let bot = selectedBot else { return }
        routineName = ""
        routinePrompt = ""
        routineScheduleNote = ""
        routineSpec = BotScheduleSpec()
        studioTab = .routines
        openStudio(bot)
    }

    /// Studio is a dest. Keep the last selected tab; Edit still opens Profile.
    public func openStudio(_ bot: BotDefinition) {
        let fresh = refreshPublishedIdentity(for: bot.id) ?? bot
        loadStudioDraft(fresh)
        screen = .studio
        reloadBotSecrets(for: fresh)
        persistSelection()
        leaveDeskLiveWatch()
        reloadStudioSupport(id: fresh.id)
        refreshDockerGuestProbe()
    }

    private func loadStudioDraft(_ bot: BotDefinition) {
        // Studio dest used to getRevision on every dest even when the
        // published revision was already in revisionByID from Desk chips.
        let revision = cachedRevision(for: bot)
        isApplyingStudioDraft = true
        studioDraft = BotStudioDraft(
            botID: bot.id,
            name: bot.name,
            title: bot.title,
            description: bot.description,
            handle: bot.handle,
            avatarSymbol: bot.avatarSymbol,
            soul: revision?.soul ?? "",
            notificationsEnabled: bot.notificationsEnabled,
            desktopKind: resolvedDesktopKind(revision?.desktopKind ?? .logicalExecutionSpace),
            expectedRevisionID: bot.currentRevisionID,
            slugFollowsName: BotHandle.shouldFollowName(handle: bot.handle, name: bot.name)
        )
        applyPersistedStudioDraftIfMatching(bot.id)
        isApplyingStudioDraft = false
        adoptSelectedBot(bot.id)
        studioFilesLocation = resolvedStudioFilesLocation(for: bot)
        botSecretsReloadGeneration &+= 1
        botSecretsReloadTask?.cancel()
        botSecretsReloadTask = nil
        botSecrets = []
        isBotSecretsLoading = true
        botSecretsLoadFailed = false
        pendingSecretDeleteName = nil
        cancelBotSecretEdit()
    }

    /// Metadata is loaded after Studio mounts. Only the latest selected Bot
    /// may publish the result; values never enter the view model.
    public func reloadBotSecrets(for bot: BotDefinition? = nil) {
        botSecretsReloadGeneration &+= 1
        let generation = botSecretsReloadGeneration
        botSecretsReloadTask?.cancel()
        botSecretsReloadTask = nil
        botSecrets = []
        guard let bot = bot ?? selectedBot else {
            isBotSecretsLoading = false
            botSecretsLoadFailed = false
            return
        }
        isBotSecretsLoading = true
        botSecretsLoadFailed = false
        let botID = bot.id
        let secretStore = botSecretStore
        botSecretsReloadTask = Task { @MainActor [weak self] in
            do {
                let metadata = try await Task.detached {
                    try secretStore.list(botID: botID)
                }.value
                guard !Task.isCancelled,
                      let self,
                      self.botSecretsReloadGeneration == generation,
                      self.selectedBotID == botID,
                      self.screen == .studio else { return }
                self.botSecretsReloadTask = nil
                self.isBotSecretsLoading = false
                self.botSecretsLoadFailed = false
                self.botSecrets = metadata
            } catch {
                guard !Task.isCancelled,
                      let self,
                      self.botSecretsReloadGeneration == generation,
                      self.selectedBotID == botID,
                      self.screen == .studio else { return }
                self.botSecretsReloadTask = nil
                self.isBotSecretsLoading = false
                self.botSecretsLoadFailed = true
                self.errorMessage = "Protected secret storage is unavailable."
            }
        }
    }

    public func editBotSecret(_ name: String) {
        studioState.secretNameDraft = name
        studioState.secretValueDraft = ""
        studioState.editingSecretName = name
    }

    public func cancelBotSecretEdit() {
        studioState.secretNameDraft = ""
        studioState.secretValueDraft = ""
        studioState.editingSecretName = nil
    }

    public func saveBotSecret() {
        guard let bot = selectedBot else { return }
        do {
            let name = try BotKeychainSecretStore.normalizedName(studioState.secretNameDraft)
            if let editing = studioState.editingSecretName, editing != name {
                throw BotSecretStoreError.invalidName
            }
            try botSecretStore.save(
                botID: bot.id,
                name: name,
                value: studioState.secretValueDraft
            )
            cancelBotSecretEdit()
            reloadBotSecrets(for: bot)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func requestDeleteBotSecret(_ name: String) {
        pendingSecretDeleteName = name
    }

    public func removeBotSecret(_ name: String) {
        guard let bot = selectedBot else { return }
        do {
            try botSecretStore.delete(botID: bot.id, name: name)
            if studioState.editingSecretName == name {
                cancelBotSecretEdit()
            }
            pendingSecretDeleteName = nil
            reloadBotSecrets(for: bot)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func openFleet() {
        reloadFleet()
        reloadAttention()
        restoreSelectedBotIfNeeded()
        if selectedBotID == nil, let first = fleet.first {
            adoptSelectedBot(first.id)
        }
        if let bot = selectedBot {
            openDesk(bot)
        } else {
            screen = .desk
            persistSelection()
        }
    }

    public func openHome(_ bot: BotDefinition) {
        openDesk(bot)
    }

    public func openDesk(_ bot: BotDefinition) {
        guard !navigationFirstFrameDeferral else {
            openDeskFromCache(bot)
            scheduleNavigationFreshness(.desk(botID: bot.id, reloadFirst: false))
            return
        }
        _ = refreshPublishedIdentity(for: bot.id)
        adoptSelectedBot(bot.id)
        screen = .desk
        persistSelection()
        markOpenedConversationRead(botID: bot.id)
        reloadSelectedBot(id: bot.id)
        syncQueuedFollowUps()
        drainQueuedFollowUp()
        deskTimelineRejoinToken &+= 1
        lastGuestScreenURL = guestScreenURLByBot[bot.id.value]
        if displayedDesktopKind == .dockerDesktop {
            presentGuestDesktop(botID: bot.id)
        }
    }

    /// Publish only facts already retained by the selected Bot. The store and
    /// coordinator hydration runs in the one deferred pass below, so a cold
    /// Bot can never briefly show another Bot's transcript or live turn.
    private func openDeskFromCache(_ bot: BotDefinition) {
        let cachedBot = bots.first(where: { $0.id == bot.id }) ?? bot
        adoptSelectedBot(cachedBot.id)
        if screen != .desk {
            screen = .desk
        }
        persistSelection()
        resetTokenSaverFooterSnapshot()
        if let snapshot = studioSupportByBot[cachedBot.id] {
            applyStudioSupport(snapshot, prefetchRail: false)
        } else {
            conversations = conversations.filter { $0.botID == cachedBot.id }
            selectedConversation = destConversation(for: cachedBot.id) ?? conversations.first
            selectedConversationByBot[cachedBot.id] = selectedConversation?.id
            selectedRevision = cachedBot.currentRevisionID.flatMap { revisionByID[$0] }
            skillBindings = []
            memoryItems = []
            lastContextReceipt = nil
            routines = []
        }
        applyDeskRouting(for: selectedConversation, allowStoreLookup: false)
        let cached = cachedMessages(
            botID: cachedBot.id,
            conversationID: selectedConversation?.id
        )
        deskMessages = cached
        if !cached.isEmpty {
            storeCachedMessages(
                cached,
                botID: cachedBot.id,
                conversationID: selectedConversation?.id
            )
        }
        if deskMessages.isEmpty {
            destDeskChatFromTitleIfNeeded(
                botID: cachedBot.id,
                cached: cached,
                conversation: selectedConversation
            )
        }
        deskWorkLog = []
        if let threadID = selectedConversation?.linkedAgentThreadID {
            deskLiveTimeline = liveTimelineByThread[threadID] ?? AssistantTimelineState()
            deskStreamEventCount = liveStreamCountByThread[threadID] ?? 0
        } else {
            deskLiveTimeline = AssistantTimelineState()
            deskStreamEventCount = 0
        }
        syncQueuedFollowUps()
        lastGuestScreenURL = guestScreenURLByBot[cachedBot.id.value]
    }

    private enum NavigationFreshnessOperation {
        case reload
        case activeBots
        case desk(botID: BotID, reloadFirst: Bool)
        case thread(botID: BotID, conversationID: BotConversationID)
    }

    private func scheduleNavigationFreshness(_ operation: NavigationFreshnessOperation) {
        navigationFreshnessGeneration &+= 1
        let generation = navigationFreshnessGeneration
        navigationFreshnessTask?.cancel()
        navigationFreshnessTask = Task { @MainActor [weak self] in
            await Self.waitForCommittedFrame()
            guard let self else { return }
            defer {
                // A cancelled task may resume after its replacement has been
                // installed. Only the owner generation may clear the handle.
                if self.navigationFreshnessGeneration == generation {
                    self.navigationFreshnessTask = nil
                }
            }
            guard self.navigationFreshnessIsCurrent(generation) else { return }
            switch operation {
            case .reload:
                self.reload()
            case .activeBots:
                guard self.screen.resolvedDestination == .activeBots else { return }
                self.reloadActiveBotsScreen()
            case .desk(let botID, let reloadFirst):
                self.performDeskFreshness(
                    botID: botID,
                    reloadFirst: reloadFirst,
                    generation: generation
                )
            case .thread(let botID, let conversationID):
                self.performThreadFreshness(
                    botID: botID,
                    conversationID: conversationID,
                    generation: generation
                )
            }
        }
    }

    private func invalidateNavigationFreshness() {
        navigationFreshnessGeneration &+= 1
        navigationFreshnessTask?.cancel()
        navigationFreshnessTask = nil
    }

    /// Next main-queue turn after the current CATransaction. `Task.yield()`
    /// is only an executor hop and can still run before SwiftUI paints.
    private static func waitForCommittedFrame() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    private func navigationFreshnessIsCurrent(
        _ generation: UInt64,
        botID: BotID? = nil,
        conversationID: BotConversationID? = nil
    ) -> Bool {
        guard !Task.isCancelled,
              navigationFreshnessGeneration == generation else { return false }
        if let botID {
            guard selectedBotID == botID,
                  screen.resolvedDestination == .desk else { return false }
        }
        if let conversationID {
            guard selectedConversation?.id == conversationID else { return false }
        }
        return true
    }

    private func performDeskFreshness(
        botID: BotID,
        reloadFirst: Bool,
        generation: UInt64
    ) {
        guard navigationFreshnessIsCurrent(generation, botID: botID) else { return }
        if reloadFirst {
            reload()
            guard navigationFreshnessIsCurrent(generation, botID: botID) else {
                // `reload` may find that the exact target was deleted. Never
                // leave this detached window pointing at a fallback teammate.
                if navigationFreshnessGeneration == generation {
                    adoptSelectedBot(botID)
                    screen = .desk
                }
                return
            }
        }
        guard let storedBot = try? botStore.get(id: botID),
              storedBot.deletedAt == nil else { return }
        adoptSelectedBot(botID)
        screen = .desk
        persistSelection()
        guard navigationFreshnessIsCurrent(generation, botID: botID) else { return }
        markOpenedConversationRead(botID: botID)
        guard navigationFreshnessIsCurrent(generation, botID: botID) else { return }
        _ = refreshPublishedIdentity(for: botID)
        guard navigationFreshnessIsCurrent(generation, botID: botID) else { return }
        reloadSelectedBot(id: botID)
        guard navigationFreshnessIsCurrent(generation, botID: botID) else { return }
        syncQueuedFollowUps()
        drainQueuedFollowUp()
        guard navigationFreshnessIsCurrent(generation, botID: botID) else { return }
        deskTimelineRejoinToken &+= 1
        lastGuestScreenURL = guestScreenURLByBot[botID.value]
        if displayedDesktopKind == .dockerDesktop {
            presentGuestDesktop(botID: botID)
        }
    }

    @discardableResult
    public func createDeskThread() -> Bool {
        guard let bot = selectedBot else { return false }
        if !isDeskThreadRailVisible {
            isDeskThreadRailVisible = true
        }
        let conversation = BotConversation(botID: bot.id, title: "New thread")
        do {
            try botStore.upsertConversation(conversation)
        } catch {
            errorMessage = String(describing: error)
            return false
        }
        conversations.removeAll { $0.id == conversation.id }
        conversations.insert(conversation, at: 0)
        deskRoutingByConversation[conversation.id] = deskRouting
        persistDeskRouting()
        selectDeskThread(conversation.id)
        return true
    }

    public var filteredDeskConversations: [BotConversation] {
        let matching = conversations.filter {
            AgentChatThreadRailCopy.matches(title: $0.title, query: deskThreadSearchQuery)
        }
        let live = liveDeskThreadIDs()
        return AgentChatThreadRailCopy.orderingActiveFirst(matching) {
            isDeskConversationRunning($0, liveThreadIDs: live)
        }
    }

    public var deskThreadActiveCount: Int {
        let live = liveDeskThreadIDs()
        return conversations.filter { isDeskConversationRunning($0, liveThreadIDs: live) }.count
    }

    public func isDeskConversationRunning(_ conversation: BotConversation) -> Bool {
        isDeskConversationRunning(conversation, liveThreadIDs: liveDeskThreadIDs())
    }

    /// BT-25: the rail takes ONE snapshot per pass and hands it to every row.
    /// `activeThreadIdsSnapshot()` takes the coordinator's global lock (shared
    /// with the streaming thread) and allocates a Set — per row per token before.
    public func liveDeskThreadIDsSnapshot() -> Set<AgentThreadID> {
        liveDeskThreadIDs()
    }

    private func liveDeskThreadIDs() -> Set<AgentThreadID> {
        Set(activeThreadIDsOverrideForTesting ?? context.coordinator.activeThreadIdsSnapshot())
    }

    public func isDeskConversationRunning(
        _ conversation: BotConversation,
        liveThreadIDs: Set<AgentThreadID>
    ) -> Bool {
        if conversation.attentionState == .working { return true }
        guard let threadID = conversation.linkedAgentThreadID else { return false }
        return liveThreadIDs.contains(threadID)
    }

    public func clearAllDeskThreads() {
        guard let bot = selectedBot else { return }
        for threadID in conversations.compactMap(\.linkedAgentThreadID) {
            clearDeskObservedEvents(threadID: threadID)
            settledTerminalRunIDByThread[threadID] = nil
        }
        let handoffDeletion = context.botPeerHandoffAuthority.beginDeletion(originBotID: bot.id)
        if deskRunIsLive {
            stopDeskRun()
        }
        do {
            try botStore.deleteConversations(botID: bot.id)
        } catch {
            context.botPeerHandoffAuthority.rollbackDeletion(handoffDeletion)
            errorMessage = String(describing: error)
            return
        }
        _ = context.botPeerHandoffAuthority.commitDeletion(handoffDeletion)
        for conversation in conversations {
            deskRoutingByConversation[conversation.id] = nil
        }
        persistDeskRouting()
        for conversation in conversations {
            messagesByConversation[conversation.id] = nil
        }
        conversations = []
        selectedConversation = nil
        selectedConversationByBot[bot.id] = nil
        lastStartedConversationByBot[bot.id] = nil
        messagesByBot[bot.id] = []
        messagesConversationIDByBot[bot.id] = nil
        deskMessages = []
        resetTokenSaverFooterSnapshot()
        tokenSaverOriginalDisplayMessageIds = []
        deskThreadSearchQuery = ""
        attentionItems.removeAll {
            $0.botID == bot.id && $0.conversationID != nil
        }
        rememberStudioSupport(for: bot.id)
        applyAttentionState(for: bot.id, conversations: [])
        Self.publishDestAttentionChanged()
        deskTimelineRejoinToken &+= 1
    }

    public func selectDeskThread(_ id: BotConversationID) {
        guard let conversation = conversations.first(where: { $0.id == id }) else { return }
        captureDeskRouting()
        resetTokenSaverFooterSnapshot()
        selectedConversation = conversation
        publishInterestedDeskThreadID()
        selectedConversationByBot[conversation.botID] = conversation.id
        applyDeskRouting(
            for: conversation,
            allowStoreLookup: !navigationFirstFrameDeferral
        )
        rememberStudioSupport(for: conversation.botID)
        let cached = cachedMessages(
            botID: conversation.botID,
            conversationID: conversation.id
        )
        deskMessages = cached
        if !cached.isEmpty {
            storeCachedMessages(
                cached,
                botID: conversation.botID,
                conversationID: conversation.id
            )
        }
        if deskMessages.isEmpty {
            destDeskChatFromTitleIfNeeded(
                botID: conversation.botID,
                cached: cached,
                conversation: conversation
            )
        }
        deskWorkLog = []
        if let threadID = conversation.linkedAgentThreadID {
            deskLiveTimeline = liveTimelineByThread[threadID] ?? AssistantTimelineState()
        } else {
            deskLiveTimeline = AssistantTimelineState()
        }
        guard !navigationFirstFrameDeferral else {
            deskTimelineRejoinToken &+= 1
            scheduleNavigationFreshness(
                .thread(botID: conversation.botID, conversationID: conversation.id)
            )
            return
        }
        if cached.isEmpty {
            restoreDeskMessages(botID: conversation.botID)
        }
        restoreDeskWorkLog(botID: conversation.botID)
        restoreDeskLiveTurn(botID: conversation.botID)
        reloadTokenSaverThreadSavings()
        deskTimelineRejoinToken &+= 1
    }

    private func publishInterestedDeskThreadID() {
        var next = screen.resolvedDestination == .desk
            ? selectedConversation?.linkedAgentThreadID
            : nil
        // The embedded Agent App paints this thread; a second desk paint pipeline
        // would republish this view model on every token.
        if let threadID = next, deskAgentOwnsLiveStream(threadID: threadID) { next = nil }
        if interestedDeskThread.get() != next { deskStreamAggregateBudgetOps = 0 }
        interestedDeskThread.set(next)
    }

    private func deskAgentOwnsLiveStream(threadID: AgentThreadID) -> Bool {
        deskAgentVM != nil && deskAgentKey?.threadID == threadID
    }

    nonisolated private func currentInterestedDeskThreadID() -> AgentThreadID? {
        interestedDeskThread.get()
    }

    private func performThreadFreshness(
        botID: BotID,
        conversationID: BotConversationID,
        generation: UInt64
    ) {
        guard navigationFreshnessIsCurrent(
            generation,
            botID: botID,
            conversationID: conversationID
        ) else { return }
        if cachedMessages(botID: botID, conversationID: conversationID).isEmpty {
            restoreDeskMessages(botID: botID)
        }
        guard navigationFreshnessIsCurrent(
            generation,
            botID: botID,
            conversationID: conversationID
        ) else { return }
        restoreDeskWorkLog(botID: botID)
        restoreDeskLiveTurn(botID: botID)
        reloadTokenSaverThreadSavings()
        guard navigationFreshnessIsCurrent(
            generation,
            botID: botID,
            conversationID: conversationID
        ) else { return }
        deskTimelineRejoinToken &+= 1
    }

    public func openInNewWindow(_ bot: BotDefinition) {
        guard !presentsAsDetachedWindow else { return }
        router?.openBotInNewWindow(bot.id)
    }

    public func openGuestDesktopInNewWindow(_ bot: BotDefinition) {
        router?.openBotGuestDesktopInNewWindow(bot.id)
    }

    private func markOpenedConversationRead(botID: BotID) {
        if let snapshot = studioSupportByBot[botID],
           !Self.conversationsNeedMarkRead(snapshot.conversations),
           !attentionItems.contains(where: {
               $0.botID == botID && $0.acknowledgedAt == nil && $0.kind == .unread
           }) {
            applyAttentionState(for: botID, conversations: snapshot.conversations)
            return
        }
        deskMarkReadStoreCountForTesting += 1
        do {
            // Dest first. Mark-read dest used to listConversations and
            // listAttention after dest already dested Chat. Dest cache
            // already has this teammate's threads and dest inbox.
            var items = destConversations(botID: botID)
            if items.isEmpty {
                conversationListCountForTesting += 1
                items = try botStore.listConversations(botID: botID)
            }
            for index in items.indices where items[index].unread || items[index].attentionState == .unreadActivity {
                items[index].unread = false
                if items[index].attentionState == .unreadActivity {
                    items[index].attentionState = .none
                }
                try botStore.upsertConversation(items[index])
            }
            let destUnread = attentionItems.filter {
                $0.botID == botID && $0.acknowledgedAt == nil && $0.kind == .unread
            }
            for item in destUnread {
                try botStore.acknowledgeAttention(id: item.id)
                dropAcknowledgedAttention(item.id)
            }
            applyAttentionState(for: botID, conversations: items)
            rememberStudioSupportConversations(botID: botID, conversations: items)
            Self.publishDestAttentionChanged()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private static func conversationsNeedMarkRead(_ conversations: [BotConversation]) -> Bool {
        conversations.contains { $0.unread || $0.attentionState == .unreadActivity }
    }

    private func rememberStudioSupportConversations(botID: BotID, conversations: [BotConversation]) {
        guard var snapshot = studioSupportByBot[botID] else { return }
        snapshot.conversations = conversations
        if let selected = snapshot.selectedConversation,
           let updated = conversations.first(where: { $0.id == selected.id }) {
            snapshot.selectedConversation = updated
        } else {
            snapshot.selectedConversation = conversations.first
        }
        studioSupportByBot[botID] = snapshot
    }

    private func patchStudioSupportConversation(_ conversation: BotConversation, botID: BotID) {
        guard var snapshot = studioSupportByBot[botID] else { return }
        if let index = snapshot.conversations.firstIndex(where: { $0.id == conversation.id }) {
            snapshot.conversations[index] = conversation
        } else {
            snapshot.conversations.insert(conversation, at: 0)
        }
        if snapshot.selectedConversation?.id == conversation.id {
            snapshot.selectedConversation = conversation
        }
        studioSupportByBot[botID] = snapshot
    }

    public func openAttention() {
        // Dest first. Bell dest used to listAttention (and then list
        // every teammate's conversations) before dest dested Chat.
        // Dest already has dest inbox from send/settle dest.
        if let item = destOpenAttentionItem() {
            openAttention(item)
            return
        }
        reloadAttention()
        guard let item = attentionItems.first else {
            // Home/Attention is not a dest. An empty bell must not
            // yank Studio back to Chat.
            return
        }
        openAttention(item)
    }

    /// Bell dest dests dest inbox. Cold dest still lists.
    private func destOpenAttentionItem() -> BotAttentionItem? {
        attentionItems.first(where: { $0.acknowledgedAt == nil })
    }

    public func openAttention(_ item: BotAttentionItem) {
        // Dest first. Attention used to acknowledge and list the queue
        // before Chat could paint, so first feedback waited on store writes.
        if let bot = bots.first(where: { $0.id == item.botID }) {
            openDesk(bot)
        } else if let bot = try? botStore.get(id: item.botID) {
            openDesk(bot)
        } else {
            screen = .desk
        }
        lastAttentionAcknowledgedOnScreenForTesting = screen
        do {
            // Dest first. Acknowledge used to listAttention after dest
            // painted Chat. The store already marked this row read.
            try botStore.acknowledgeAttention(id: item.id)
            dropAcknowledgedAttention(item.id)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func acknowledge(_ item: BotAttentionItem) {
        do {
            // Dest first. Acknowledge used to listAttention after the
            // store marked this row read. Drop it locally.
            try botStore.acknowledgeAttention(id: item.id)
            dropAcknowledgedAttention(item.id)
            Self.publishDestAttentionChanged()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    @discardableResult
    public func create(
        name: String,
        title: String = "",
        description: String = "",
        handle: String? = nil,
        soul: String = "",
        avatarSymbol: String = "person.crop.circle",
        notificationsEnabled: Bool = true,
        desktopKind: BotDesktopKind = .logicalExecutionSpace
    ) throws -> BotDefinition {
        guard isControlPlaneActive else {
            errorMessage = "Turn on Bot control plane in Settings"
            throw BotPublishError.controlPlaneDisabled
        }
        let bot = try botStore.create(
            name: name,
            title: title,
            description: description,
            handle: handle,
            avatarSymbol: avatarSymbol,
            soul: soul,
            desktopKind: resolvedDesktopKind(desktopKind),
            workspaceID: context.state.window.selectedWorkspaceID,
            notificationsEnabled: notificationsEnabled
        )
        // Dest first. Create used to reloadFleet (every teammate's
        // conversations + recent messages) before Chat could paint.
        adoptCreatedBot(bot)
        ensureBotHome(bot)
        return bot
    }

    @available(*, deprecated, message: "Provider routing belongs to the calling AgentThread.")
    @discardableResult
    public func create(
        name: String,
        title: String = "",
        description: String = "",
        handle: String? = nil,
        soul: String = "",
        provider _: AgentProvider,
        providerInstanceID _: String? = nil,
        model _: String = "",
        avatarSymbol: String = "person.crop.circle",
        notificationsEnabled: Bool = true,
        desktopKind: BotDesktopKind = .logicalExecutionSpace
    ) throws -> BotDefinition {
        try create(
            name: name,
            title: title,
            description: description,
            handle: handle,
            soul: soul,
            avatarSymbol: avatarSymbol,
            notificationsEnabled: notificationsEnabled,
            desktopKind: desktopKind
        )
    }

    /// Keep a message already set by saveStudio/send; otherwise use LocalizedError copy.
    public func presentAlertError(_ error: Error) {
        guard errorMessage == nil else { return }
        errorMessage = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    @discardableResult
    public func saveStudio() throws -> BotDefinition {
        defer { flushPendingDraftPersistence() }
        let name = studioDraft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            errorMessage = "Name is required."
            throw BotPublishError.invalidRevision
        }
        let handle = studioDraft.handle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !handle.isEmpty, BotHandle.normalize(handle) == nil {
            errorMessage = "Slug is empty or invalid."
            throw BotPublishError.handleEmpty
        }
        let publishedDesktop = selectedRevision?.desktopKind
        if studioDraft.desktopKind == .dockerDesktop,
           publishedDesktop != .dockerDesktop,
           !BotDesktopKind.dockerDesktop.isSelectable(
            flags: settingsStore.load().botControlPlaneFlags,
            guestReady: dockerGuestReady
           ) {
            errorMessage = "Docker desktop is not ready."
            throw BotComputerGuestError.notReady
        }
        let desktop = resolvedDesktopKind(studioDraft.desktopKind)
        let startsDockerGuest = desktop == .dockerDesktop
            && publishedDesktop != .dockerDesktop
        let soul = BotStandingInstructions.resolved(
            name: name,
            title: studioDraft.title,
            description: studioDraft.description,
            soul: studioDraft.soul
        )
        studioDraft.soul = soul
        if let botID = studioDraft.botID {
            guard let bot = try botStore.get(id: botID), bot.deletedAt == nil else {
                throw BotStoreError.notFound
            }
            let renamed: BotDefinition
            if let normalized = BotHandle.normalize(handle), normalized != bot.handle {
                do {
                    renamed = try botStore.renameHandle(id: botID, handle: normalized)
                } catch {
                    errorMessage = (error as? CustomStringConvertible)?.description ?? String(describing: error)
                    throw error
                }
            } else {
                renamed = bot
            }
            let draft = BotRevisionDraft(
                name: name,
                title: studioDraft.title,
                description: studioDraft.description,
                soul: soul,
                permissionMode: .supervised,
                desktopKind: desktop
            )
            let published = try botStore.publish(
                botID: botID,
                expectedCurrentRevisionID: studioDraft.expectedRevisionID ?? renamed.currentRevisionID,
                draft: draft,
                avatarSymbol: studioDraft.avatarSymbol,
                notificationsEnabled: studioDraft.notificationsEnabled
            )
            studioDraft.expectedRevisionID = published.id
            studioDraft.desktopKind = desktop
            // Dest first. Save used to force-reload studio support
            // (conversations, skills, memory, routines, receipt) after
            // publish already returned this revision. Patch the row
            // and the revision locally so dest does not reread inspector.
            var saved = renamed
            saved.name = published.name
            saved.title = published.title
            saved.description = published.description
            saved.avatarSymbol = studioDraft.avatarSymbol
            saved.notificationsEnabled = studioDraft.notificationsEnabled
            saved.currentRevisionID = published.id
            saved.updatedAt = Date()
            adoptPublishedRevision(published, bot: saved)
            syncPublishedHome(saved, revision: published)
            clearUnpublishedNewBot(botID)
            if startsDockerGuest {
                presentGuestDesktop(botID: botID)
            }
            screen = .studio
            return saved
        }
        let created = try create(
            name: name,
            title: studioDraft.title,
            description: studioDraft.description,
            handle: handle.isEmpty ? nil : handle,
            soul: soul,
            avatarSymbol: studioDraft.avatarSymbol,
            notificationsEnabled: studioDraft.notificationsEnabled,
            desktopKind: desktop
        )
        if desktop == .dockerDesktop {
            presentGuestDesktop(botID: created.id)
        }
        beginEdit(created)
        clearUnpublishedNewBot(created.id)
        return created
    }

    @discardableResult
    public func duplicate(id: BotID) throws -> BotDefinition {
        guard isControlPlaneActive else {
            errorMessage = "Turn on Bot control plane in Settings"
            throw BotPublishError.controlPlaneDisabled
        }
        let copy = try botStore.duplicate(id: id)
        // Dest first. Copy used to reloadFleet before Chat/Studio could
        // paint. The store already returned the new row.
        adoptCreatedBot(copy)
        return copy
    }

    public func setPinned(id: BotID, pinned: Bool) {
        do {
            try botStore.setPinned(id: id, pinned: pinned)
            // Dest first. Pin used to reloadFleet (every teammate's
            // conversations + recent messages) before the roster could
            // resort. The store already wrote this row.
            if var bot = bots.first(where: { $0.id == id }) {
                bot.pinned = pinned
                rememberFleetBot(bot)
            } else {
                reloadFleet()
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func setHidden(id: BotID, hidden: Bool) {
        do {
            try botStore.setHidden(id: id, hidden: hidden)
            let leaving = hidden && selectedBotID == id
            // Dest first. Hide used to reloadFleet (every teammate's
            // conversations + recent messages) before the roster could
            // drop the row. The store already wrote this row.
            applyHiddenLocally(id: id, hidden: hidden)
            if leaving {
                adoptRemainingTeammate(afterRemoving: id)
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func applyShowHiddenLocally() {
        if !showHidden {
            bots.removeAll { $0.hidden }
            return
        }
        do {
            bots = try botStore.list(includeHidden: true)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func applyHiddenLocally(id: BotID, hidden: Bool) {
        if hidden, !showHidden {
            bots.removeAll { $0.id == id }
            return
        }
        if var bot = bots.first(where: { $0.id == id }) {
            bot.hidden = hidden
            rememberFleetBot(bot)
            return
        }
        reloadFleet()
    }

    public func duplicateFromRoster(_ bot: BotDefinition) {
        do {
            let copy = try duplicate(id: bot.id)
            if screen == .studio {
                beginEdit(copy)
            } else {
                openDesk(copy)
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func delete(id: BotID, navigate: Bool = true) {
        do {
            try botSecretStore.deleteAll(botID: id)
            try botStore.delete(id: id)
            if let service = computerGuestService {
                Task.detached { [service] in
                    service.teardown(botID: id)
                }
            }
            let leaving = selectedBotID == id
            unpublishedNewBotIDs.remove(id)
            persistUnpublishedNewBotIDs()
            queuedFollowUpsByBot[id] = nil
            composerDraftsByBot[id] = nil
            inspectorDraftsByBot[id] = nil
            studioDraftsByBot[id] = nil
            studioFilesLocationsByBot[id] = nil
            draftPersistenceAuthority.removeDrafts(for: id)
            clearDeskSendInFlight(for: id)
            persistQueuedFollowUps()
            flushPendingDraftPersistence()
            persistStudioFilesLocations()
            syncQueuedFollowUps()
            forgetResidentCaches(for: id, leaving: leaving)
            // Dest first. Delete used to reloadFleet (every teammate's
            // conversations + recent messages) before Chat could dest the
            // next row, then listAttention after dest already dested.
            // The store already removed this teammate; dest inbox is
            // already dropped locally.
            bots.removeAll { $0.id == id }
            attentionItems.removeAll { $0.botID == id }
            if leaving, navigate {
                adoptRemainingTeammate(afterRemoving: id)
            } else if leaving {
                adoptSelectedBot(nil)
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// Resident caches keyed to a teammate otherwise outlive its row for the
    /// life of the window: the studio snapshot (conversations, memory facts,
    /// routines, the selected revision), every published revision, the desk
    /// previews, and each per-conversation transcript plus its per-thread
    /// probes. Deleting a teammate must drop its share of them so the window's
    /// footprint follows the live roster instead of every row it ever showed.
    ///
    /// `deskRoutingByConversation` is deliberately not pruned: it is persisted
    /// state, not a resident cache, so dropping it without a write would only
    /// resurrect the same keys at the next `restoreDeskRoutingIfNeeded`, and
    /// writing here would add a synchronous encode to the delete path that must
    /// stay dest-first (see `test_deleteRunsDockerTeardownOffMain_becauseAStuckDaemonMustNotFreezeTheRoster`).
    private func forgetResidentCaches(for id: BotID, leaving: Bool) {
        var conversationIDs = Set<BotConversationID>()
        var threadIDs = Set<AgentThreadID>()
        func collect(_ rows: [BotConversation]) {
            for row in rows {
                conversationIDs.insert(row.id)
                if let threadID = row.linkedAgentThreadID { threadIDs.insert(threadID) }
            }
        }
        // Only the two cached lists still hold this teammate's conversations:
        // its studio snapshot, and `conversations` when it is the open desk.
        if let cached = studioSupportByBot[id] { collect(cached.conversations) }
        if leaving { collect(conversations) }
        if let selected = selectedConversationByBot[id] { conversationIDs.insert(selected) }
        if let last = messagesConversationIDByBot[id] { conversationIDs.insert(last) }

        studioSupportByBot[id] = nil
        attentionStateByBot[id] = nil
        lastPreviewByBot[id] = nil
        lastUpdatedByBot[id] = nil
        lastLinkedRunIDByBot[id] = nil
        lastStartedConversationByBot[id] = nil
        selectedConversationByBot[id] = nil
        messagesByBot[id] = nil
        messagesConversationIDByBot[id] = nil
        revisionByID = revisionByID.filter { $0.value.botID != id }
        for conversationID in conversationIDs {
            messagesByConversation[conversationID] = nil
        }
        for threadID in threadIDs {
            clearDeskObservedEvents(threadID: threadID)
            settledTerminalRunIDByThread[threadID] = nil
        }
    }

    /// Hide/Delete of the open teammate must not dump Chat on empty desk
    /// while the roster still has rows. Home is gone; pick the next visible
    /// teammate. Stay put only when Show hidden still lists the same row.
    private func adoptRemainingTeammate(afterRemoving removedID: BotID) {
        if fleet.contains(where: { $0.id == removedID }) {
            if let bot = fleet.first(where: { $0.id == removedID }) {
                openDesk(bot)
            }
            return
        }
        if let next = fleet.first {
            openDesk(next)
            return
        }
        adoptSelectedBot(nil)
        screen = .desk
        persistSelection()
    }

    public var deskRunIsLive: Bool {
        deskWorkLog.contains { $0.statusLabel == "Working" }
    }

    public var deskShowsLoading: Bool {
        guard deskSendInFlight, !deskRunIsLive else { return false }
        guard !deskMessages.contains(where: { $0.peer?.activityPhase == .waiting }) else {
            return false
        }
        return deskSendInFlightBotID == nil || deskSendInFlightBotID == selectedBotID
    }

    public var deskSendEnabled: Bool {
        AgentChatTranscriptChrome.admitsSend(text: composerText, attachmentCount: attachments.count)
    }

    public func deskWorkingStartedAt() -> Date? {
        if let started = deskWorkLog.first(where: { $0.statusLabel == "Working" })?.createdAt {
            return started
        }
        if let turn = deskLiveTimeline.turns.last(where: { !$0.finished }) {
            return AgentChatLiveTurnChrome.turnSortDate(turn)
        }
        return nil
    }

    public func deskWorkingLabel(now: Date = Date()) -> String? {
        AgentChatTranscriptChrome.deskWorkingLabel(
            runIsLive: deskRunIsLive,
            startedAt: deskWorkingStartedAt(),
            hasStreamingTools: deskHasStreamingTools,
            now: now
        )
    }

    public var deskWorkingContext: AgentChatWorkingContext? {
        guard deskRunIsLive, let bot = selectedBot else { return nil }
        if let replyIndex = deskMessages.lastIndex(where: {
            $0.peer?.direction == .fromPeer
        }), let peer = deskMessages[replyIndex].peer,
           !deskMessages[deskMessages.index(after: replyIndex)...].contains(where: {
               $0.role == .user
           }) {
            return .reviewing(peerName: peer.name)
        }
        return .agent(name: bot.name)
    }

    /// Test seam (BT-23/BT-28): one watch tick for the selected desk thread,
    /// without the 2 s cadence or the push-quiet gate. Returns true when the
    /// watched run is terminal, i.e. when the watch stops.
    @discardableResult
    func deskLiveTurnWatchTickForTesting() async -> Bool {
        guard let botID = selectedBotID,
              let threadID = selectedConversation?.linkedAgentThreadID else { return false }
        return await deskLiveTurnWatchTick(botID: botID, threadID: threadID)
    }

    public func refreshDeskLiveTurn() {
        guard let id = selectedBotID else { return }
        restoreDeskLiveTurn(botID: id)
    }

    func applyDeskLiveEventForTesting(_ event: AssistantEvent, threadId: AgentThreadID) {
        applyIncomingDeskEvent(event, threadId: threadId)
    }

    func applyDeskLiveEventForTesting(
        _ event: AssistantEvent,
        runId: AgentRunID,
        threadId: AgentThreadID
    ) {
        applyIncomingDeskEvent(event, runId: runId, threadId: threadId)
    }

    func deskLiveObservedEventBufferForTesting(
        threadId: AgentThreadID
    ) -> (count: Int, bytes: Int, totalBytes: Int, overflowed: Bool) {
        (
            liveObservedEventsByThread[threadId]?.count ?? 0,
            liveObservedEventBytesByThread[threadId] ?? 0,
            liveObservedEventBytesTotal,
            liveObservedEventOverflowThreads.contains(threadId)
        )
    }

    public func addAttachments(_ paths: [String]) {
        do {
            let staged = try attachmentStore().stage(paths: paths)
            var known = Set(attachments.map(\.path))
            for attachment in staged where known.insert(attachment.path).inserted {
                attachments.append(attachment)
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func removeAttachment(_ attachment: AgentAttachment) {
        attachments.removeAll { $0 == attachment }
    }

    /// Dropping files/folders on the Desk composer inserts their paths into
    /// the prompt text — same behavior as Agent App's composer.
    public func insertDroppedFilePaths(_ paths: [String]) {
        let insertion = DroppedFilePaths.composerInputText(for: paths)
        composerText = DroppedFilePaths.appending(insertion, to: composerText)
    }

    public func removeQueuedFollowUp(_ item: BotQueuedFollowUp) {
        guard let botID = selectedBotID else { return }
        queuedFollowUpsByBot[botID]?.removeAll { $0.id == item.id }
        if queuedFollowUpsByBot[botID]?.isEmpty == true {
            queuedFollowUpsByBot[botID] = nil
        }
        persistQueuedFollowUps()
        syncQueuedFollowUps()
    }

    public func hasLiveRun(botID: BotID) -> Bool {
        do {
            return try liveThreadIDs(for: botID).isEmpty == false
        } catch {
            return true
        }
    }

    public func stopLiveRuns(for botID: BotID, force: Bool, onSettled: ((Bool) -> Void)? = nil) {
        if let existing = deskStopJoins[botID] {
            Task { @MainActor in
                let ok = await existing.task.value
                onSettled?(ok)
            }
            return
        }
        let join = DeskStopJoin()
        deskStopJoinStartCountForTesting += 1
        deskStopJoins[botID] = join
        deskStopEpoch[botID, default: 0] += 1
        if force {
            isStopping = true
        }
        let sendWorks = takeDeskSendWorks(for: botID)
        sendWorks.forEach { work in
            work.task.cancel()
            if let threadID = work.threadID {
                context.coordinator.stopRun(threadId: threadID)
                deskStopRunIssuedCountForTesting += 1
            }
        }
        join.task = Task { @MainActor [weak self] in
            guard let self else { return false }
            var discoveryError: Error?
            var threadIDs: [AgentThreadID] = []
            do {
                threadIDs = try self.liveThreadIDs(for: botID)
            } catch {
                discoveryError = error
            }
            if discoveryError == nil {
                for threadID in threadIDs {
                    self.context.coordinator.stopRun(threadId: threadID)
                }
            }
            var seen = Set<AgentThreadID>()
            seen.reserveCapacity(sendWorks.count + threadIDs.count)
            var toStop: [AgentThreadID] = []
            toStop.reserveCapacity(sendWorks.count + threadIDs.count)
            for work in sendWorks {
                if let threadID = work.threadID, seen.insert(threadID).inserted {
                    toStop.append(threadID)
                }
            }
            for threadID in threadIDs where seen.insert(threadID).inserted {
                toStop.append(threadID)
            }
            let coordinator = self.context.coordinator
            let termination = Task {
                if !toStop.isEmpty {
                    try await coordinator.stopAndAwaitTermination(threadIds: toStop)
                }
            }
            for work in sendWorks {
                await work.task.value
            }
            defer {
                if self.deskStopJoins[botID] === join {
                    self.deskStopJoins[botID] = nil
                }
                self.isStopping = false
            }
            if discoveryError != nil {
                _ = await termination.result
                return false
            }
            do {
                try await termination.value
                return try self.liveThreadIDs(for: botID, includeInFlightSends: false).isEmpty
            } catch {
                self.errorMessage = force
                    ? "Force stop: \(error.localizedDescription)"
                    : String(describing: error)
                return false
            }
        }
        Task { @MainActor [weak self] in
            let ok = await join.task.value
            onSettled?(ok)
        }
    }

    /// Paired v1 stop is bound to the exact admitted conversation/run. A
    /// delayed request must fail instead of discovering and stopping whatever
    /// run happens to be active for the Bot when it arrives.
    public func stopLiveRun(
        for botID: BotID,
        conversationID: String?,
        runID: String?,
        runRequestID: String?,
        force: Bool,
        onSettled: ((Bool) -> Void)? = nil
    ) {
        if conversationID == nil, runID == nil, runRequestID == nil {
            stopLiveRuns(for: botID, force: force, onSettled: onSettled)
            return
        }
        guard let conversationID,
              let conversationUUID = UUID(uuidString: conversationID),
              let runID,
              let runUUID = UUID(uuidString: runID),
              let conversation = try? botStore.conversation(
                id: BotConversationID(conversationUUID)
              ),
              conversation.botID == botID,
              let threadID = conversation.linkedAgentThreadID else {
            onSettled?(false)
            return
        }
        let targetRunID = AgentRunID(runUUID)
        let matchingWorks = (deskSendTasks[botID] ?? []).filter {
            $0.threadID == threadID && $0.runID == targetRunID
        }
        let activeRunMatches = context.coordinator.activeRunId(threadId: threadID) == targetRunID
        guard activeRunMatches || !matchingWorks.isEmpty else {
            onSettled?(false)
            return
        }
        matchingWorks.forEach { $0.task.cancel() }
        context.coordinator.stopRun(threadId: threadID)
        deskStopRunIssuedCountForTesting += 1
        Task { @MainActor [weak self] in
            guard let self else { return }
            for work in matchingWorks {
                await work.task.value
                self.forgetDeskSend(work, botID: botID)
            }
            self.clearDeskSendInFlight(for: botID)
            do {
                try await self.context.coordinator.stopAndAwaitTermination(threadId: threadID)
                onSettled?(self.context.coordinator.activeRunId(threadId: threadID) != targetRunID)
            } catch {
                self.errorMessage = force
                    ? "Force stop: \(error.localizedDescription)"
                    : String(describing: error)
                onSettled?(false)
            }
            _ = runRequestID // receipt identity is validated by the authority.
        }
    }

    private func liveThreadIDs(for botID: BotID, includeInFlightSends: Bool = true) throws -> [AgentThreadID] {
        if let error = liveThreadDiscoveryErrorForTesting {
            throw error
        }
        var ids: [AgentThreadID] = []
        let inFlight = includeInFlightSends && deskSendInFlightBotID == botID
        for conversation in try botStore.listConversations(botID: botID) {
            guard let threadID = conversation.linkedAgentThreadID else { continue }
            if inFlight {
                ids.append(threadID)
                continue
            }
            if context.coordinator.activeRunId(threadId: threadID) != nil {
                ids.append(threadID)
                continue
            }
            if context.coordinator.hasPendingProviderStart(threadId: threadID) {
                ids.append(threadID)
                continue
            }
            if context.coordinator.hasProviderSession(threadId: threadID) {
                ids.append(threadID)
                continue
            }
            if context.coordinator.isPreparingProviderStart(threadId: threadID) {
                ids.append(threadID)
                continue
            }
            if try context.coordinator.hasDurableActiveRun(threadId: threadID) {
                ids.append(threadID)
            }
        }
        return ids
    }

    public func reloadQueuedFollowUpsFromStore() {
        queuedFollowUpsByBot = decodeQueuedFollowUpsFromStore()
        syncQueuedFollowUps()
    }

    /// Promote an exact persisted remote queue row and either interrupt its
    /// current conversation or start it immediately when that conversation is
    /// idle. The authority has already moved the row to the front transactionally.
    public func forceQueuedFollowUpFromStore(botID: BotID, id: String) throws -> [String: Any] {
        reloadQueuedFollowUpsFromStore()
        guard let itemID = UUID(uuidString: id),
              let bot = try botStore.get(id: botID), bot.deletedAt == nil,
              let item = queuedFollowUpsByBot[botID]?.first,
              item.id == itemID,
              let conversationID = item.conversationID,
              let conversation = try botStore.conversation(id: conversationID),
              conversation.botID == botID,
              let threadID = conversation.linkedAgentThreadID else {
            throw BotStoreError.invalidRow("queued follow-up authority is stale")
        }
        if try liveThreadIDs(for: botID).contains(threadID) {
            stopDeskThread(conversationID)
            return [
                "force_status": "queued",
                "conversation_id": conversationID.value.uuidString.lowercased(),
                "thread_id": threadID.value.uuidString.lowercased(),
            ]
        }
        drainHostQueuedFollowUp(bot: bot, conversation: conversation)
        guard queuedFollowUpsByBot[botID]?.contains(where: { $0.id == itemID }) != true,
              let runID = context.coordinator.activeRunId(threadId: threadID) else {
            throw BotStoreError.invalidRow("queued follow-up did not start")
        }
        return [
            "force_status": "started",
            "conversation_id": conversationID.value.uuidString.lowercased(),
            "thread_id": threadID.value.uuidString.lowercased(),
            "run_id": runID.value.uuidString.lowercased(),
        ]
    }

    public func stopDeskRun() {
        guard let id = selectedConversation?.id else { return }
        stopDeskThread(id)
    }

    public func stopDeskThread(_ conversationID: BotConversationID) {
        guard let threadID = deskLinkedThreadID(for: conversationID) else { return }
        let affectsComposer = selectedConversation?.id == conversationID
        if isStopping, affectsComposer {
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.context.coordinator.stopAndAwaitTermination(threadId: threadID)
                } catch {
                    self.errorMessage = "Force stop: \(error.localizedDescription)"
                }
                if self.context.coordinator.activeRunId(threadId: threadID) == nil {
                    self.isStopping = false
                } else {
                    self.isStopping = false
                    if self.errorMessage == nil {
                        self.errorMessage = "Stop is taking longer than expected. Try again or restart the agent."
                    }
                }
            }
            return
        }
        if affectsComposer {
            isStopping = true
        }
        do {
            try resolvedRouter()?.stopAgentRun(thread: threadID)
        } catch {
            errorMessage = String(describing: error)
            if affectsComposer {
                isStopping = false
            }
        }
    }

    private func deskLinkedThreadID(for conversationID: BotConversationID) -> AgentThreadID? {
        if let selected = selectedConversation, selected.id == conversationID {
            return selected.linkedAgentThreadID
        }
        return conversations.first(where: { $0.id == conversationID })?.linkedAgentThreadID
    }

    @discardableResult
    public func send(_ text: String? = nil, relayHop: Int = 0) -> Bool {
        let attached = attachments
        let message = (text ?? composerText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard AgentChatTranscriptChrome.admitsSend(text: message, attachmentCount: attached.count) else { return false }
        guard let bot = selectedBot else { return false }
        if let message = deskDistillEffortValidationMessage {
            errorMessage = message
            return false
        }
        do {
            try admitDesktopSend(bot: bot)
        } catch {
            switch guestLaunchState(for: bot.id) {
            case .starting:
                errorMessage = "Linux desktop is starting. Try again when it is ready."
            case .failed(let message):
                errorMessage = message
            case .idle:
                errorMessage = "Docker desktop is not ready."
            }
            return false
        }
        lastSendAcknowledgedOnScreenForTesting = screen
        lastSendStartedProviderRun = false
        lastMentionedBotIDForTesting = nil
        lastHopUserTextForTesting = nil
        lastSupervisedRunUserTextForTesting = nil
        supervisedRunBotIDsForTesting = []
        if deskRunIsLive, text == nil {
            // The follow-up queue write cannot fail, so the words are already
            // accounted for and the composer may be consumed before it.
            consumeComposerForAcceptedSend()
            enqueueFollowUp(
                BotQueuedFollowUp(text: message, attachments: attached),
                botID: bot.id
            )
            return true
        }
        do {
            let display = AgentChatTranscriptChrome.displayUserLine(text: message, attachments: attached)
            let conversation = try persistUserMessage(bot: bot, text: display)
            // WHY here and not before the do: clearing the composer, the staged
            // attachments and the saved draft used to happen before this write, so
            // a failed persist left the user with an error message and none of the
            // words or files they had just sent.
            consumeComposerForAcceptedSend()
            appendDeskMessage(BotDeskMessage(role: .user, text: display), botID: bot.id, conversationID: conversation.id)
            if let started = try enqueueSupervisedBotRun(
                bot: bot,
                conversation: conversation,
                userText: message,
                attachments: attached
            ) {
                stampDeskUserMessageIdentity(runID: started.runID, botID: bot.id)
            }
            return true
        } catch {
            errorMessage = String(describing: error)
            return false
        }
    }

    /// Consumes the composer in the same turn the send becomes the app's:
    /// the cleared editor and the flushed draft are the visible contract that a
    /// sent line never comes back as a draft. Only call this once the words are
    /// durable (persisted message) or queued in memory (live-run follow-up).
    private func consumeComposerForAcceptedSend() {
        composerText = ""
        composerCursorOffset = nil
        attachments = []
        flushPendingDraftPersistence()
    }

    /// Host-catalog Bot sends use the same persisted user line, compiled Bot
    /// brain, routing, provider start, and follow-through as a Desk send. They
    /// never change the user's currently selected Bot or conversation.
    func enqueueHostMessage(
        botID: BotID,
        text: String,
        conversationID: BotConversationID?,
        attachments: [AgentAttachment] = [],
        routing: BotDeskRouting
    ) throws -> JSONValue {
        guard let bot = try botStore.get(id: botID), bot.deletedAt == nil else {
            throw BotStoreError.notFound
        }
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { throw BotStoreError.invalidRow("message is empty") }
        guard resolvedRouter() != nil, try currentRevision(for: bot) != nil else {
            throw BotStoreError.invalidRow("Bot runtime is unavailable")
        }
        try admitDesktopSend(bot: bot)

        if let conversationID {
            guard let existing = try botStore.conversation(id: conversationID),
                  existing.botID == bot.id else {
                throw BotStoreError.notFound
            }
            if let threadID = existing.linkedAgentThreadID,
               let activeRunID = context.coordinator.activeRunId(threadId: threadID) {
                let followUp = BotQueuedFollowUp(
                    text: message,
                    attachments: attachments,
                    conversationID: existing.id,
                    routing: routing
                )
                enqueueFollowUp(followUp, botID: bot.id)
                return .object([
                    "id": .string(followUp.id.uuidString.lowercased()),
                    "bot_id": .string(bot.id.value.uuidString.lowercased()),
                    "conversation_id": .string(existing.id.value.uuidString.lowercased()),
                    "thread_id": .string(threadID.value.uuidString.lowercased()),
                    "run_id": .string(activeRunID.value.uuidString.lowercased()),
                    "enqueued": .bool(true),
                    "queued_follow_up": .bool(true),
                ])
            }
        }

        let display = AgentChatTranscriptChrome.displayUserLine(text: message, attachments: attachments)
        let conversation = try persistUserMessage(
            bot: bot,
            text: display,
            adoptSelection: false,
            createNew: conversationID == nil,
            conversationID: conversationID
        )
        appendDeskMessage(
            BotDeskMessage(role: .user, text: display),
            botID: bot.id,
            conversationID: conversation.id
        )
        guard let prepared = try enqueueSupervisedBotRun(
            bot: bot,
            conversation: conversation,
            userText: message,
            attachments: attachments,
            routingOverride: routing
        ) else {
            throw BotStoreError.invalidRow("Bot runtime is unavailable")
        }
        stampDeskUserMessageIdentity(runID: prepared.runID, botID: bot.id)
        return .object([
            "bot_id": .string(bot.id.value.uuidString.lowercased()),
            "conversation_id": .string(prepared.conversation.id.value.uuidString.lowercased()),
            "thread_id": .string(prepared.thread.id.value.uuidString.lowercased()),
            "run_id": .string(prepared.runID.value.uuidString.lowercased()),
            "enqueued": .bool(true),
            "queued_follow_up": .bool(false),
        ])
    }

    public func addSkill() {
        let skillID = skillDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !skillID.isEmpty, let bot = selectedBot else { return }
        guard !skillID.contains("/") else {
            errorMessage = "Catalog ids only. A skill id is not a filesystem path."
            return
        }
        do {
            // Dest first. Add used to listSkillBindings after the store
            // wrote this binding. The binding is already the row.
            let binding = BotSkillBinding(
                botID: bot.id,
                skillID: skillID,
                enabled: true
            )
            try botStore.setSkillBinding(binding)
            skillDraft = ""
            flushPendingDraftPersistence()
            adoptWrittenSkill(binding)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func setSkillEnabled(skillID: String, enabled: Bool) {
        guard let bot = selectedBot else { return }
        do {
            // Dest first. Enable used to listSkillBindings after the
            // store wrote this binding. Patch it locally so dest does
            // not reread every skill.
            let binding = BotSkillBinding(
                botID: bot.id,
                skillID: skillID,
                enabled: enabled
            )
            try botStore.setSkillBinding(binding)
            adoptEnabledSkill(binding)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func botHome(for bot: BotDefinition) -> BotHome {
        BotHome(appSupportDirectory: context.appSupportDirectory, bot: bot)
    }

    public func ensureBotHome(_ bot: BotDefinition, revision: BotRevision? = nil) {
        let home = botHome(for: bot)
        let publishedSoul = bot.currentRevisionID.flatMap { try? botStore.getRevision(id: $0) }?.soul
        let soul = revision?.soul ?? publishedSoul ?? studioDraft.soul
        let description = revision?.description ?? bot.description
        try? home.ensure(
            name: bot.name,
            handle: bot.handle,
            title: revision?.title ?? bot.title,
            description: description,
            soul: soul,
            legacyFacts: leftoverStoreFacts(for: bot)
        )
        try? home.writeIdentity(name: bot.name, handle: bot.handle, title: revision?.title ?? bot.title)
        refreshHomeFiles(for: bot)
    }

    public func syncPublishedHome(_ bot: BotDefinition, revision: BotRevision) {
        let home = botHome(for: bot)
        try? home.ensure(
            name: revision.name,
            handle: bot.handle,
            title: revision.title,
            description: revision.description,
            soul: revision.soul,
            legacyFacts: leftoverStoreFacts(for: bot)
        )
        try? home.writeIdentity(name: revision.name, handle: bot.handle, title: revision.title)
        try? home.writeDescription(revision.description)
        try? home.writeSoul(revision.soul)
        refreshHomeFiles(for: bot)
    }

    public func leftoverStoreFacts(for bot: BotDefinition) -> [String] {
        // PERF: single pass avoids the filter + map intermediate on the
        // bot-mind write path; fact order identical.
        ((try? botStore.listMemory(botID: bot.id)) ?? []).reduce(into: [String]()) { out, memory in
            if memory.forgottenAt == nil && memory.trusted {
                out.append(memory.content)
            }
        }
    }

    public func memoryFileTexts(for bot: BotDefinition) -> [BotMemoryFileText] {
        guard isMemoryActive else { return [] }
        return ((try? botHome(for: bot).readBootstrapMemory()) ?? []).map {
            BotMemoryFileText(path: $0.path, body: $0.body)
        }
    }

    public func ownedSkillTexts(for bot: BotDefinition) -> [BotOwnedSkillText] {
        ((try? botHome(for: bot).listOwnedSkills()) ?? []).map {
            BotOwnedSkillText(slug: $0.slug, body: $0.body)
        }
    }

    public func refreshHomeFiles(for bot: BotDefinition? = nil) {
        guard let bot = bot ?? selectedBot else {
            homeFiles = []
            return
        }
        homeFiles = (try? botHome(for: bot).listRelativePaths()) ?? []
        if let path = selectedHomePath, !homeFiles.contains(path) {
            selectedHomePath = homeFiles.first
            if let selectedHomePath {
                openHomeFile(selectedHomePath)
            } else {
                homeDraft = ""
                homeOriginal = ""
            }
        }
    }

    public func openHomeFile(_ relativePath: String) {
        guard let bot = selectedBot else { return }
        setStudioFilesLocation(.botFiles, for: bot)
        do {
            let text = try botHome(for: bot).readFile(relativePath: relativePath)
            selectedHomePath = relativePath
            homeDraft = text
            homeOriginal = text
            attachHomeFilesSurface(for: bot)
            homeFilesModel?.reveal(relativePath: relativePath)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func openRemoteFile(
        botID: BotID,
        relativePath: String,
        split: Bool,
        root: String
    ) throws {
        guard let bot = try botStore.get(id: botID), bot.deletedAt == nil else {
            throw BotStoreError.notFound
        }
        openStudio(bot)
        studioTab = .files
        setStudioFilesLocation(root == "docker_home" ? .dockerHome : .botFiles, for: bot)
        attachHomeFilesSurface(for: bot)
        guard let router = homeFilesRouter else {
            throw BotStoreError.invalidRow("Bot files surface is unavailable")
        }
        let workspaceID = WorkspaceID(bot.id.value)
        let surfaceID = SurfaceID(bot.id.value)
        if split {
            _ = try router.filesSplitTab(
                workspace: workspaceID,
                sourceSurface: surfaceID,
                paneID: nil,
                direction: .right,
                path: relativePath
            )
            homeFilesModel?.splitFileTab(path: relativePath, direction: .right)
        } else {
            _ = try router.filesOpenTab(
                workspace: workspaceID,
                sourceSurface: surfaceID,
                paneID: nil,
                path: relativePath
            )
            homeFilesModel?.reveal(relativePath: relativePath)
        }
        if root == "docker_home" {
            selectedHomePath = relativePath
        } else {
            let text = try botHome(for: bot).readFile(relativePath: relativePath)
            selectedHomePath = relativePath
            homeDraft = text
            homeOriginal = text
        }
    }

    public func discardHomeFile() {
        homeDraft = homeOriginal
    }

    public func saveHomeFile() {
        guard let bot = selectedBot, let path = selectedHomePath else { return }
        do {
            let home = botHome(for: bot)
            switch path {
            case BotHome.identityName:
                try home.writeIdentity(name: bot.name, handle: bot.handle, title: selectedRevision?.title ?? bot.title)
                homeDraft = try home.readIdentity()
                homeOriginal = homeDraft
            case BotHome.soulName:
                studioDraft.soul = homeDraft
                _ = try saveStudio()
                homeDraft = try home.readSoul()
                homeOriginal = homeDraft
            case BotHome.descriptionName:
                studioDraft.description = homeDraft
                _ = try saveStudio()
                homeDraft = try home.readDescription()
                homeOriginal = homeDraft
            default:
                try home.writeFile(relativePath: path, contents: homeDraft)
                homeOriginal = homeDraft
            }
            refreshHomeFiles(for: bot)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func createThisBotSkill() {
        guard let bot = selectedBot else { return }
        do {
            ensureBotHome(bot, revision: selectedRevision)
            let path = try botHome(for: bot).createOwnedSkill(slug: thisBotSkillDraft)
            thisBotSkillDraft = ""
            refreshHomeFiles(for: bot)
            openHomeFile(path)
            studioTab = .files
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func attachHomeFilesSurface(for bot: BotDefinition) {
        let location = resolvedStudioFilesLocation(for: bot)
        let root: URL
        switch location {
        case .botFiles:
            let home = botHome(for: bot)
            ensureBotHome(bot, revision: selectedRevision)
            root = home.root
        case .dockerHome:
            do {
                try computerGuestService?.prepareHome(botID: bot.id)
                root = try BotGuestHome.ensure(
                    appSupport: context.appSupportDirectory,
                    botID: bot.id
                )
            } catch {
                errorMessage = String(describing: error)
                return
            }
        }
        studioFilesLocation = location
        if let model = homeFilesModel, model.root == root.path {
            return
        }
        homeFilesModel?.close()
        let workspaceID = WorkspaceID(bot.id.value)
        let router = BotHomeFilesRouter(
            root: root.path,
            workspaceID: workspaceID,
            locksBotHomeProjections: location == .botFiles
        )
        if location == .botFiles {
            router.onDidSave = { [weak self] path, content in
                self?.publishHomeFileIfNeeded(relativePath: path, contents: content)
            }
        }
        homeFilesRouter = router
        let model = FilesViewModel(
            surfaceID: SurfaceID(bot.id.value),
            workspaceID: workspaceID,
            root: root.path,
            router: router
        )
        homeFilesModel = model
        model.loadInitialState()
    }

    public func setStudioFilesLocation(
        _ location: BotStudioFilesLocation,
        for bot: BotDefinition
    ) {
        let resolved = supportsDockerHomeFiles(for: bot) ? location : .botFiles
        studioFilesLocationsByBot[bot.id] = resolved
        persistStudioFilesLocations()
        studioFilesLocation = resolved
        attachHomeFilesSurface(for: bot)
    }

    func supportsDockerHomeFiles(for bot: BotDefinition) -> Bool {
        cachedRevision(for: bot)?.desktopKind == .dockerDesktop
            || (selectedBotID == bot.id && selectedRevision?.desktopKind == .dockerDesktop)
    }

    private func resolvedStudioFilesLocation(for bot: BotDefinition) -> BotStudioFilesLocation {
        guard supportsDockerHomeFiles(for: bot) else { return .botFiles }
        return studioFilesLocationsByBot[bot.id] ?? .dockerHome
    }

    public func confirmClearDockerData(for bot: BotDefinition) {
        guard supportsDockerHomeFiles(for: bot),
              resolvedStudioFilesLocation(for: bot) == .dockerHome else { return }
        homeFilesModel?.close()
        homeFilesModel = nil
        homeFilesRouter = nil
        guestScreenURLByBot[bot.id.value] = nil
        guestRunningByBot[bot.id.value] = nil
        guestLaunchStateByBot[bot.id.value] = nil
        if selectedBotID == bot.id {
            lastGuestScreenURL = nil
        }
        objectWillChange.send()
        let service = computerGuestService
        let appSupport = context.appSupportDirectory
        Task.detached { [weak self, service] in
            service?.teardown(botID: bot.id)
            do {
                _ = try BotGuestHome.ensure(appSupport: appSupport, botID: bot.id)
                await MainActor.run {
                    guard let self, self.selectedBotID == bot.id else { return }
                    self.attachHomeFilesSurface(for: bot)
                }
            } catch {
                await MainActor.run {
                    self?.errorMessage = String(describing: error)
                }
            }
        }
    }

    var homeFilesRouterForTesting: BotHomeFilesRouter? { homeFilesRouter }

    public func publishHomeFileIfNeeded(relativePath: String, contents: String) {
        switch relativePath {
        case BotHome.soulName:
            studioDraft.soul = contents
            _ = try? saveStudio()
        case BotHome.descriptionName:
            studioDraft.description = contents
            _ = try? saveStudio()
        default:
            break
        }
    }

    public func removeSkill(skillID: String) {
        guard let bot = selectedBot else { return }
        do {
            // Dest first. Remove used to listSkillBindings after the
            // store dropped this row. Drop it locally.
            try botStore.removeSkillBinding(botID: bot.id, skillID: skillID)
            dropRemovedSkill(skillID, botID: bot.id)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// Same workspace Desk send binds. Studio already shows the name;
    /// compile uses name + cwd so first-chat cannot invent a folder.
    public var advertisedWorkspace: BotWorkspaceHonesty? {
        let id = selectedBot?.workspaceID
            ?? context.state.window.selectedWorkspaceID
            ?? context.state.window.workspaces.first
        guard let id, let workspace = context.state.workspaces[id] else { return nil }
        let honesty = BotWorkspaceHonesty(name: workspace.name, cwd: workspace.cwd)
        return honesty.placeLabel.isEmpty ? nil : honesty
    }

    public var studioWorkspaceLabel: String {
        let name = advertisedWorkspace?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "None" : name
    }

    /// Same last website tools persist. Compile URL + title so first-chat
    /// cannot invent a page. Blank URL compiles as omitted.
    public var advertisedBrowser: BotBrowserTarget? {
        guard let bot = selectedBot else { return nil }
        let store = BotBrowserStore(appSupportDirectory: context.appSupportDirectory)
        guard let target = try? store.loadTarget(botID: bot.id) else { return nil }
        let url = target.url.trimmingCharacters(in: .whitespacesAndNewlines)
        return url.isEmpty ? nil : target
    }

    public var studioDesktopSummary: String {
        resolvedDesktopKind(studioDraft.desktopKind).displayTitle
    }

    public var studioApprovalLabel: String { "Supervised" }

    public var inspectedBrain: ContextAssemblyReceipt? {
        if screen == .studio {
            return previewBrain()
        }
        return lastContextReceipt ?? previewBrain()
    }

    public var inspectedBrainIsPreview: Bool {
        screen == .studio || lastContextReceipt == nil
    }

    public var inspectedBrainIsLastCall: Bool {
        screen != .studio && lastContextReceipt?.runID != nil
    }

    public func previewBrain(userText: String? = nil) -> ContextAssemblyReceipt? {
        let text = (userText ?? composerText)
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let selectedOrDraft = selectedBot ?? studioPreviewBot() else { return nil }
        var bot = selectedOrDraft
        if screen == .studio {
            bot.notificationsEnabled = studioDraft.notificationsEnabled
        }
        guard let revision = studioPreviewRevision(for: bot) ?? selectedRevision else { return nil }
        let turnDirective = BotPeerDelegation.turnDirective(
            mentionedBots: BotMentionParser.mentionedBots(
                in: request,
                bots: bots,
                excluding: bot.id
            )
        )
        let memoryFiles = memoryFileTexts(for: bot)
        let previewProvider = deskRouting.provider
        let previewModel = deskRouting.resolvedModel(defaultModel: Self.defaultModel(for:))
        let key = [
            bot.id.value.uuidString,
            revision.digest,
            request,
            previewProvider.rawValue,
            previewModel,
            memoryFiles.map { "\($0.path):\($0.body)" }.joined(separator: "\u{1e}"),
            skillBindings.map(\.skillID).joined(separator: ","),
            routines.map {
                "\($0.definition.id.value.uuidString):\($0.activation.isEnabled):\($0.definition.name):\($0.definition.prompt):\($0.definition.scheduleNote)"
            }.joined(separator: ","),
            advertisedWorkspace?.placeLabel ?? "",
            advertisedBrowser.map { "\($0.title)\u{1d}\($0.url)" } ?? "",
            ownedSkillTexts(for: bot).map { "\($0.slug):\($0.body)" }.joined(separator: ","),
            selectedConversation?.id.value.uuidString ?? "",
            bot.notificationsEnabled ? "n1" : "n0",
            turnDirective ?? "",
        ].joined(separator: "\u{1f}")
        if cachedPreviewBrainKey == key, let cached = cachedPreviewBrain {
            return cached
        }
        previewBrainAssembleCountForTesting += 1
        let receipt = BotBrainCompiler.assemble(
            bot: bot,
            revision: revision,
            userText: request,
            memoryFiles: memoryFiles,
            skills: skillBindings,
            ownedSkills: ownedSkillTexts(for: bot),
            routines: routines,
            workspace: advertisedWorkspace,
            browser: advertisedBrowser,
            conversationID: selectedConversation?.id,
            runProvider: previewProvider,
            runModel: previewModel,
            turnDirective: turnDirective
        )
        cachedPreviewBrainKey = key
        cachedPreviewBrain = receipt
        return receipt
    }

    public var studioHasUnpublishedChanges: Bool {
        guard let revision = selectedRevision else { return studioDraft.isNew }
        let bot = selectedBot
        return studioDraft.name != revision.name
            || studioDraft.title != revision.title
            || studioDraft.description != revision.description
            || studioDraft.soul != revision.soul
            || resolvedDesktopKind(studioDraft.desktopKind) != resolvedDesktopKind(revision.desktopKind)
            || studioDraft.notificationsEnabled != (bot?.notificationsEnabled ?? true)
            || studioDraft.avatarSymbol != (bot?.avatarSymbol ?? "person.crop.circle")
            || BotHandle.normalize(studioDraft.handle) != bot?.handle
    }

    public func addMemory() {
        guard isMemoryActive else { return }
        let content = memoryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, let bot = selectedBot else { return }
        do {
            // Dest first. Add used to listMemory after putMemory before
            // the new fact could paint. The store already returned the row.
            let item = try botStore.putMemory(
                botID: bot.id,
                content: content,
                provenance: "user",
                trusted: true,
                source: "studio"
            )
            memoryDraft = ""
            flushPendingDraftPersistence()
            adoptWrittenMemory(item)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func correctMemory(id: BotMemoryItemID, content: String) {
        guard isMemoryActive else { return }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            // Dest first. Correct used to listMemory after the store
            // returned the revised row. Insert it locally.
            let item = try botStore.correctMemory(id: id, content: trimmed)
            adoptWrittenMemory(item)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func forgetMemory(id: BotMemoryItemID) {
        guard isMemoryActive else { return }
        do {
            // Dest first. Forget used to listMemory after the store
            // marked the row forgotten. Drop it locally.
            try botStore.forgetMemory(id: id)
            dropForgottenMemory(id)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func saveRoutine() {
        guard let bot = selectedBot else { return }
        let name = routineName.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = routinePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !prompt.isEmpty else {
            errorMessage = "Routine name and prompt are required."
            return
        }
        do {
            // Dest first. Save used to listRoutines after the store
            // wrote this schedule. The definition is already the row.
            _ = try routineSpec.makeRecurrence()
            if routineScheduleNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                routineScheduleNote = routineSpec.displayNote()
            }
            let definition = BotRoutineDefinition(
                botID: bot.id,
                name: name,
                prompt: prompt,
                scheduleNote: routineScheduleNote,
                scheduleSpecJSON: routineSpec.encodedJSON()
            )
            try botStore.saveRoutine(definition)
            routineName = ""
            routinePrompt = ""
            routineScheduleNote = ""
            flushPendingDraftPersistence()
            adoptWrittenRoutine(definition)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func setRoutineEnabled(id: BotRoutineID, enabled: Bool) {
        do {
            // Dest first. Enable used to listRoutines after the store
            // wrote this activation. Patch it locally so dest does not
            // reread every schedule.
            try botStore.setRoutineEnabled(id: id, enabled: enabled)
            adoptEnabledRoutine(id: id, enabled: enabled)
            if let index = scheduleTaskSource.firstIndex(where: { $0.id == id }) {
                scheduleTaskSource[index].isEnabled = enabled
                applyScheduleTaskFilters()
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func requestRoutineTestRun(id: BotRoutineID) {
        let routine = routines.first(where: { $0.definition.id == id })
        let fleetItem = scheduleTaskSource.first(where: { $0.id == id })
        let instruction = (routine?.definition.prompt ?? fleetItem?.prompt)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !instruction.isEmpty else {
            errorMessage = "Task instruction is required."
            return
        }
        let botID = routine?.definition.botID ?? fleetItem?.botID
        guard let botID, let bot = bots.first(where: { $0.id == botID }) else {
            errorMessage = "Task bot is unavailable."
            return
        }
        let spec = routine?.definition.scheduleSpec
            ?? fleetItem.flatMap {
                BotScheduleSpec.decodeJSON($0.scheduleSpecJSON)
                    ?? BotScheduleSpec.parseDisplayNote($0.scheduleNote)
            }
        do {
            // Dest first. Test run used to listRoutines after the store
            // stamped last_test_run_requested_at. Patch it locally so
            // dest does not reread every schedule.
            try botStore.requestRoutineTestRun(id: id)
            adoptTestRunRequested(id: id)
            openDesk(bot)
            // Each task execution owns a fresh conversation and provider session.
            guard createDeskThread() else { return }
            if let spec {
                deskRouting.provider = spec.provider
                deskRouting.providerInstanceID = spec.providerInstanceID
                deskRouting.model = spec.model
                deskRouting.routingMode = spec.provider == .distill ? .manual : spec.routingMode
                deskRouting.reasoningEffort = spec.reasoningEffort
                deskRouting.reasoningModel = spec.reasoningModel
                deskRouting.distillMainEffortSelection = spec.provider == .distill
                    ? (spec.distillMainEffortSelection ?? .fixed(spec.reasoningEffort)) : nil
                deskRouting.distillReasoningEffortSelection = spec.provider == .distill
                    ? (spec.distillReasoningEffortSelection ?? .automatic) : nil
            }
            _ = send(instruction)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public nonisolated static func defaultModel(for provider: AgentProvider) -> String {
        switch provider {
        case .claude: return "opus"
        case .codex: return AgentDefaultModelSelection.codexBuiltInDefault
        case .grok: return "grok-4.6"
        case .distill: return ""
        }
    }

    // MARK: - Internals

    private func resolvedRouter() -> AppCommandRouter? {
        if let router { return router }
        let existing: AppCommandRouter? = context.router
        return existing
    }

    private func attachmentStore() -> AgentAttachmentStore {
        AgentAttachmentStore(
            root: context.appSupportDirectory.appendingPathComponent("agent-attachments", isDirectory: true)
        )
    }

    private func refreshFlags() {
        let settings = settingsStore.load()
        isControlPlaneActive = settings.isBotControlPlaneActive
        isMemoryActive = settings.isBotMemoryActive
        isAutonomyActive = settings.isBotAutonomyActive
    }

    private func reloadFleet() {
        fleetReloadCountForTesting += 1
        do {
            let destIDs = Set(bots.map(\.id))
            // Hide is a roster view, not a delete: a hidden teammate still owns
            // the user's drafts and queued follow-ups, so the store roster (not
            // the filtered list) is what pruning may delete against.
            let roster = try botStore.list(includeHidden: true)
            bots = showHidden ? roster : roster.filter { !$0.hidden }
            if selectedBotID == nil || !bots.contains(where: { $0.id == selectedBotID }) {
                restoreSelectedBotIfNeeded()
            }
            // Dest first. First paint dest used to dest dest preview
            // (listConversations + listRecent) before dest dested Chat.
            // Dest dests this bubble first; dest dests dest preview
            // from dest Chat.
            destSelectedChatIfNeeded()
            var previews: [BotID: String] = lastPreviewByBot
            var updated: [BotID: Date] = lastUpdatedByBot
            let live = Set(bots.map(\.id))
            // Single pass: drop preview/update entries for removed bots
            // together, no second dictionary traversal.
            for key in previews.keys where !live.contains(key) {
                previews.removeValue(forKey: key)
                updated.removeValue(forKey: key)
            }
            for bot in bots {
                if let last = messagesByBot[bot.id]?.last, !last.text.isEmpty {
                    previews[bot.id] = last.text
                    updated[bot.id] = last.createdAt
                    continue
                }
                if destIDs.contains(bot.id) {
                    // Dest first. Remount dest used to list this teammate's
                    // conversations + recent messages before dest dested Chat.
                    continue
                }
                if bot.id != selectedBotID {
                    // Dest first. First paint dest used to list every
                    // teammate before dest dested Chat. Dest dests this
                    // preview when dest dests this row.
                    continue
                }
                conversationListCountForTesting += 1
                guard let conversation = try botStore.listConversations(botID: bot.id).first else { continue }
                if let threadID = conversation.linkedAgentThreadID,
                   let stored = try? context.messageRepo.listRecent(threadId: threadID, limit: 8),
                   let last = stored.last(where: { $0.role == .user || $0.role == .assistant }) {
                    previews[bot.id] = last.role == .user
                        ? BotsDeskFollowThrough.displayUserText(from: last.content)
                        : last.content
                    updated[bot.id] = last.createdAt
                } else if !conversation.title.isEmpty {
                    previews[bot.id] = conversation.title
                    updated[bot.id] = conversation.updatedAt
                }
            }
            lastPreviewByBot = previews
            lastUpdatedByBot = updated
            publishRosterIfNeeded()
            rebuildAttentionStates()
            let liveFleetIDs = Set(roster.map(\.id))
            pruneQueuedFollowUpsToFleet(live: liveFleetIDs)
            pruneComposerDraftsToFleet(live: liveFleetIDs)
            pruneInspectorDraftsToFleet(live: liveFleetIDs)
            pruneStudioDraftsToFleet(live: liveFleetIDs)
            pruneUnpublishedNewBotIDs(live: liveFleetIDs)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func reloadAttention() {
        do {
            attentionListCountForTesting += 1
            attentionItems = try botStore.listAttention()
            rebuildAttentionStates()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func rebuildAttentionStates() {
        var states: [BotID: BotAttentionState] = [:]
        for item in attentionItems where item.acknowledgedAt == nil {
            states[item.botID] = .needsAttention
        }
        let liveHandoffBots = activeHandoffBotIDs()
        for bot in bots {
            if liveHandoffBots.contains(bot.id) {
                states[bot.id] = .working
                continue
            }
            if states[bot.id] == .needsAttention { continue }
            let dest = destConversations(botID: bot.id)
            if !dest.isEmpty {
                states[bot.id] = Self.attentionState(from: dest, hasOpenAttention: false)
                continue
            }
            if bot.id != selectedBotID {
                // Dest first. First paint dest used to list every
                // teammate before dest dested Chat. Dest dests this
                // chip when dest dests this row.
                if let existing = attentionStateByBot[bot.id] {
                    states[bot.id] = existing == .needsAttention ? BotAttentionState.none : existing
                } else {
                    states[bot.id] = BotAttentionState.none
                }
                continue
            }
            if let existing = attentionStateByBot[bot.id], existing != BotAttentionState.none {
                // Dest first. Remount dest already dested this chip
                // from dest cache. Keep it unless dest inbox already
                // dested needs-you above.
                states[bot.id] = existing == .needsAttention ? BotAttentionState.none : existing
                continue
            }
            conversationListCountForTesting += 1
            let conversations = (try? botStore.listConversations(botID: bot.id)) ?? []
            states[bot.id] = Self.attentionState(from: conversations, hasOpenAttention: false)
        }
        attentionStateByBot = states
    }

    /// `reload: false` is for callers that touch several teammates in one
    /// synchronous turn (one handoff delta carries two conversations): the
    /// roster pass is a SQLite hydration, so it must be paid once per turn,
    /// not once per teammate.
    private func applyAttentionState(
        for botID: BotID,
        conversations: [BotConversation],
        reload: Bool = true
    ) {
        var states = attentionStateByBot
        if activeHandoffBotIDs().contains(botID) {
            states[botID] = .working
        } else {
            let hasOpenAttention = attentionItems.contains {
                $0.botID == botID && $0.acknowledgedAt == nil
            }
            states[botID] = Self.attentionState(from: conversations, hasOpenAttention: hasOpenAttention)
        }
        attentionStateByBot = states
        if reload, screen == .activeBots {
            reloadActiveBotsScreen()
        }
    }

    private static func attentionState(
        from conversations: [BotConversation],
        hasOpenAttention: Bool
    ) -> BotAttentionState {
        if hasOpenAttention { return .needsAttention }
        if conversations.contains(where: { $0.attentionState == .needsAttention }) {
            return .needsAttention
        }
        if conversations.contains(where: { $0.attentionState == .working }) {
            return .working
        }
        if conversations.contains(where: { $0.unread || $0.attentionState == .unreadActivity }) {
            return .unreadActivity
        }
        return .none
    }

    private func leaveDeskLiveWatch() {
        deskLiveTurnWatch?.cancel()
        deskLiveTurnWatch = nil
        if let threadID = selectedConversation?.linkedAgentThreadID {
            clearDeskObservedEvents(threadID: threadID)
        }
    }

    private func clearDeskObservedEvents(threadID: AgentThreadID) {
        liveObservedEventBytesTotal = max(
            0,
            liveObservedEventBytesTotal - (liveObservedEventBytesByThread[threadID] ?? 0)
        )
        liveObservedEventsByThread[threadID] = nil
        liveObservedEventBytesByThread[threadID] = nil
        liveObservedEventOverflowThreads.remove(threadID)
    }

    /// Studio dest needs revision, memory, skills, routines, and the last
    /// brain receipt. It does not show Chat, so it must not replay the desk
    /// stream before the dest can paint. Desk dest used to pay the same
    /// six store reads on every roster click even when that inspector
    /// snapshot was already warm.
    private func reloadStudioSupport(id: BotID, force: Bool = false) {
        if !force, let cached = studioSupportByBot[id] {
            applyStudioSupport(cached)
            applyDeskRouting(for: selectedConversation)
            syncQueuedFollowUps()
            return
        }
        studioSupportReloadCountForTesting += 1
        do {
            conversationListCountForTesting += 1
            deskThreadRailRoutingCache.removeAll()
            conversations = try botStore.listConversations(botID: id)
            prefetchDeskThreadRailRouting(for: conversations)
            if let remembered = selectedConversationByBot[id],
               let found = conversations.first(where: { $0.id == remembered }) {
                selectedConversation = found
            } else if let selected = selectedConversation, selected.botID == id,
                      conversations.contains(where: { $0.id == selected.id }) {
                selectedConversation = conversations.first(where: { $0.id == selected.id })
            } else {
                selectedConversation = conversations.first
            }
            if let selected = selectedConversation {
                selectedConversationByBot[id] = selected.id
            }
            applyDeskRouting(for: selectedConversation)
            if let bot = try botStore.get(id: id) {
                selectedRevision = try currentRevision(for: bot)
            } else {
                selectedRevision = nil
            }
            skillListCountForTesting += 1
            skillBindings = try botStore.listSkillBindings(botID: id)
            reloadMemory(botID: id)
            reloadRoutines(botID: id)
            reloadContextReceipt(botID: id)
            rememberStudioSupport(for: id)
            syncQueuedFollowUps()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func applyStudioSupport(
        _ snapshot: BotStudioSupportSnapshot,
        prefetchRail: Bool = true
    ) {
        conversations = snapshot.conversations
        if prefetchRail {
            prefetchDeskThreadRailRouting(for: conversations)
        }
        selectedConversation = snapshot.selectedConversation
        selectedRevision = snapshot.selectedRevision
        skillBindings = snapshot.skillBindings
        memoryItems = snapshot.memoryItems
        lastContextReceipt = snapshot.lastContextReceipt
        routines = snapshot.routines
    }

    private func rememberStudioSupport(for id: BotID) {
        studioSupportByBot[id] = BotStudioSupportSnapshot(
            conversations: conversations,
            selectedConversation: selectedConversation,
            selectedRevision: selectedRevision,
            skillBindings: skillBindings,
            memoryItems: memoryItems,
            lastContextReceipt: lastContextReceipt,
            routines: routines
        )
    }

    /// Add dest used to listMemory after putMemory. The store already
    /// returned the row; insert it locally so dest does not reread facts.
    private func adoptWrittenMemory(_ item: BotMemoryItem) {
        memoryItems.removeAll { $0.id == item.id }
        memoryItems.insert(item, at: 0)
        rememberStudioSupport(for: item.botID)
    }

    /// Forget dest used to listMemory after the store marked the row.
    /// Drop it locally so dest does not reread facts.
    private func dropForgottenMemory(_ id: BotMemoryItemID) {
        memoryItems.removeAll { $0.id == id }
        if let botID = selectedBotID {
            rememberStudioSupport(for: botID)
        }
    }

    /// Save dest used to listRoutines after the store wrote this
    /// schedule. Insert it locally so dest does not reread routines.
    private func adoptWrittenRoutine(_ definition: BotRoutineDefinition) {
        let routine = BotRoutine(
            definition: definition,
            activation: BotRoutineActivation(
                routineID: definition.id,
                botID: definition.botID,
                isEnabled: false
            )
        )
        routines.removeAll { $0.definition.id == definition.id }
        routines.insert(routine, at: 0)
        rememberStudioSupport(for: definition.botID)
    }

    /// Enable dest used to listRoutines after the store wrote this
    /// activation. Patch it locally so dest does not reread schedules.
    private func adoptEnabledRoutine(id: BotRoutineID, enabled: Bool) {
        guard let index = routines.firstIndex(where: { $0.definition.id == id }) else {
            return
        }
        var routine = routines[index]
        routine.activation.isEnabled = enabled
        routine.activation.updatedAt = Date()
        routines[index] = routine
        rememberStudioSupport(for: routine.definition.botID)
    }

    /// Add dest used to listSkillBindings after the store wrote this
    /// binding. Insert it locally so dest does not reread skills.
    private func adoptWrittenSkill(_ binding: BotSkillBinding) {
        skillBindings.removeAll { $0.skillID == binding.skillID }
        skillBindings.insert(binding, at: 0)
        rememberStudioSupport(for: binding.botID)
    }

    /// Enable dest used to listSkillBindings after the store wrote this
    /// binding. Patch it locally so dest does not reread skills.
    private func adoptEnabledSkill(_ binding: BotSkillBinding) {
        guard let index = skillBindings.firstIndex(where: { $0.skillID == binding.skillID }) else {
            return
        }
        skillBindings[index] = binding
        rememberStudioSupport(for: binding.botID)
    }

    private func dropRemovedSkill(_ skillID: String, botID: BotID) {
        skillBindings.removeAll { $0.skillID == skillID }
        rememberStudioSupport(for: botID)
    }

    /// Test run dest used to listRoutines after the store stamped this
    /// request. Patch it locally so dest does not reread schedules.
    private func adoptTestRunRequested(id: BotRoutineID) {
        guard let index = routines.firstIndex(where: { $0.definition.id == id }) else {
            return
        }
        var routine = routines[index]
        routine.activation.lastTestRunRequestedAt = Date()
        routine.activation.updatedAt = Date()
        routines[index] = routine
        rememberStudioSupport(for: routine.definition.botID)
    }

    /// Dest first. First paint dest used to dest dest preview before
    /// dest dested Chat. Dest dests this bubble from dest cache or
    /// dest title/thread; dest dests dest preview from that dest.
    private func destSelectedChatIfNeeded() {
        guard let id = selectedBotID, bots.contains(where: { $0.id == id }) else { return }
        let conversationID = destConversation(for: id)?.id
        let cached = cachedMessages(botID: id, conversationID: conversationID)
        deskMessages = cached
        if cached.isEmpty {
            restoreDeskMessages(botID: id)
        }
    }

    private func reloadSelectedBot(id: BotID) {
#if DEBUG
        reloadSelectedBotCountForTesting += 1
#endif
        leaveDeskLiveWatch()
        resetTokenSaverFooterSnapshot()
        let conversation = destConversation(for: id)
        let threadID = conversation?.linkedAgentThreadID
        deskLiveTimeline = threadID.flatMap { liveTimelineByThread[$0] } ?? AssistantTimelineState()
        deskStreamEventCount = threadID.flatMap { liveStreamCountByThread[$0] } ?? 0
        let cached = cachedMessages(botID: id, conversationID: conversation?.id)
        deskMessages = cached
        // Dest first. First paint dest used to dest inspector
        // (conversations, revision, skills, memory, routines,
        // receipt) before dest dested Chat. Dest dests this
        // bubble first; dest dests inspector after dest dested Chat.
        if cached.isEmpty {
            restoreDeskMessages(botID: id)
        }
        restoreDeskWorkLog(botID: id)
        restoreDeskLiveTurn(botID: id)
        reloadStudioSupport(id: id)
        reloadTokenSaverThreadSavings()
        if let bot = bots.first(where: { $0.id == id }) {
            settleTerminalWorkingConversation(bot: bot)
        }
    }

    public func providerChipTitle(_ provider: AgentProvider) -> String {
        switch provider {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .grok: return "Grok"
        case .distill: return "Distill"
        }
    }

    public func providerLabel(for bot: BotDefinition) -> String? {
        if bot.id == selectedBotID {
            return providerChipTitle(deskRouting.provider)
        }
        return resolvedProvider(for: bot).map(providerChipTitle)
    }

    public func resolvedProvider(for bot: BotDefinition) -> AgentProvider? {
        resolvedThreadRouting(for: bot)?.provider
    }

    private func resolvedThreadRouting(for bot: BotDefinition) -> BotDeskRouting? {
        let conversation: BotConversation?
        if selectedBotID == bot.id {
            conversation = selectedConversation
        } else if let remembered = selectedConversationByBot[bot.id] {
            conversation = studioSupportByBot[bot.id]?.conversations.first { $0.id == remembered }
        } else {
            conversation = studioSupportByBot[bot.id]?.selectedConversation
        }
        guard let conversation else { return nil }
        if let saved = deskRoutingByConversation[conversation.id] {
            return saved
        }
        return nil
    }

    private static let selectedBotDefaultsKey = "bots.selectedBotID"
    private static let inspectorTabDefaultsKey = "bots.inspectorTab"
    private static let screenDefaultsKey = "bots.screen"
    private static let studioTabDefaultsKey = "bots.studioTab"
    private static let deskSidePaneDefaultsKey = "bots.deskSidePane"
    private static let deskSidePaneWidthDefaultsKey = "bots.deskSidePaneWidth"
    private static let deskThreadRailDefaultsKey = "bots.deskThreadRail"
    private static let deskThreadRailWidthDefaultsKey = "bots.deskThreadRailWidth"
    private static let showHiddenDefaultsKey = "bots.showHidden"
    private static let brainPaneDefaultsKey = "bots.brainPane"
    private static let queuedFollowUpsDefaultsKey = "bots.queuedFollowUps"
    fileprivate static let composerDraftsDefaultsKey = "bots.composerDrafts"
    private static let deskRoutingDefaultsKey = "bots.deskThreadRouting"
    private static let legacyBotRoutingDefaultsKey = "bots.deskRouting"
    private static let peerHandoffsDefaultsKey = "bots.peerTurns.v2"
    private static let studioFilesLocationsDefaultsKey = "bots.studioFilesLocations"
    fileprivate static let inspectorDraftsDefaultsKey = "bots.inspectorDrafts"
    fileprivate static let studioDraftDefaultsKey = "bots.studioDraft"
    fileprivate static let searchTextDefaultsKey = "bots.searchText"
    private static let unpublishedNewBotDefaultsKey = "bots.unpublishedNewBotIDs"

    private func persistSelection() {
        UserDefaults.standard.set(selectedBotID?.value.uuidString.lowercased(), forKey: Self.selectedBotDefaultsKey)
    }

    private func persistInspectorTab() {
        let tab = inspectorTab.isUserFacing ? inspectorTab : .routines
        UserDefaults.standard.set(tab.rawValue, forKey: Self.inspectorTabDefaultsKey)
    }

    private func persistScreen() {
        UserDefaults.standard.set(screen.rawValue, forKey: Self.screenDefaultsKey)
    }

    private func persistStudioTab() {
        let tab = studioTab.isUserFacing ? studioTab : .profile
        UserDefaults.standard.set(tab.rawValue, forKey: Self.studioTabDefaultsKey)
    }

    private func persistDeskSidePane() {
        UserDefaults.standard.set(isDeskSidePaneVisible, forKey: Self.deskSidePaneDefaultsKey)
    }

    private func restoreDeskSidePaneIfNeeded() {
        guard UserDefaults.standard.object(forKey: Self.deskSidePaneDefaultsKey) != nil else { return }
        isDeskSidePaneVisible = UserDefaults.standard.bool(forKey: Self.deskSidePaneDefaultsKey)
    }

    public func resizeDeskSidePane(by delta: CGFloat) {
        let next = min(
            BotsChrome.desktopPaneMaxWidth,
            max(BotsChrome.desktopPaneMinWidth, deskSidePaneWidth + delta)
        )
        guard next != deskSidePaneWidth else { return }
        deskSidePaneWidth = next
    }

    private func persistDeskSidePaneWidth() {
        UserDefaults.standard.set(Double(deskSidePaneWidth), forKey: Self.deskSidePaneWidthDefaultsKey)
    }

    private func restoreDeskSidePaneWidthIfNeeded() {
        let stored = UserDefaults.standard.double(forKey: Self.deskSidePaneWidthDefaultsKey)
        guard stored > 0 else { return }
        deskSidePaneWidth = min(
            BotsChrome.desktopPaneMaxWidth,
            max(BotsChrome.desktopPaneMinWidth, CGFloat(stored))
        )
    }

    private func persistDeskThreadRail() {
        UserDefaults.standard.set(isDeskThreadRailVisible, forKey: Self.deskThreadRailDefaultsKey)
    }

    private func restoreDeskThreadRailIfNeeded() {
        guard UserDefaults.standard.object(forKey: Self.deskThreadRailDefaultsKey) != nil else { return }
        isDeskThreadRailVisible = UserDefaults.standard.bool(forKey: Self.deskThreadRailDefaultsKey)
    }

    public func resizeDeskThreadRail(by delta: CGFloat) {
        let next = BotsChrome.clampedThreadRailWidth(deskThreadRailWidth + delta)
        guard next != deskThreadRailWidth else { return }
        deskThreadRailWidth = next
    }

    private func persistDeskThreadRailWidth() {
        UserDefaults.standard.set(Double(deskThreadRailWidth), forKey: Self.deskThreadRailWidthDefaultsKey)
    }

    /// Memo for thread-rail provider · model chips: one batched listChrome
    /// per desk reload instead of one full get per row per render (the desk
    /// composer republishes this model on every keystroke).
    private var deskThreadRailRoutingCache: [AgentThreadID: BotDeskThreadRailRouting] = [:]

    /// Prefetch provider · model for linked threads so first rail paint
    /// does not compile N 26-column + routing `get`s.
    private func prefetchDeskThreadRailRouting(for conversations: [BotConversation]) {
        var missing: [AgentThreadID] = []
        missing.reserveCapacity(conversations.count)
        for conversation in conversations {
            if let threadID = conversation.linkedAgentThreadID,
               deskThreadRailRoutingCache[threadID] == nil {
                missing.append(threadID)
            }
        }
        guard !missing.isEmpty else { return }
        let chrome = (try? context.threadRepo.listChrome(ids: missing)) ?? [:]
        for (id, row) in chrome {
            deskThreadRailRoutingCache[id] = BotDeskThreadRailRouting(
                provider: row.provider,
                model: row.model
            )
        }
    }

    /// Provider · model for a desk thread row — the same chip data the
    /// Agent App rail shows. The linked run's thread wins; a never-run
    /// conversation shows what the desk would route it to today.
    public func deskThreadRailRouting(for conversation: BotConversation) -> BotDeskThreadRailRouting {
        if let threadID = conversation.linkedAgentThreadID,
           let cached = deskThreadRailRoutingCache[threadID] {
            return cached
        }
        return BotDeskThreadRailRouting(provider: deskRouting.provider, model: deskRouting.model)
    }

    /// The content column is never under the traffic lights: the sidebar
    /// owns them when open, and the 34pt restore bar owns them when
    /// collapsed. So the main shell always drops every titlebar inset —
    /// keeping .top while the sidebar is open parked the Ceo header a
    /// full titlebar below the traffic lights, and keeping .leading hung
    /// Ceo in empty padding next to the sidebar. Constant edges also
    /// keep Desk still while the sidebar toggle animates.
    static func ignoredSafeAreaEdges(
        embedsRosterRail: Bool,
        presentsAsDetachedWindow: Bool
    ) -> Edge.Set {
        if presentsAsDetachedWindow { return [] }
        if embedsRosterRail { return .top }
        return [.top, .leading, .trailing]
    }

    /// Identity row padding is the same with the sidebar open or hidden.
    /// Extra traffic-light width is cancelled on the hosting view, not added here.
    static func deskIdentityLeadingPadding(shellSidebarCollapsed: Bool) -> CGFloat {
        _ = shellSidebarCollapsed
        return DS.Space.xl
    }

    static func cancelsWindowLeadingTitlebarGutter(presentsAsDetachedWindow: Bool) -> Bool {
        !presentsAsDetachedWindow
    }

    /// How much of the window titlebar leading inset still reaches Desk.
    /// Main shell must be 0 or Ceo sits in a traffic-light-sized hole.
    static func addedLeadingInsetBeyondIdentityPadding(
        windowTitlebarLeading: CGFloat,
        presentsAsDetachedWindow: Bool
    ) -> CGFloat {
        cancelsWindowLeadingTitlebarGutter(presentsAsDetachedWindow: presentsAsDetachedWindow)
            ? 0
            : windowTitlebarLeading
    }

    private func restoreShellSidebarCollapsedIfNeeded() {
        isShellSidebarCollapsed = ((try? context.settingsRepo.get(MainWindowController.sidebarCollapsedSettingsKey)) ?? nil) == "1"
    }

    private func observeShellSidebarVisibility() {
        shellSidebarVisibilityObserver = NotificationCenter.default.addObserver(
            forName: .rc2SidebarVisibility,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let collapsed = note.userInfo?["collapsed"] as? Bool else { return }
            Task { @MainActor in
                self?.isShellSidebarCollapsed = collapsed
            }
        }
    }

    private func restoreDeskThreadRailWidthIfNeeded() {
        let stored = UserDefaults.standard.double(forKey: Self.deskThreadRailWidthDefaultsKey)
        guard stored > 0 else { return }
        deskThreadRailWidth = BotsChrome.clampedThreadRailWidth(CGFloat(stored))
    }

    private func markUnpublishedNewBot(_ id: BotID) {
        unpublishedNewBotIDs.insert(id)
        persistUnpublishedNewBotIDs()
    }

    private func clearUnpublishedNewBot(_ id: BotID) {
        guard unpublishedNewBotIDs.contains(id) else { return }
        unpublishedNewBotIDs.remove(id)
        persistUnpublishedNewBotIDs()
    }

    private func persistUnpublishedNewBotIDs() {
        let values = unpublishedNewBotIDs.map { $0.value.uuidString.lowercased() }.sorted()
        if values.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.unpublishedNewBotDefaultsKey)
        } else {
            UserDefaults.standard.set(values, forKey: Self.unpublishedNewBotDefaultsKey)
        }
    }

    private func restoreUnpublishedNewBotIDsIfNeeded() {
        let raw = UserDefaults.standard.stringArray(forKey: Self.unpublishedNewBotDefaultsKey) ?? []
        unpublishedNewBotIDs = Set(raw.compactMap { UUID(uuidString: $0).map(BotID.init) })
    }

    private func pruneUnpublishedNewBotIDs(live: Set<BotID>) {
        let next = unpublishedNewBotIDs.intersection(live)
        guard next != unpublishedNewBotIDs else { return }
        unpublishedNewBotIDs = next
        persistUnpublishedNewBotIDs()
    }

    private func flushPendingDraftPersistence() {
        draftPersistenceAuthority.flushPending()
    }

    func flushDraftPersistenceForTesting() {
        flushPendingDraftPersistence()
    }

    private func persistStudioDraftIfHydrated() {
        guard studioDraftHydrated, !isApplyingStudioDraft else { return }
        persistStudioDraft()
    }

    private func persistStudioDraft() {
        guard let botID = studioDraft.botID else { return }
        var draft = studioDraft
        draft.desktopKind = resolvedDesktopKind(draft.desktopKind)
        studioDraftsByBot[botID] = draft
        draftPersistenceAuthority.updateStudio(draft, for: botID)
    }

    private func restoreStudioDraftIfNeeded() {
        studioDraftsByBot = draftPersistenceAuthority.studioDraftsByBot
    }

    private func applyPersistedStudioDraftIfMatching(_ botID: BotID) {
        guard var saved = draftPersistenceAuthority.studioDraftsByBot[botID] else { return }
        studioDraftsByBot[botID] = saved
        saved.desktopKind = resolvedDesktopKind(saved.desktopKind)
        studioDraft = saved
    }

    private func pruneStudioDraftsToFleet(live: Set<BotID>) {
        guard draftPersistenceAuthority.retainStudioDrafts(for: live) else { return }
        studioDraftsByBot = draftPersistenceAuthority.studioDraftsByBot
        flushPendingDraftPersistence()
    }

    private func persistSearchText() {
        draftPersistenceAuthority.updateSearchText(searchText)
    }

    private func restoreSearchTextIfNeeded() {
        searchText = draftPersistenceAuthority.currentSearchText
    }

    private func persistShowHidden() {
        UserDefaults.standard.set(showHidden, forKey: Self.showHiddenDefaultsKey)
    }

    private func restoreShowHiddenIfNeeded() {
        showHidden = UserDefaults.standard.bool(forKey: Self.showHiddenDefaultsKey)
    }

    private func persistBrainPane() {
        UserDefaults.standard.set(brainPane.rawValue, forKey: Self.brainPaneDefaultsKey)
    }

    private func restoreBrainPaneIfNeeded() {
        guard let raw = UserDefaults.standard.string(forKey: Self.brainPaneDefaultsKey),
              let pane = BotBrainInspectorPane(rawValue: raw) else { return }
        brainPane = pane
    }

    private func persistQueuedFollowUps() {
        let liveIDs = Set(queuedFollowUpsByBot.keys)
        let stored = try? botStore.listAllQueuedFollowUps()
        if let stored {
            for botID in Set(stored.map(\.botID)) where !liveIDs.contains(botID) {
                try? botStore.deleteQueuedFollowUps(botID: botID)
            }
        }
        // Rewriting the queue must carry each row's own enqueue moment forward.
        // `createdAt: Date()` re-dated the rows this mutation did not touch —
        // including other teammates' — and `created_at` is what `bot.queue.list`
        // reports to the paired device.
        let queuedAtByID = Dictionary(
            (stored ?? []).map { ($0.id.lowercased(), $0.createdAt) },
            uniquingKeysWith: { first, _ in first }
        )
        let now = Date()
        for (botID, items) in queuedFollowUpsByBot {
            let records = items.enumerated().map { index, item in
                BotQueuedFollowUpRecord(
                    id: item.id.uuidString.lowercased(),
                    botID: botID,
                    conversationID: item.conversationID?.value.uuidString.lowercased(),
                    text: item.text,
                    payloadJSON: encodeQueuedFollowUpPayload(item),
                    sortOrder: index,
                    createdAt: queuedAtByID[item.id.uuidString.lowercased()] ?? now
                )
            }
            try? botStore.replaceQueuedFollowUps(botID: botID, items: records)
        }
        UserDefaults.standard.removeObject(forKey: Self.queuedFollowUpsDefaultsKey)
    }

    private func restoreQueuedFollowUpsIfNeeded() {
        let fromStore = decodeQueuedFollowUpsFromStore()
        if !fromStore.isEmpty {
            queuedFollowUpsByBot = fromStore
            return
        }
        guard let data = UserDefaults.standard.data(forKey: Self.queuedFollowUpsDefaultsKey),
              let payload = try? Self.decodeJSON([String: [BotQueuedFollowUp]].self, from: data)
        else { return }
        var restored: [BotID: [BotQueuedFollowUp]] = [:]
        for (raw, items) in payload {
            guard let uuid = UUID(uuidString: raw) else { continue }
            let kept = items.filter {
                !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !$0.attachments.isEmpty
            }
            if !kept.isEmpty {
                restored[BotID(uuid)] = kept
            }
        }
        queuedFollowUpsByBot = restored
        if !restored.isEmpty {
            persistQueuedFollowUps()
        }
    }

    private func decodeQueuedFollowUpsFromStore() -> [BotID: [BotQueuedFollowUp]] {
        guard let stored = try? botStore.listAllQueuedFollowUps() else { return [:] }
        var restored: [BotID: [BotQueuedFollowUp]] = [:]
        for record in stored {
            let item = decodeQueuedFollowUp(record)
            guard !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !item.attachments.isEmpty else { continue }
            restored[record.botID, default: []].append(item)
        }
        return restored
    }

    private func encodeQueuedFollowUpPayload(_ item: BotQueuedFollowUp) -> String {
        let payload = BotQueuedFollowUpStorePayload(
            attachments: item.attachments,
            routing: item.routing
        )
        guard let data = try? Self.encodeJSON(payload),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private func decodeQueuedFollowUp(_ record: BotQueuedFollowUpRecord) -> BotQueuedFollowUp {
        let payload = record.payloadJSON.data(using: .utf8).flatMap {
            try? Self.decodeJSON(BotQueuedFollowUpStorePayload.self, from: $0)
        }
        return BotQueuedFollowUp(
            id: UUID(uuidString: record.id) ?? UUID(),
            text: record.text,
            attachments: payload?.attachments ?? [],
            conversationID: record.conversationID.flatMap(UUID.init).map(BotConversationID.init),
            routing: payload?.routing
        )
    }

    private func pruneQueuedFollowUpsToFleet(live: Set<BotID>) {
        let next = queuedFollowUpsByBot.filter { live.contains($0.key) }
        guard next.count != queuedFollowUpsByBot.count else { return }
        queuedFollowUpsByBot = next
        persistQueuedFollowUps()
        syncQueuedFollowUps()
    }

    private func persistComposerIfHydrated() {
        guard composerHydrated, !isApplyingComposerDraft else { return }
        captureComposerDraft()
    }

    /// Create/copy dest used to reloadFleet before Chat/Studio painted.
    /// The store already returned the new row; insert it locally so dest
    /// does not list every teammate. Hide/pin/delete/reload still list.
    private func rememberFleetBot(_ bot: BotDefinition) {
        if let index = bots.firstIndex(where: { $0.id == bot.id }) {
            bots[index] = bot
        } else {
            bots.append(bot)
        }
        publishRosterIfNeeded()
    }

    /// Re-read a bot after `bot_set_settings` (or any out-of-process publish).
    /// Studio Save already calls `adoptPublishedRevision`; Desk keeps a stale
    /// `bots` row until this runs.
    @discardableResult
    public func refreshPublishedIdentity(for botID: BotID) -> BotDefinition? {
        guard let fresh = try? botStore.get(id: botID), fresh.deletedAt == nil else { return nil }
        let current = bots.first(where: { $0.id == botID })
        let unchanged = current?.currentRevisionID == fresh.currentRevisionID
            && current?.name == fresh.name
            && current?.title == fresh.title
            && current?.description == fresh.description
            && current?.avatarSymbol == fresh.avatarSymbol
            && current?.notificationsEnabled == fresh.notificationsEnabled
        if !unchanged {
            rememberFleetBot(fresh)
            if let revisionID = fresh.currentRevisionID,
               let revision = try? botStore.getRevision(id: revisionID) {
                revisionByID[revisionID] = revision
                if selectedBotID == botID {
                    selectedRevision = revision
                    if screen != .studio {
                        rememberStudioSupport(for: botID)
                    }
                }
            }
        }
        return fresh
    }

    /// Save dest used to force-reload studio support after publish.
    /// The revision is already the row; dest must not reread inspector.
    private func adoptPublishedRevision(_ revision: BotRevision, bot: BotDefinition) {
        rememberFleetBot(bot)
        revisionByID[revision.id] = revision
        selectedRevision = revision
        rememberStudioSupport(for: bot.id)
        adoptSelectedBot(bot.id)
    }

    private func adoptCreatedBot(_ bot: BotDefinition) {
        rememberFleetBot(bot)
        attentionStateByBot[bot.id] = BotAttentionState.none
        adoptSelectedBot(bot.id)
    }

    private func adoptSelectedBot(_ id: BotID?) {
        if selectedBotID == id {
            // Opening an already-selected bot is navigation, not an edit. Read
            // the AppContext authority so a stale window cannot manufacture a
            // later draft mutation merely by reopening the same teammate.
            applyComposerDraft(for: id)
            applyInspectorDraft(for: id)
            if deskRoutingHydrated {
                captureDeskRouting()
            } else {
                applyDeskRouting(
                    for: selectedConversation,
                    allowStoreLookup: !navigationFirstFrameDeferral
                )
            }
            return
        }
        // Draft field didSets update the AppContext authority immediately.
        // Recapturing here would let a stale window replace a newer window's
        // draft merely by navigating to another teammate.
        if deskRoutingHydrated {
            captureDeskRouting()
        }
        if let threadID = selectedConversation?.linkedAgentThreadID {
            clearDeskObservedEvents(threadID: threadID)
        }
        flushPendingDraftPersistence()
        selectedBotID = id
        publishRosterIfNeeded()
        applyComposerDraft(for: id)
        applyInspectorDraft(for: id)
    }

    private func captureComposerDraft(for botID: BotID? = nil) {
        guard let botID = botID ?? selectedBotID else { return }
        let draft = BotComposerDraft(text: composerText, attachments: attachments)
        if draft.isEmpty {
            composerDraftsByBot[botID] = nil
        } else {
            composerDraftsByBot[botID] = draft
        }
        draftPersistenceAuthority.updateComposer(draft, for: botID)
    }

    private func applyComposerDraft(for botID: BotID?) {
        let draft = botID.flatMap { draftPersistenceAuthority.composerDraftsByBot[$0] }
        if let botID {
            composerDraftsByBot[botID] = draft
        }
        isApplyingComposerDraft = true
        composerText = draft?.text ?? ""
        composerCursorOffset = nil
        attachments = draft?.liveAttachments ?? []
        isApplyingComposerDraft = false
        composerHydrated = true
    }

    public func setDeskProvider(_ provider: AgentProvider, instanceID: String? = nil) {
        let instance = instanceID
            ?? providers.first(where: { $0.provider == provider })?.id
            ?? provider.rawValue
        deskRouting.provider = provider
        deskRouting.providerInstanceID = instance
        if provider == .distill {
            deskRouting.routingMode = .manual
        }
        if deskRouting.routingMode == .auto {
            deskRouting.model = ""
        } else if !deskModels.contains(where: { $0.id == deskRouting.model }) {
            deskRouting.model = Self.defaultModel(for: provider)
        }
        normalizeDeskReasoning()
    }

    public func setDeskModel(_ model: String) {
        deskRouting.model = model
        deskRouting.routingMode = .manual
        normalizeDeskReasoning()
    }

    public func setDeskReasoningModel(_ model: String?) {
        let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let selectedModel = trimmed.isEmpty ? nil : trimmed
        var updated = deskRouting
        if selectedModel == nil {
            updated.distillReasoningEffortSelection = .automatic
        }
        updated.reasoningModel = selectedModel
        guard persistDeskThreadModelSelection(updated) else { return }
        deskRouting = updated
    }

    public func setDeskRoutingMode(_ mode: AgentRoutingMode) {
        let resolvedMode: AgentRoutingMode = deskRouting.provider == .distill ? .manual : mode
        deskRouting.routingMode = resolvedMode
        if resolvedMode == .auto {
            deskRouting.model = ""
        } else if deskRouting.model.isEmpty {
            deskRouting.model = Self.defaultModel(for: deskRouting.provider)
        }
        normalizeDeskReasoning()
    }

    public func setDeskPermissionMode(_ mode: AgentPermissionMode) {
        deskRouting.permissionMode = mode
    }

    public func setDeskRunAsUser(_ user: AgentRunAsUser) {
        deskRouting.runAsUser = user
    }

    public func refreshAvailableRunAsUsers() {
        availableRunAsUsers = MacOSLocalUserCatalog.listEligibleUsers()
    }

    public var deskDistillMainEffortSelection: AgentEffortSelection {
        if let selection = deskRouting.distillMainEffortSelection { return selection }
        return deskSupportedReasoning.isEmpty ? .automatic : .fixed(deskRunReasoning)
    }

    public var deskDistillReasoningEffortSelection: AgentEffortSelection {
        deskRouting.distillReasoningEffortSelection ?? .automatic
    }

    public var deskDistillReasoningEfforts: [AgentReasoningEffort] {
        guard let reasoningModel = deskRouting.reasoningModel else { return [] }
        return deskModels.first(where: { $0.id == reasoningModel })?.supportedReasoningEfforts
            ?? DistillReasoningPolicy.supportedEfforts(for: reasoningModel)
    }

    public var deskDistillEffortValidationMessage: String? {
        guard deskRouting.provider == .distill else { return nil }
        let mainSelection = deskDistillMainEffortSelection
        if let effort = mainSelection.effort,
           !deskSupportedReasoning.isEmpty,
           !deskSupportedReasoning.contains(effort) {
            return "Main effort \(effort.displayName) is unavailable for the selected Distill model. Choose Auto or a supported effort."
        }
        if mainSelection.isAutomatic, !deskSupportsDistillMainEffortAuto {
            return "Update the Distill ACP harness to apply Auto Main effort."
        }
        if let reasoningModel = deskRouting.reasoningModel,
           let effort = deskDistillReasoningEffortSelection.effort {
            if !deskDistillReasoningEfforts.isEmpty, !deskDistillReasoningEfforts.contains(effort) {
                return "Worker effort \(effort.displayName) is unavailable for \(reasoningModel). Choose Auto or a supported effort."
            }
            if !deskSupportsDistillReasoningModelEffort {
                return "Update the Distill ACP harness to apply a separate Worker-model effort."
            }
        }
        return nil
    }

    public var deskSupportsDistillMainEffortAuto: Bool {
        let snapshot = providers.first(where: {
            $0.provider == deskRouting.provider && $0.id == deskRouting.providerInstanceID
        }) ?? providers.first { $0.provider == deskRouting.provider }
        return snapshot?.effectiveCapabilities.supportsDistillMainEffortAuto == true
    }

    public var deskSupportsDistillReasoningModelEffort: Bool {
        let snapshot = providers.first(where: {
            $0.provider == deskRouting.provider && $0.id == deskRouting.providerInstanceID
        }) ?? providers.first { $0.provider == deskRouting.provider }
        return snapshot?.effectiveCapabilities.supportsDistillReasoningModelEffort == true
    }

    public func setDeskDistillMainEffortSelection(_ selection: AgentEffortSelection) {
        guard deskRouting.provider == .distill else { return }
        if selection.isAutomatic, !deskSupportsDistillMainEffortAuto {
            errorMessage = "Update the Distill ACP session to enable Auto Main effort."
            return
        }
        if let effort = selection.effort,
           !deskSupportedReasoning.isEmpty,
           !deskSupportedReasoning.contains(effort) { return }
        var updated = deskRouting
        if let effort = selection.effort { updated.reasoningEffort = effort }
        updated.distillMainEffortSelection = selection
        updated.routingMode = .manual
        guard persistDeskThreadModelSelection(updated) else { return }
        deskRouting = updated
    }

    public func setDeskDistillReasoningEffortSelection(_ selection: AgentEffortSelection) {
        guard deskRouting.provider == .distill,
              deskSupportsDistillReasoningModelEffort,
              deskRouting.reasoningModel != nil else { return }
        if let effort = selection.effort,
           !deskDistillReasoningEfforts.isEmpty,
           !deskDistillReasoningEfforts.contains(effort) { return }
        var updated = deskRouting
        updated.distillReasoningEffortSelection = selection
        guard persistDeskThreadModelSelection(updated) else { return }
        deskRouting = updated
    }

    public func setDeskReasoningEffort(_ effort: AgentReasoningEffort) {
        if deskRouting.provider == .distill {
            setDeskDistillMainEffortSelection(.fixed(effort))
            return
        }
        let supported = deskSupportedReasoning
        deskRouting.reasoningEffort = supported.contains(effort) ? effort : (supported.first ?? .medium)
        deskRouting.routingMode = .manual
    }

    @discardableResult
    private func persistDeskThreadModelSelection(_ routing: BotDeskRouting) -> Bool {
        guard let threadID = selectedConversation?.linkedAgentThreadID else { return true }
        do {
            guard var thread = try context.threadRepo.get(id: threadID) else { return false }
            thread.reasoningModel = routing.reasoningModel
            thread.reasoningEffort = routing.reasoningEffort
            thread.modelSelection = routing.modelSelection
            try context.threadRepo.upsert(thread)
            return true
        } catch {
            errorMessage = "Could not save Distill model settings: \(error)"
            return false
        }
    }

    public var botMentionSuggestions: [BotDefinition] {
        guard let query = BotMentionParser.activeQuery(in: composerText) else { return [] }
        return BotMentionParser.suggestions(query: query, bots: bots, excluding: selectedBotID)
    }

    func replaceProvidersForTests(_ snapshots: [AgentProviderSnapshot]) {
        providers = snapshots
    }

    /// Cheap user-catalog fingerprint used on every composer reevaluation. Entry
    /// add/remove/rename mutates the parent directory metadata, invalidating the
    /// expensive recursive discovery without rescanning it on each keystroke.
    nonisolated static func claudeSlashCatalogRevision(home: String) -> String {
        let claudeRoot = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".claude", isDirectory: true)
        return ["skills", "commands"].map { component in
            let path = claudeRoot.appendingPathComponent(component, isDirectory: true).path
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
                return "missing"
            }
            let modificationNanoseconds = (attributes[.modificationDate] as? Date).map {
                Int64(($0.timeIntervalSince1970 * 1_000_000_000).rounded())
            } ?? 0
            let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            return "\(fileNumber):\(modificationNanoseconds)"
        }.joined(separator: "|")
    }

    private static let claudeSlashCacheTTL: TimeInterval = 1

    /// Bots have no project cwd, so Claude discovery is user-scoped. Cache it
    /// while the catalog fingerprint and short freshness bound are stable.
    /// The bound also retries empty/error results and catches nested manifest
    /// changes that do not mutate the top-level skills directory metadata.
    private func claudeSlashEntries() -> [String] {
        let home = ProcessInfo.processInfo.environment["HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        let revision = claudeSlashCatalogRevisionForTesting?(home)
            ?? Self.claudeSlashCatalogRevision(home: home)
        let now = claudeSlashCacheTimeForTesting?()
            ?? ProcessInfo.processInfo.systemUptime
        if let cached = cachedClaudeSlashEntries,
           cached.home == home,
           cached.revision == revision,
           now >= cached.refreshedAt,
           now - cached.refreshedAt < Self.claudeSlashCacheTTL {
            return cached.entries
        }
        let entries = claudeSlashDiscoveryForTesting?(home)
            ?? ClaudeSlashCommandDiscovery.discover(cwd: nil, home: home)
        cachedClaudeSlashEntries = (home, revision, now, entries)
        return entries
    }

    public var composerSuggestions: [AgentComposerSuggestion] {
        let snapshot = selectedDeskSnapshot
        let isClaude = snapshot?.provider == .claude || deskRouting.provider == .claude
        // F1 parity with AgentAppViewModel: the composer bar reevaluates this on
        // every keystroke and every publish behind the Desk TimelineView. Plain
        // text can never consume the disk-backed catalog, so its fingerprint
        // (two filesystem stats) must not be read before `suggestions` can
        // short-circuit on the same token.
        let token = AgentComposerSuggestions.activeToken(
            in: composerText,
            cursorOffset: composerCursorOffset
        )
        let trigger = token.first
        let listsCatalog = trigger == "/" || trigger == "$"
        return AgentComposerSuggestions.suggestions(
            for: composerText,
            cursorOffset: composerCursorOffset,
            snapshot: snapshot,
            localSlashCommands: [],
            extraCommands: isClaude ? ClaudeSlashCommandDiscovery.builtInClaudeCommands : [],
            extraSkillNames: isClaude && listsCatalog ? claudeSlashEntries() : [],
            mentionableBots: bots.filter { $0.id != selectedBotID }
        )
    }

    public func applyComposerSuggestion(_ suggestion: AgentComposerSuggestion) {
        composerText = AgentComposerSuggestions.replacingActiveToken(
            in: composerText,
            cursorOffset: composerCursorOffset,
            with: suggestion.insertText
        )
    }

    public func applyBotMention(_ bot: BotDefinition) {
        composerText = BotMentionParser.applying(bot, to: composerText)
    }

    public func mentionedBots(in text: String) -> [BotDefinition] {
        BotMentionParser.mentionedBots(in: text, bots: bots, excluding: selectedBotID)
    }

    private func deskRunAsMatches(_ thread: AgentThread) -> Bool {
        let actual = thread.runAsUser ?? AgentRunAsUser.current()
        return actual.id == deskRunAsUser.id
    }

    public var deskRunProvider: AgentProvider { deskRouting.provider }

    public var deskRunModel: String {
        deskRouting.resolvedModel(defaultModel: Self.defaultModel(for:))
    }

    public var deskRunReasoning: AgentReasoningEffort {
        let supported = deskSupportedReasoning
        if supported.isEmpty { return deskRouting.reasoningEffort }
        return supported.contains(deskRouting.reasoningEffort)
            ? deskRouting.reasoningEffort
            : (supported.contains(.high) ? .high : (supported.first ?? .medium))
    }

    public var deskRunPermissionMode: AgentPermissionMode { deskRouting.permissionMode }

    public var selectedDeskSnapshot: AgentProviderSnapshot? {
        providers.first(where: { $0.id == deskRouting.providerInstanceID })
            ?? providers.first(where: { $0.provider == deskRouting.provider })
    }

    public var deskModels: [AgentModelDescriptor] {
        let snapshot = selectedDeskSnapshot
        let optionProvider = snapshot?.provider ?? deskRouting.provider
        let snapshotModels = snapshot?.models.filter { $0.provider == optionProvider } ?? []
        if !snapshotModels.isEmpty { return snapshotModels }
        return [AgentModelDescriptor(id: Self.defaultModel(for: optionProvider), label: Self.defaultModel(for: optionProvider), provider: optionProvider)]
    }

    public var deskModelDisplayLabel: String {
        if deskRouting.routingMode == .auto, deskRouting.provider != .distill { return "Auto" }
        let id = deskRunModel
        if deskRouting.provider == .distill, id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Select Main model"
        }
        return deskModels.first(where: { $0.id == id })?.label ?? id
    }

    public var deskSelectedModel: AgentModelDescriptor? {
        deskModels.first(where: { $0.id == deskRunModel })
    }

    public var deskSupportedReasoning: [AgentReasoningEffort] {
        if deskRouting.provider == .grok {
            return GrokReasoningPolicy.supportedEfforts(for: deskRunModel)
        }
        return deskSelectedModel?.supportedReasoningEfforts ?? []
    }

    public var deskSupportsReasoning: Bool {
        !deskSupportedReasoning.isEmpty
    }

    private func normalizeDeskReasoning() {
        if deskRouting.provider == .distill {
            deskRouting.routingMode = .manual
        }
        let supported = deskSupportedReasoning
        if !supported.isEmpty, !supported.contains(deskRouting.reasoningEffort) {
            deskRouting.reasoningEffort = supported.contains(.high) ? .high : (supported.first ?? .medium)
        }
        if deskRouting.provider == .distill {
            if deskRouting.distillMainEffortSelection == nil {
                deskRouting.distillMainEffortSelection = supported.isEmpty
                    ? .automatic
                    : .fixed(deskRouting.reasoningEffort)
            }
            if deskRouting.reasoningModel == nil {
                deskRouting.distillReasoningEffortSelection = .automatic
            }
        }
    }

    public var deskPermissionModes: [AgentPermissionMode] {
        selectedDeskSnapshot?.effectivePermissionModes ?? AgentPermissionMode.allCases
    }

    private func persistDeskRoutingIfHydrated() {
        guard deskRoutingHydrated, !isApplyingDeskRouting else { return }
        captureDeskRouting()
    }

    private func captureDeskRouting(for conversationID: BotConversationID? = nil) {
        guard let conversationID = conversationID ?? selectedConversation?.id else { return }
        deskRoutingByConversation[conversationID] = deskRouting
        persistDeskRouting()
    }

    private func applyDeskRouting(
        for conversation: BotConversation?,
        allowStoreLookup: Bool = true
    ) {
        let priorRouting = deskRouting
        isApplyingDeskRouting = true
        if let conversation, let saved = deskRoutingByConversation[conversation.id] {
            if deskRouting != saved {
                deskRouting = saved
            }
        } else if allowStoreLookup,
                  let threadID = conversation?.linkedAgentThreadID,
                  let thread = try? context.threadRepo.get(id: threadID) {
            deskRouting = BotDeskRouting(thread: thread)
        } else {
            let fallback = BotDeskRouting()
            if deskRouting != fallback {
                deskRouting = fallback
            }
        }
        normalizeDeskReasoning()
        let routingChanged = priorRouting != deskRouting
        isApplyingDeskRouting = false
        deskRoutingHydrated = true
        if routingChanged, let conversationID = conversation?.id {
            captureDeskRouting(for: conversationID)
        }
    }

    private func persistDeskRouting() {
        let payload = Dictionary(uniqueKeysWithValues: deskRoutingByConversation.map {
            ($0.key.value.uuidString.lowercased(), $0.value)
        })
        if payload.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.deskRoutingDefaultsKey)
            return
        }
        if let data = try? Self.encodeJSON(payload) {
            UserDefaults.standard.set(data, forKey: Self.deskRoutingDefaultsKey)
        }
    }

    private func restoreDeskRoutingIfNeeded() {
        // Bot-keyed routing was the defect: it made the callee choose the
        // provider. Never migrate that state into a thread.
        UserDefaults.standard.removeObject(forKey: Self.legacyBotRoutingDefaultsKey)
        guard let data = UserDefaults.standard.data(forKey: Self.deskRoutingDefaultsKey),
              let payload = try? Self.decodeJSON([String: BotDeskRouting].self, from: data)
        else { return }
        var restored: [BotConversationID: BotDeskRouting] = [:]
        for (raw, routing) in payload {
            guard let uuid = UUID(uuidString: raw) else { continue }
            restored[BotConversationID(uuid)] = routing
        }
        deskRoutingByConversation = restored
    }

    private func peerAttribution(forUserText text: String, hostID: BotID) -> BotDeskPeer? {
        guard !BotPeerTranscript.isHostHopUserText(text),
              let peer = mentionedBots(in: text).first else { return nil }
        return BotDeskPeer(direction: .messaged, bot: peer)
    }

    private func resolvedPeerAvatarSymbol(botID: BotID, stored: String?) -> String {
        if let stored, !stored.isEmpty { return stored }
        return bots.first(where: { $0.id == botID })?.avatarSymbol ?? ""
    }

    private func deskPeer(
        direction: BotDeskPeer.Direction,
        botID: BotID,
        name: String,
        title: String,
        handle: String,
        avatarSymbol: String? = nil,
        activityPhase: BotPeerActivityPhase? = nil
    ) -> BotDeskPeer {
        BotDeskPeer(
            direction: direction,
            botID: botID,
            name: name,
            title: title,
            handle: handle,
            avatarSymbol: resolvedPeerAvatarSymbol(botID: botID, stored: avatarSymbol),
            activityPhase: activityPhase
        )
    }

    private func updatePeerActivity(
        originConversationID: BotConversationID,
        messageID: UUID,
        phase: BotPeerActivityPhase?
    ) {
        func update(_ messages: inout [BotDeskMessage]) {
            guard let index = messages.firstIndex(where: { $0.id == messageID }),
                  messages[index].peer?.direction == .messaged else { return }
            messages[index].peer?.activityPhase = phase
        }

        guard let handoff = peerHandoffs[messageID],
              handoff.originConversationID == originConversationID,
              let hostID = handoff.originBotID else { return }
        if var messages = messagesByConversation[originConversationID] {
            update(&messages)
            messagesByConversation[originConversationID] = messages
        }
        if var messages = messagesByBot[hostID],
           messagesConversationIDByBot[hostID] == originConversationID {
            update(&messages)
            messagesByBot[hostID] = messages
        }
        if selectedBotID == hostID, selectedConversation?.id == originConversationID {
            update(&deskMessages)
        }
    }

    private func hostSidePeerTurns(_ handoff: PersistedBotPeerHandoff) -> [BotDeskMessage] {
        let peer = deskPeer(
            direction: .messaged,
            botID: handoff.peerBotID,
            name: handoff.peerName,
            title: handoff.peerTitle,
            handle: handoff.peerHandle,
            avatarSymbol: handoff.peerAvatarSymbol,
            activityPhase: handoff.phase == .needsAttention
                ? .needsAttention
                : (handoff.replyText == nil ? .waiting : nil)
        )
        var turns = [BotDeskMessage(
            id: handoff.activityID,
            role: .user,
            text: handoff.outboundText,
            createdAt: handoff.createdAt,
            peer: peer
        )]
        if let reply = handoff.replyText {
            turns.append(BotDeskMessage(
                id: handoff.inboundMessageID,
                role: .assistant,
                text: reply,
                createdAt: handoff.replyCreatedAt ?? handoff.createdAt,
                peer: deskPeer(
                    direction: .fromPeer,
                    botID: handoff.peerBotID,
                    name: handoff.peerName,
                    title: handoff.peerTitle,
                    handle: handoff.peerHandle,
                    avatarSymbol: handoff.peerAvatarSymbol
                )
            ))
        }
        return turns
    }

    private func askedBotPeerTurns(_ handoff: PersistedBotPeerHandoff) -> [BotDeskMessage] {
        let originPeer: BotDeskPeer?
        if let originID = handoff.originBotID {
            let origin = bots.first(where: { $0.id == originID })
            originPeer = deskPeer(
                direction: .fromPeer,
                botID: originID,
                name: origin?.name ?? "Bot",
                title: origin?.title ?? "",
                handle: origin?.handle ?? "",
                avatarSymbol: origin?.avatarSymbol
            )
        } else {
            originPeer = nil
        }
        return [BotDeskMessage(
            id: handoff.activityID,
            role: .user,
            text: handoff.outboundText,
            createdAt: handoff.createdAt,
            peer: originPeer
        )]
    }

    private func mergePeerTurns(
        _ messages: [BotDeskMessage],
        conversationID: BotConversationID?
    ) -> [BotDeskMessage] {
        guard let conversationID else { return messages }
        let extras = peerHandoffs.values
            .flatMap { handoff -> [BotDeskMessage] in
                if handoff.originConversationID == conversationID {
                    return hostSidePeerTurns(handoff)
                }
                if handoff.peerConversationID == conversationID {
                    return askedBotPeerTurns(handoff)
                }
                return []
            }
        guard !extras.isEmpty else { return messages }
        var merged = messages
        for extra in extras where !merged.contains(where: {
            $0.id == extra.id || (
                $0.role == extra.role
                    && $0.text == extra.text
                    && $0.createdAt == extra.createdAt
                    && $0.peer?.direction == extra.peer?.direction
                    && $0.peer?.botID == extra.peer?.botID
            )
        }) {
            merged.append(extra)
        }
        return merged.sorted { $0.createdAt < $1.createdAt }
    }

    func lastAssistantText(for botID: BotID) -> String? {
        let rows = botID == selectedBotID ? deskMessages : (messagesByBot[botID] ?? [])
        if let text = rows.last(where: {
            $0.role == .assistant
                && $0.text != BotsDeskFollowThrough.workingPlaceholder
                && $0.text != BotsViewModel.assistantPlaceholder
        })?.text, !text.isEmpty {
            return text
        }
        let threadID = conversationForBot(botID)?.linkedAgentThreadID
            ?? lastStartedConversationByBot[botID]?.linkedAgentThreadID
        guard let threadID,
              let stored = try? context.messageRepo.listRecent(threadId: threadID, limit: 80),
              let last = stored.last(where: {
                  $0.role == .assistant && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }) else {
            return nil
        }
        return last.content
    }

    public func lastAssistantTextForTesting(botID: BotID) -> String? {
        lastAssistantText(for: botID)
    }

    public func deskTranscriptForTesting(botID: BotID) -> [BotDeskMessage] {
        botID == selectedBotID ? deskMessages : (messagesByBot[botID] ?? [])
    }

    @discardableResult
    private func persistPeerHandoffs() -> Bool {
        context.botPeerHandoffAuthority.replaceSnapshot(peerHandoffs)
    }

    private func restorePeerHandoffsIfNeeded() {
        peerHandoffs = context.botPeerHandoffAuthority.snapshot()
    }

    private func activeBotIDs(for handoff: PersistedBotPeerHandoff) -> Set<BotID> {
        switch handoff.phase {
        case .peerPrepared, .peerRunning:
            return Set([handoff.originBotID, Optional(handoff.peerBotID)].compactMap { $0 })
        case .peerCompleted, .hostPrepared, .hostRunning:
            return Set([handoff.originBotID].compactMap { $0 })
        case .completed, .needsAttention:
            return []
        }
    }

    private func activeHandoffBotIDs() -> Set<BotID> {
        let activeHandoffs = peerHandoffs.values.compactMap { handoff -> (PersistedBotPeerHandoff, Set<BotID>)? in
            let botIDs = activeBotIDs(for: handoff)
            return botIDs.isEmpty ? nil : (handoff, botIDs)
        }
        let originConversationIDs = Set(activeHandoffs.compactMap { $0.0.originConversationID })
        let existingOrigins = (try? botStore.conversations(ids: originConversationIDs)) ?? [:]
        return activeHandoffs.reduce(into: Set<BotID>()) { result, item in
            if let conversationID = item.0.originConversationID,
               existingOrigins[conversationID] == nil {
                return
            }
            result.formUnion(item.1)
        }
    }

    private func setHandoffPhase(_ activityID: UUID, _ phase: BotPeerHandoffPhase) {
        guard let previous = peerHandoffs[activityID] else { return }
        var handoff = previous
        handoff.phase = phase
        peerHandoffs[activityID] = handoff
        if !persistPeerHandoffs() {
            peerHandoffs[activityID] = previous
            errorMessage = "The bot handoff state could not be saved."
            return
        }
        if phase == .needsAttention {
            if let peerRunID = handoff.peerRunID, armedRunIDs.contains(peerRunID) {
                cancelExactRunWait(peerRunID)
            }
            if let hostRunID = handoff.hostRunID, armedRunIDs.contains(hostRunID) {
                cancelExactRunWait(hostRunID)
            }
        }
        if let conversationID = handoff.originConversationID {
            let activity: BotPeerActivityPhase?
            switch phase {
            case .needsAttention: activity = .needsAttention
            case .peerPrepared, .peerRunning: activity = .waiting
            default: activity = nil
            }
            updatePeerActivity(
                originConversationID: conversationID,
                messageID: activityID,
                phase: activity
            )
        }
        if screen == .activeBots {
            reloadActiveBotsScreen()
        }
    }

    private func exactAssistantMessage(threadID: AgentThreadID, runID: AgentRunID) -> AgentMessage? {
        guard let checkpoint = (try? context.turnCheckpointRepo.list(threadId: threadID))?
            .last(where: { $0.runId == runID }),
              checkpoint.threadId == threadID,
              let messageID = checkpoint.assistantMessageId,
              let message = try? context.messageRepo.get(id: messageID),
              message.threadId == threadID,
              message.role == .assistant,
              !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return message
    }

    func reconcilePeerHandoffsForTesting() {
        context.botPeerHandoffAuthority.reconcilePeerHandoffsForTesting()
    }

    func peerHandoffSnapshotsForTesting(
        originConversationID: BotConversationID? = nil,
        originThreadID: AgentThreadID? = nil
    ) -> [BotPeerHandoffSnapshot] {
        peerHandoffs.values
            .filter {
                (originConversationID == nil || $0.originConversationID == originConversationID)
                    && (originThreadID == nil || $0.originAgentThreadID == originThreadID)
            }
            .sorted { $0.createdAt < $1.createdAt }
            .map {
                BotPeerHandoffSnapshot(
                    activityID: $0.activityID,
                    consultationID: $0.consultationID,
                    originBotID: $0.originBotID,
                    originConversationID: $0.originConversationID,
                    originThreadID: $0.originAgentThreadID,
                    peerBotID: $0.peerBotID,
                    peerConversationID: $0.peerConversationID,
                    peerThreadID: $0.peerThreadID,
                    peerRunID: $0.peerRunID,
                    inboundMessageID: $0.inboundMessageID,
                    outboundText: $0.outboundText,
                    hostInstructionText: $0.resolvedHostInstructionText,
                    hostThreadID: $0.hostThreadID,
                    hostRunID: $0.hostRunID,
                    phase: $0.phase,
                    peerProvider: $0.peerRoute.provider,
                    peerModel: $0.peerRoute.model,
                    hostProvider: $0.hostRoute?.provider,
                    hostModel: $0.hostRoute?.model
                )
            }
    }

    private func persistStudioFilesLocations() {
        let payload = Dictionary(uniqueKeysWithValues: studioFilesLocationsByBot.map {
            ($0.key.value.uuidString.lowercased(), $0.value)
        })
        if payload.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.studioFilesLocationsDefaultsKey)
        } else if let data = try? Self.encodeJSON(payload) {
            UserDefaults.standard.set(data, forKey: Self.studioFilesLocationsDefaultsKey)
        }
    }

    private func restoreStudioFilesLocationsIfNeeded() {
        guard let data = UserDefaults.standard.data(forKey: Self.studioFilesLocationsDefaultsKey),
              let payload = try? Self.decodeJSON([String: BotStudioFilesLocation].self, from: data)
        else { return }
        studioFilesLocationsByBot = Dictionary(uniqueKeysWithValues: payload.compactMap { raw, location in
            guard let uuid = UUID(uuidString: raw) else { return nil }
            return (BotID(uuid), location)
        })
    }

    private func restoreComposerDraftsIfNeeded() {
        composerDraftsByBot = draftPersistenceAuthority.composerDraftsByBot
    }

    private func pruneComposerDraftsToFleet(live: Set<BotID>) {
        guard draftPersistenceAuthority.retainComposerDrafts(for: live) else { return }
        composerDraftsByBot = draftPersistenceAuthority.composerDraftsByBot
        flushPendingDraftPersistence()
    }

    private func persistInspectorIfHydrated() {
        guard inspectorHydrated, !isApplyingInspectorDraft else { return }
        captureInspectorDraft()
    }

    private func captureInspectorDraft(for botID: BotID? = nil) {
        guard let botID = botID ?? selectedBotID else { return }
        let draft = BotInspectorDraft(
            memoryDraft: memoryDraft,
            skillDraft: skillDraft,
            routineName: routineName,
            routinePrompt: routinePrompt,
            routineScheduleNote: routineScheduleNote,
            routineSpec: routineSpec
        )
        if draft.isEmpty {
            inspectorDraftsByBot[botID] = nil
        } else {
            inspectorDraftsByBot[botID] = draft
        }
        draftPersistenceAuthority.updateInspector(draft, for: botID)
    }

    private func applyInspectorDraft(for botID: BotID?) {
        let saved = botID.flatMap { draftPersistenceAuthority.inspectorDraftsByBot[$0] }
        if let botID {
            inspectorDraftsByBot[botID] = saved
        }
        let draft = saved ?? BotInspectorDraft()
        isApplyingInspectorDraft = true
        memoryDraft = draft.memoryDraft
        skillDraft = draft.skillDraft
        routineName = draft.routineName
        routinePrompt = draft.routinePrompt
        routineScheduleNote = draft.routineScheduleNote
        routineSpec = draft.routineSpec ?? BotScheduleSpec()
        isApplyingInspectorDraft = false
        inspectorHydrated = true
    }

    func resetDraftPersistenceMetricsForTesting() {
        draftPersistenceAuthority.resetMetricsForTesting()
    }

    var draftPersistenceMetricsForTesting: BotDraftPersistenceMetrics {
        draftPersistenceAuthority.metricsForTesting
    }

    private func restoreInspectorDraftsIfNeeded() {
        inspectorDraftsByBot = draftPersistenceAuthority.inspectorDraftsByBot
    }

    private func pruneInspectorDraftsToFleet(live: Set<BotID>) {
        guard draftPersistenceAuthority.retainInspectorDrafts(for: live) else { return }
        inspectorDraftsByBot = draftPersistenceAuthority.inspectorDraftsByBot
        flushPendingDraftPersistence()
    }

    private func restoreInspectorTabIfNeeded() {
        guard let raw = UserDefaults.standard.string(forKey: Self.inspectorTabDefaultsKey) else { return }
        // Brain / Memory left the inspector strip; leftover persists follow Routines.
        if raw == "brain" || raw == "memory" {
            inspectorTab = .routines
            return
        }
        guard let tab = BotDeskInspectorTab(rawValue: raw) else { return }
        inspectorTab = tab.isUserFacing ? tab : .routines
    }

    private func restoreStudioTabIfNeeded() {
        guard let raw = UserDefaults.standard.string(forKey: Self.studioTabDefaultsKey) else { return }
        // The Desktop tab merged into Security; leftover persists follow it.
        if raw == "desktop" {
            studioTab = .security
            return
        }
        // Brain left the Studio strip; leftover persists follow Profile.
        if raw == "brain" {
            studioTab = .profile
            return
        }
        if raw == "memory" || raw == "skills" {
            studioTab = .files
            return
        }
        guard let tab = BotStudioTab(rawValue: raw) else { return }
        studioTab = tab.isUserFacing ? tab : .profile
    }

    private func restoreScreenIfNeeded() {
        guard let raw = UserDefaults.standard.string(forKey: Self.screenDefaultsKey),
              let saved = BotsScreen(rawValue: raw) else { return }
        let persistedSelection = UserDefaults.standard.string(forKey: Self.selectedBotDefaultsKey)
        let selectionMatches = selectedBotID?.value.uuidString.lowercased() == persistedSelection
        switch saved.resolvedDestination {
        case .studio:
            guard selectionMatches, let bot = selectedBot else {
                screen = .desk
                return
            }
            let tab = studioTab
            beginEdit(bot)
            studioTab = tab
        case .activeBots:
            screen = .activeBots
            reloadActiveBotsScreen()
        case .scheduleTasks:
            screen = .scheduleTasks
            reloadScheduleTasks()
        case .desk, .fleet, .attention:
            if selectionMatches, let bot = selectedBot {
                openDesk(bot)
            } else {
                screen = .desk
            }
        }
    }

    private func restoreSelectedBotIfNeeded() {
        // Persist lookup must use `bots` (hidden filter only), not `fleet`
        // (search). Otherwise a restored search drops the open teammate
        // and Chat jumps to the first match.
        if let selectedBotID, bots.contains(where: { $0.id == selectedBotID }) {
            if !composerHydrated {
                applyComposerDraft(for: selectedBotID)
            }
            if !inspectorHydrated {
                applyInspectorDraft(for: selectedBotID)
            }
            return
        }
        if let raw = UserDefaults.standard.string(forKey: Self.selectedBotDefaultsKey),
           let uuid = UUID(uuidString: raw),
           bots.contains(where: { $0.id == BotID(uuid) }) {
            adoptSelectedBot(BotID(uuid))
            return
        }
        adoptSelectedBot(fleet.first?.id)
    }

    public var liveMemoryCount: Int {
        memoryItems.filter { $0.forgottenAt == nil }.count
    }

    public var enabledSkillCount: Int {
        skillBindings.filter(\.enabled).count
    }

    public var enabledRoutineCount: Int {
        routines.filter(\.activation.isEnabled).count
    }

    public var pendingApprovalCount: Int {
        attentionItems.filter { $0.acknowledgedAt == nil && $0.kind == .approval && $0.botID == selectedBotID }.count
    }

    private func reloadMemory(botID: BotID) {
        do {
            memoryListCountForTesting += 1
            memoryItems = try botStore.listMemory(botID: botID)
            rememberStudioSupport(for: botID)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func reloadContextReceipt(botID: BotID) {
        do {
            if let conversationID = selectedConversation?.id,
               let receipt = try botStore.latestContextReceipt(botID: botID, conversationID: conversationID) {
                lastContextReceipt = receipt
            } else {
                lastContextReceipt = try botStore.latestContextReceipt(botID: botID)
            }
            rememberStudioSupport(for: botID)
        } catch {
            lastContextReceipt = nil
        }
    }

    private func studioPreviewBot() -> BotDefinition? {
        if let selectedBot { return selectedBot }
        let handle = BotHandle.normalize(studioDraft.handle) ?? "draft"
        return BotDefinition(
            handle: handle,
            name: studioDraft.name,
            title: studioDraft.title,
            description: studioDraft.description,
            avatarSymbol: studioDraft.avatarSymbol
        )
    }

    private func studioPreviewRevision(for bot: BotDefinition) -> BotRevision? {
        let draft = BotRevisionDraft(
            name: studioDraft.name,
            title: studioDraft.title,
            description: studioDraft.description,
            soul: studioDraft.soul,
            permissionMode: .supervised,
            desktopKind: resolvedDesktopKind(studioDraft.desktopKind)
        )
        if screen != .studio, let selectedRevision { return selectedRevision }
        return BotRevision(
            id: selectedRevision?.id ?? BotRevisionID(),
            botID: bot.id,
            revisionNumber: selectedRevision?.revisionNumber ?? 0,
            name: draft.name,
            title: draft.title,
            description: draft.description,
            soul: draft.soul,
            permissionMode: draft.permissionMode,
            desktopKind: draft.desktopKind,
            digest: BotRevision.digest(botID: bot.id, draft: draft),
            publishedAt: selectedRevision?.publishedAt ?? Date(),
            supersedesRevisionID: selectedRevision?.id
        )
    }

    private func reloadRoutines(botID: BotID) {
        do {
            routineListCountForTesting += 1
            routines = try botStore.listRoutines(botID: botID)
            rememberStudioSupport(for: botID)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func conversationForBot(_ botID: BotID) -> BotConversation? {
        if let dest = destConversation(for: botID) {
            return dest
        }
        // Dest first. Settle dest used to listConversations after dest
        // dested Chat — including when dest dested another teammate.
        // Dest cache already has this thread from persist dest.
        conversationListCountForTesting += 1
        return (try? botStore.listConversations(botID: botID).first)
    }

    private func cachedMessages(
        botID: BotID,
        conversationID: BotConversationID?
    ) -> [BotDeskMessage] {
        if let conversationID, let rows = messagesByConversation[conversationID] {
            return rows
        }
        if let conversationID, messagesConversationIDByBot[botID] == conversationID {
            return messagesByBot[botID] ?? []
        }
        return []
    }

    private func storeCachedMessages(
        _ messages: [BotDeskMessage],
        botID: BotID,
        conversationID: BotConversationID?
    ) {
        if let conversationID {
            messagesByConversation[conversationID] = messages
        }
        messagesByBot[botID] = messages
        messagesConversationIDByBot[botID] = conversationID
    }

    /// Persist dest already wrote this thread into dest cache. Settle
    /// dest must dest Chat from that cache instead of listing threads.
    private func destConversation(for botID: BotID) -> BotConversation? {
        if let selected = selectedConversation, selected.botID == botID {
            return selected
        }
        if selectedBotID != botID, let started = lastStartedConversationByBot[botID] {
            return started
        }
        if let snapshot = studioSupportByBot[botID] {
            if let selected = snapshot.selectedConversation, selected.botID == botID {
                return selected
            }
            if let first = snapshot.conversations.first(where: { $0.botID == botID }) {
                return first
            }
        }
        if selectedBotID == botID {
            return conversations.first(where: { $0.botID == botID })
        }
        return nil
    }

    private func threadBelongsToAnotherBot(_ threadID: AgentThreadID, botID: BotID) -> Bool {
        guard let owner = try? botStore.conversationLinked(to: threadID) else { return false }
        return owner.botID != botID
    }

    private func restoreDeskMessages(botID: BotID) {
        deskRestoreInvokedCountForTesting += 1
        lastDeskRestoreStudioSupportCountForTesting = studioSupportReloadCountForTesting
        lastDeskRestoreAttentionListCountForTesting = attentionListCountForTesting
        lastDeskRestoreConversationListCountForTesting = conversationListCountForTesting
        let conversation = conversationForBot(botID)
        if let conversation, selectedBotID == botID {
            selectedConversation = conversation
            selectedConversationByBot[botID] = conversation.id
            if !conversations.contains(where: { $0.id == conversation.id }) {
                conversations.insert(conversation, at: 0)
            }
        }
        let cached = cachedMessages(botID: botID, conversationID: conversation?.id)
        // Dest first. First paint dest used to dest dest thread
        // (listRecent) before dest dested Chat. Dest dests dest
        // title now; dest dests dest thread after dest dested Chat.
        destDeskChatFromTitleIfNeeded(botID: botID, cached: cached, conversation: conversation)
        var persisted: [BotDeskMessage] = []
        if let threadID = conversation?.linkedAgentThreadID,
           let stored = try? context.messageRepo.listRecent(threadId: threadID, limit: 80),
           !stored.isEmpty {
            deskMessageRestoreCountForTesting += 1
            let askedBotHandoff = conversation.flatMap { conversation in
                peerHandoffs.values.first { $0.peerConversationID == conversation.id }
            }
            var hidAskedBotProviderPrompt = false
            persisted = stored.compactMap { message -> BotDeskMessage? in
                let role: BotDeskMessage.Role
                var text: String
                switch message.role {
                case .user:
                    role = .user
                    text = BotsDeskFollowThrough.displayUserText(from: message.content)
                    if BotPeerTranscript.isHostHopUserText(text) { return nil }
                    if !hidAskedBotProviderPrompt,
                       let askedBotHandoff,
                       text == askedBotHandoff.outboundText {
                        // The peer thread persists its compiled provider input.
                        // Desk paints the same ask below with From-host chrome.
                        hidAskedBotProviderPrompt = true
                        return nil
                    }
                    if BotPeerTranscript.isPeerAskUserText(text) {
                        if let conversation, peerHandoffs.values.contains(where: {
                            $0.peerConversationID == conversation.id
                        }) {
                            return nil
                        }
                        text = BotPeerTranscript.displayTextFromPeerAsk(text)
                    }
                    text = AgentChatTranscriptChrome.displayUserLine(
                        text: AgentChatTranscriptChrome.promptByRemovingDisplayDecorations(
                            from: text,
                            attachments: message.attachments
                        ),
                        attachments: message.attachments
                    )
                case .assistant:
                    role = .assistant
                    text = message.content
                default:
                    return nil
                }
                var bubble = BotDeskMessage(
                    role: role,
                    text: text,
                    createdAt: message.createdAt,
                    agentMessageID: message.id
                )
                if role == .user {
                    bubble.peer = self.peerAttribution(forUserText: text, hostID: botID)
                }
                return bubble
            }
            attachTokenSaverTranscriptMetadata(
                to: &persisted,
                threadID: threadID,
                messageIds: stored.map(\.id)
            )
            overlayCachedHumanTextOntoPersistedTokenSaverUsers(
                cached: cached,
                persisted: &persisted
            )
        }
        var visible = BotsDeskFollowThrough.visibleDeskMessages(cached: cached, persisted: persisted)
        visible = mergePeerTurns(visible, conversationID: conversation?.id)
        if visible.isEmpty, let conversation, Self.shouldDestTitleAsBubble(conversation.title) {
            visible = [BotDeskMessage(role: .user, text: conversation.title, createdAt: conversation.createdAt)]
        }
        storeCachedMessages(visible, botID: botID, conversationID: conversation?.id)
        if selectedBotID == botID {
            deskMessages = visible
            if selectedConversation?.botID == botID {
                reloadTokenSaverThreadSavings()
            }
        }
        if let last = visible.last, !last.text.isEmpty {
            lastPreviewByBot[botID] = last.text
            lastUpdatedByBot[botID] = last.createdAt
        }
    }

    private func attachTokenSaverTranscriptMetadata(
        to messages: inout [BotDeskMessage],
        threadID: AgentThreadID,
        messageIds: [AgentMessageID]
    ) {
        let requests = (try? context.messageRepo.rcw1RequestTranslations(
            threadId: threadID,
            messageIds: messageIds
        )) ?? [:]
        let responses = (try? context.messageRepo.rcw1ResponseTranslations(
            threadId: threadID,
            messageIds: messageIds
        )) ?? [:]
        let modes = (try? context.messageRepo.tokenSaverDisplayModes(
            threadId: threadID,
            messageIds: messageIds
        )) ?? [:]
        var originalIds = tokenSaverOriginalDisplayMessageIds
        for index in messages.indices {
            guard let id = messages[index].agentMessageID else { continue }
            messages[index].tokenSaverWireRequest = requests[id]
            if let response = responses[id] {
                messages[index].tokenSaverOriginal = response.wireResponseText
                messages[index].tokenSaverTurnId = response.turnId
            }
            if modes[id] == .rcw1 {
                originalIds.insert(id)
            }
        }
        if selectedBotID != nil {
            tokenSaverOriginalDisplayMessageIds = originalIds
        }
    }

    /// Persist stores the compiled provider envelope (and may wire-encode the
    /// User request). Desk Human must keep the teammate line that send() already
    /// painted, then borrow RCW1 from the retained user message.
    private func overlayCachedHumanTextOntoPersistedTokenSaverUsers(
        cached: [BotDeskMessage],
        persisted: inout [BotDeskMessage]
    ) {
        guard !cached.isEmpty else { return }
        for index in persisted.indices {
            guard persisted[index].role == .user,
                  let id = persisted[index].agentMessageID,
                  let live = cached.first(where: {
                      $0.role == .user && $0.agentMessageID == id
                  }) else { continue }
            persisted[index] = BotDeskMessage(
                id: persisted[index].id,
                role: .user,
                text: live.text,
                createdAt: persisted[index].createdAt,
                peer: persisted[index].peer ?? live.peer,
                agentMessageID: id,
                tokenSaverWireRequest: persisted[index].tokenSaverWireRequest
                    ?? live.tokenSaverWireRequest,
                tokenSaverOriginal: persisted[index].tokenSaverOriginal
                    ?? live.tokenSaverOriginal,
                tokenSaverTurnId: persisted[index].tokenSaverTurnId
                    ?? live.tokenSaverTurnId
            )
        }
    }

    /// Create the Human user row (and RCW1 translation) before provider start
    /// or queue. Coordinator skips append when this id already exists, so a
    /// later throw or queue drain cannot leave compiled envelope as the
    /// surviving transcript.
    private func persistDeskTokenSaverUserTranslation(
        threadID: AgentThreadID,
        runID: AgentRunID,
        botID: BotID,
        conversationID: BotConversationID,
        humanText: String,
        attachments: [AgentAttachment],
        wireRequest: String
    ) throws {
        let messageID = AgentMessageID(runID.value)
        let human = AgentChatTranscriptChrome.displayUserLine(
            text: humanText,
            attachments: attachments
        )
        if try context.messageRepo.exists(id: messageID) == false {
            try context.messageRepo.append(AgentMessage(
                id: messageID,
                threadId: threadID,
                role: .user,
                content: human,
                attachments: attachments
            ))
        }
        guard RCWireProtocol.isWire(wireRequest) else { return }
        try context.messageRepo.upsertRCW1RequestTranslation(
            messageId: messageID,
            wireRequestText: wireRequest
        )
        func attach(to messages: inout [BotDeskMessage]) {
            guard let index = messages.firstIndex(where: { $0.agentMessageID == messageID }) else {
                return
            }
            messages[index].tokenSaverWireRequest = wireRequest
        }
        if var cached = messagesByConversation[conversationID] {
            attach(to: &cached)
            messagesByConversation[conversationID] = cached
        }
        if var cached = messagesByBot[botID] {
            attach(to: &cached)
            messagesByBot[botID] = cached
        }
        if selectedBotID == botID, selectedConversation?.id == conversationID {
            attach(to: &deskMessages)
        }
    }

    /// Dest first. First paint dest used to dest dest thread before
    /// dest dested Chat. Dest dests dest title so dest dests Chat
    /// before dest dests dest thread.
    private func destDeskChatFromTitleIfNeeded(
        botID: BotID,
        cached: [BotDeskMessage],
        conversation: BotConversation?
    ) {
        guard selectedBotID == botID, deskMessages.isEmpty else { return }
        lastDeskRestoreMessageListCountForTesting = deskMessageRestoreCountForTesting
        if !cached.isEmpty {
            deskMessages = cached
            return
        }
        guard let conversation, Self.shouldDestTitleAsBubble(conversation.title) else { return }
        deskMessages = [
            BotDeskMessage(role: .user, text: conversation.title, createdAt: conversation.createdAt)
        ]
    }

    private func restoreDeskLiveTurn(
        botID: BotID,
        reconcileObservedAtTerminal: Bool = false
    ) {
        let conversation = conversationForBot(botID)
        guard let threadID = conversation?.linkedAgentThreadID else {
            if selectedBotID == botID {
                deskLiveTimeline = AssistantTimelineState()
                deskStreamEventCount = 0
                deskLiveTurnWatch?.cancel()
                deskLiveTurnWatch = nil
            }
            return
        }
        // Agent App owns the transcript; the desk timeline replay would only feed deleted views.
        if deskAgentOwnsLiveStream(threadID: threadID) { return }
        applyDeskLiveReplay(
            botID: botID,
            threadID: threadID,
            reconcileObservedAtTerminal: reconcileObservedAtTerminal
        )
        if selectedBotID == botID, screen == .desk, deskRunIsLive {
            startDeskLiveTurnWatch(botID: botID, threadID: threadID)
        }
    }

    @discardableResult
    private func applyDeskLiveReplay(
        botID: BotID,
        threadID: AgentThreadID,
        reconcileObservedAtTerminal: Bool = false,
        fetchOffMain: Bool = false,
        prefetchedCursor: AgentRunRepository.StreamEventCursor? = nil
    ) -> Bool {
        let cursor = prefetchedCursor
            ?? context.coordinator.streamEventCursor(threadId: threadID)
        let hasUnconfirmedObservedEvents = liveObservedEventsByThread[threadID]?.isEmpty == false
            || liveObservedEventOverflowThreads.contains(threadID)
        let requiresTerminalReconciliation = reconcileObservedAtTerminal
            && hasUnconfirmedObservedEvents
        if let previous = liveStreamCursorByThread[threadID],
           previous == cursor,
           !requiresTerminalReconciliation {
            if selectedBotID == botID {
                deskLiveTimeline = liveTimelineByThread[threadID] ?? deskLiveTimeline
                deskStreamEventCount = liveStreamCountByThread[threadID] ?? cursor.count
            }
            return false
        }
        if let previous = liveStreamCursorByThread[threadID],
           let runId = cursor.runId,
           previous.runId == runId,
           cursor.sequence > previous.sequence,
           let previousMutationId = previous.mutationId,
           let mutationId = cursor.mutationId,
           !liveObservedEventOverflowThreads.contains(threadID) {
            let advance = cursor.sequence - previous.sequence
            let observed = liveObservedEventsByThread[threadID] ?? []
            if advance <= observed.count,
               let suffix = context.coordinator.attestedStreamEventSuffix(
                   threadId: threadID,
                   afterMutationId: previousMutationId,
                   throughMutationId: mutationId,
                   runId: runId,
                   startingSequence: previous.sequence + 1,
                   count: advance
               ) {
                deskLiveIncrementalDecodeEventCountForTesting += suffix.events.count
                deskLiveIncrementalDecodeBytesForTesting += suffix.decodedPayloadBytes
                if suffix.events == Array(observed.prefix(advance)) {
                    let remaining = Array(observed.dropFirst(advance))
                    let previousBytes = liveObservedEventBytesByThread[threadID] ?? 0
                    let remainingBytes = remaining.reduce(0) {
                        $0 + max(1, $1.estimatedHotQueueBytes)
                    }
                    liveObservedEventBytesTotal = max(
                        0,
                        liveObservedEventBytesTotal - previousBytes + remainingBytes
                    )
                    liveObservedEventsByThread[threadID] = remaining.isEmpty ? nil : remaining
                    liveObservedEventBytesByThread[threadID] = remaining.isEmpty
                        ? nil
                        : remainingBytes
                    liveStreamCursorByThread[threadID] = cursor
                    liveStreamCountByThread[threadID] = cursor.count
                    if selectedBotID == botID {
                        deskLiveTimeline = liveTimelineByThread[threadID] ?? deskLiveTimeline
                        deskStreamEventCount = cursor.count
                    }
                    return true
                }
            }
        }
        deskLiveReplayFetchCountForTesting += 1
        if fetchOffMain {
            // BT-23: the 2 s watch fell back to this full replay (up to 4,096
            // events / 32 MiB decoded) on the MainActor for the rest of a long
            // turn once the observed-event window overflowed. Fetch + replay
            // detached; adopt on main only if nothing newer superseded it.
            deskLiveReplayOffMainFetchCountForTesting += 1
            deskLiveReplayGeneration += 1
            let generation = deskLiveReplayGeneration
            let coordinator = context.coordinator
            Task.detached(priority: .userInitiated) { [weak self] in
                let events = coordinator.latestStreamEvents(threadId: threadID)
                let state = AgentChatLiveTurnChrome.timelineByReplaying(events)
                await MainActor.run {
                    guard let self, generation == self.deskLiveReplayGeneration else { return }
                    let adopted = self.adoptReplayedDeskTimeline(
                        state,
                        cursor: cursor,
                        botID: botID,
                        threadID: threadID,
                        requiresTerminalReconciliation: requiresTerminalReconciliation,
                        hasUnconfirmedObservedEvents: hasUnconfirmedObservedEvents
                    )
                    if adopted { self.refreshPublishedIdentity(for: botID) }
                }
            }
            return false
        }
        let events = context.coordinator.latestStreamEvents(threadId: threadID)
        let state = AgentChatLiveTurnChrome.timelineByReplaying(events)
        return adoptReplayedDeskTimeline(
            state,
            cursor: cursor,
            botID: botID,
            threadID: threadID,
            requiresTerminalReconciliation: requiresTerminalReconciliation,
            hasUnconfirmedObservedEvents: hasUnconfirmedObservedEvents
        )
    }

    /// Tail of a full replay: keep the richer in-memory timeline when SQLite
    /// still lags, otherwise adopt the replayed state. Shared by the
    /// synchronous path and the detached watch fetch (BT-23).
    private func adoptReplayedDeskTimeline(
        _ state: AssistantTimelineState,
        cursor: AgentRunRepository.StreamEventCursor,
        botID: BotID,
        threadID: AgentThreadID,
        requiresTerminalReconciliation: Bool,
        hasUnconfirmedObservedEvents: Bool
    ) -> Bool {
        // Compare against THIS thread. A per-bot cache kept a richer
        // hop's Worked rows after the user opened another conversation.
        let current = liveTimelineByThread[threadID] ?? AssistantTimelineState()
        liveStreamCursorByThread[threadID] = cursor
        if !requiresTerminalReconciliation,
           AgentChatLiveTurnChrome.isRicher(current, than: state) {
            liveStreamCountByThread[threadID] = max(
                cursor.count,
                liveStreamCountByThread[threadID] ?? 0
            )
            clearDeskObservedEvents(threadID: threadID)
            if hasUnconfirmedObservedEvents {
                liveObservedEventOverflowThreads.insert(threadID)
            }
            if selectedBotID == botID {
                deskLiveTimeline = current
                deskStreamEventCount = liveStreamCountByThread[threadID] ?? cursor.count
            }
            return true
        }
        storeLiveTimeline(state, for: threadID)
        liveStreamCountByThread[threadID] = cursor.count
        clearDeskObservedEvents(threadID: threadID)
        if selectedBotID == botID {
            deskLiveTimeline = state
            deskStreamEventCount = cursor.count
        }
        return true
    }

    private func flushDeskStreamEventBatch() {
        let batch = deskStreamEventBatch.drain()
        guard !batch.isEmpty else { return }
        applyIncomingDeskEvents(batch)
    }

    private func applyIncomingDeskEvent(
        _ event: AssistantEvent,
        runId: AgentRunID? = nil,
        threadId: AgentThreadID
    ) {
        applyIncomingDeskEvents([.init(event: event, runId: runId, threadId: threadId)])
    }

    /// Applies a batch of stream events with ONE `deskLiveTimeline` publish.
    /// Per-event bookkeeping (observed-event window, terminal reconciliation
    /// trigger) is unchanged; only the paint is coalesced.
    private func applyIncomingDeskEvents(_ batch: [DeskStreamEventBatchBox.Entry]) {
        applyIncomingDeskEventCountForTesting += batch.count
        guard screen == .desk,
              let selectedThreadId = selectedConversation?.linkedAgentThreadID
        else { return }
        var next = deskLiveTimeline
        var touched = false
        var terminalReplay: (runId: AgentRunID, threadId: AgentThreadID)?
        var appliedEvents: [AssistantEvent] = []
        appliedEvents.reserveCapacity(batch.count)
        for entry in batch where entry.threadId == selectedThreadId {
            let event = entry.event
            let threadId = entry.threadId
            touched = true
            appliedEvents.append(event)
            next.apply(event)
            if let runId = entry.runId, settledTerminalRunIDByThread[threadId] == runId {
                terminalReplay = (runId, threadId)
            }
            if !liveObservedEventOverflowThreads.contains(threadId) {
                recordObservedDeskEvent(event, threadId: threadId)
            }
        }
        guard touched else { return }
        lastDeskStreamPushAt = Date()
        let budget = AgentAppViewModel.aggregateBudgetDecision(
            force: AgentAppViewModel.forcesAggregateBudget(events: appliedEvents),
            opsSinceLastWalk: deskStreamAggregateBudgetOps,
            appliedEventCount: appliedEvents.count
        )
        deskStreamAggregateBudgetOps = budget.nextOps
        if budget.runsWalk { next.enforceAggregateHotTextBudget() }
        deskLiveTimeline = next
        storeLiveTimeline(next, for: selectedThreadId)
        if let terminalReplay, let botID = selectedBotID {
            _ = applyDeskLiveReplay(
                botID: botID,
                threadID: terminalReplay.threadId,
                reconcileObservedAtTerminal: true
            )
        }
    }

    private func recordObservedDeskEvent(_ event: AssistantEvent, threadId: AgentThreadID) {
        var observed = liveObservedEventsByThread[threadId] ?? []
        let eventBytes = max(1, event.estimatedHotQueueBytes)
        let threadBytes = liveObservedEventBytesByThread[threadId] ?? 0
        let byteLimit = max(
            1,
            deskLiveObservedEventByteLimitForTesting
                ?? Int(AgentRunCoordinator.hotReplayEventBytes)
        )
        if observed.count < AgentRunCoordinator.hotReplayEventCount,
           eventBytes <= byteLimit,
           threadBytes <= byteLimit - eventBytes,
           liveObservedEventBytesTotal <= byteLimit - eventBytes {
            observed.append(event)
            liveObservedEventsByThread[threadId] = observed
            liveObservedEventBytesByThread[threadId] = threadBytes + eventBytes
            liveObservedEventBytesTotal += eventBytes
        } else {
            clearDeskObservedEvents(threadID: threadId)
            liveObservedEventOverflowThreads.insert(threadId)
        }
    }

    private func refreshDeskLiveTurnIfCountChanged(botID: BotID, threadID: AgentThreadID) {
        applyDeskLiveReplay(botID: botID, threadID: threadID)
    }

    private func startDeskLiveTurnWatch(botID: BotID, threadID: AgentThreadID) {
        deskLiveTurnWatch?.cancel()
        deskLiveTurnWatch = nil
        guard !deskAgentOwnsLiveStream(threadID: threadID) else { return }
        deskLiveTurnWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                guard self.selectedBotID == botID, self.screen == .desk else { return }
                guard self.selectedConversation?.linkedAgentThreadID == threadID else { return }
                if let lastPush = self.lastDeskStreamPushAt,
                   Date().timeIntervalSince(lastPush) < 1 {
                    continue
                }
                if await self.deskLiveTurnWatchTick(botID: botID, threadID: threadID) {
                    return
                }
            }
        }
    }

    /// One watch tick. Both SQLite reads (`streamEventCursor` and `linkedRun`)
    /// happen off MainActor and only their result is applied here, because a
    /// main-thread probe can stall the UI behind the repo's transient-lock
    /// retry (8 tries / 2 s) while a turn is writing. Returns true when the
    /// watched run is terminal, i.e. when the watch must stop.
    private func deskLiveTurnWatchTick(botID: BotID, threadID: AgentThreadID) async -> Bool {
        let knownRunID = lastLinkedRunIDByBot[botID]
        let coordinator = context.coordinator
        let runRepo = context.runRepo
        let probe = await Task.detached(priority: .userInitiated) {
            DeskLiveTurnWatchProbe(
                cursor: coordinator.streamEventCursor(threadId: threadID),
                linkedRun: BotsViewModel.resolveLinkedRun(
                    runRepo: runRepo,
                    threadID: threadID,
                    knownRunID: knownRunID
                )
            )
        }.value
        deskLiveTurnWatchApplyCountForTesting += 1
        adoptLinkedRunProbe(probe.linkedRun, botID: botID)
        // BT-23: a full replay from here runs detached and refreshes the
        // identity itself once adopted; the incremental path stays sync.
        if applyDeskLiveReplay(
            botID: botID,
            threadID: threadID,
            fetchOffMain: true,
            prefetchedCursor: probe.cursor
        ) {
            refreshPublishedIdentity(for: botID)
        }
        guard let run = probe.linkedRun.run,
              BotsDeskFollowThrough.isTerminal(run.status) else {
            return false
        }
        if applyDeskLiveReplay(
            botID: botID,
            threadID: threadID,
            reconcileObservedAtTerminal: true
        ) {
            refreshPublishedIdentity(for: botID)
        }
        return true
    }

    private func restoreDeskWorkLog(botID: BotID, preferredRun: AgentRun? = nil) {
        let conversation = conversationForBot(botID)
        guard let threadID = conversation?.linkedAgentThreadID else {
            if selectedBotID == botID { deskWorkLog = [] }
            return
        }
        let run: AgentRun?
        if let preferredRun, preferredRun.threadId == threadID {
            run = preferredRun
        } else {
            run = linkedRun(for: threadID, botID: botID)
        }
        let mode = (try? context.threadRepo.permissionMode(of: threadID))
            ?? deskRouting.permissionMode
        let rows = BotsDeskFollowThrough.workLogRows(for: run, mode: mode)
        if selectedBotID == botID {
            deskWorkLog = rows
        }
    }

    private func linkedRun(for threadID: AgentThreadID, botID: BotID) -> AgentRun? {
        let probe = Self.resolveLinkedRun(
            runRepo: context.runRepo,
            threadID: threadID,
            knownRunID: lastLinkedRunIDByBot[botID]
        )
        adoptLinkedRunProbe(probe, botID: botID)
        return probe.run
    }

    /// The `agent_runs` reads behind `linkedRun`, with no main-actor state so a
    /// live poller can run them off MainActor — a main-thread probe can stall
    /// the UI behind the repo's transient-lock retry (8 tries / 2 s) while a
    /// turn is writing.
    nonisolated static func resolveLinkedRun(
        runRepo: AgentRunRepository,
        threadID: AgentThreadID,
        knownRunID: AgentRunID?
    ) -> DeskLinkedRunProbe {
        if let active = try? runRepo.latestActive(for: threadID) {
            return DeskLinkedRunProbe(run: active, memoizedRunID: active.id, scannedFinished: false)
        }
        if let knownRunID,
           let stored = try? runRepo.get(id: knownRunID),
           stored.threadId == threadID {
            return DeskLinkedRunProbe(run: stored, memoizedRunID: nil, scannedFinished: false)
        }
        guard let finished = (try? runRepo.listRecentFinished(limit: 80))?
            .first(where: { $0.threadId == threadID }) else {
            return DeskLinkedRunProbe(run: nil, memoizedRunID: nil, scannedFinished: true)
        }
        return DeskLinkedRunProbe(run: finished, memoizedRunID: finished.id, scannedFinished: true)
    }

    /// Main-actor half of `resolveLinkedRun`: the roster-scan counter and the
    /// remembered run id.
    private func adoptLinkedRunProbe(_ probe: DeskLinkedRunProbe, botID: BotID) {
        // Roster dest used to scan 80 finished runs on every click when
        // lastLinkedRunID was unset. Remember the first hit.
        if probe.scannedFinished { deskFinishedRunScanCountForTesting += 1 }
        if let memoizedRunID = probe.memoizedRunID {
            lastLinkedRunIDByBot[botID] = memoizedRunID
        }
    }

    private func appendDeskMessage(
        _ message: BotDeskMessage,
        botID: BotID,
        conversationID: BotConversationID? = nil
    ) {
        let threadID = conversationID
            ?? (selectedBotID == botID ? selectedConversation?.id : nil)
            ?? messagesConversationIDByBot[botID]
        if let threadID {
            messagesByConversation[threadID, default: []].append(message)
        }
        if let threadID, messagesConversationIDByBot[botID] != threadID {
            messagesByBot[botID] = [message]
            messagesConversationIDByBot[botID] = threadID
        } else {
            messagesByBot[botID, default: []].append(message)
            if let threadID {
                messagesConversationIDByBot[botID] = threadID
            }
        }
        if selectedBotID == botID,
           threadID == nil || threadID == selectedConversation?.id {
            deskMessages.append(message)
        }
        lastPreviewByBot[botID] = message.text
        lastUpdatedByBot[botID] = message.createdAt
    }

    private func stampDeskUserMessageIdentity(runID: AgentRunID, botID: BotID) {
        let messageID = AgentMessageID(runID.value)
        func stamp(_ messages: inout [BotDeskMessage]) {
            guard let index = messages.lastIndex(where: {
                $0.role == .user && $0.agentMessageID == nil
            }) else { return }
            var next = messages[index]
            next.agentMessageID = messageID
            messages[index] = BotDeskMessage(
                id: messageID.value,
                role: next.role,
                text: next.text,
                createdAt: next.createdAt,
                peer: next.peer,
                agentMessageID: messageID,
                tokenSaverWireRequest: next.tokenSaverWireRequest,
                tokenSaverOriginal: next.tokenSaverOriginal,
                tokenSaverTurnId: next.tokenSaverTurnId
            )
        }
        if let conversationID = (selectedBotID == botID ? selectedConversation?.id : nil)
            ?? messagesConversationIDByBot[botID],
           var cached = messagesByConversation[conversationID] {
            stamp(&cached)
            messagesByConversation[conversationID] = cached
        }
        if var cached = messagesByBot[botID] {
            stamp(&cached)
            messagesByBot[botID] = cached
        }
        if selectedBotID == botID {
            stamp(&deskMessages)
        }
    }

    @discardableResult
    private func persistUserMessage(
        bot: BotDefinition,
        text: String,
        adoptSelection: Bool = true,
        createNew: Bool = false,
        conversationID: BotConversationID? = nil
    ) throws -> BotConversation {
        var conversation: BotConversation
        if let conversationID {
            guard let requested = try botStore.conversation(id: conversationID),
                  requested.botID == bot.id else {
                throw BotStoreError.notFound
            }
            conversation = requested
        } else if createNew {
            conversation = BotConversation(
                botID: bot.id,
                title: Self.titleFromFirstMessage(text)
            )
        } else if let selected = selectedConversation, selected.botID == bot.id {
            conversation = selected
        } else if let rememberedID = selectedConversationByBot[bot.id],
                  let remembered = destConversations(botID: bot.id).first(where: { $0.id == rememberedID }) {
            conversation = remembered
        } else {
            conversation = BotConversation(
                botID: bot.id,
                title: Self.titleFromFirstMessage(text)
            )
        }
        if conversation.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || conversation.title == "New thread" {
            conversation.title = Self.titleFromFirstMessage(text)
        }
        conversation.updatedAt = Date()
        conversation.unread = false
        // Dest first. Persist used to listConversations after dest
        // painted the bubble. The upserted row is already dest state.
        try botStore.upsertConversation(conversation)
        if adoptSelection {
            adoptWrittenConversation(conversation)
        } else {
            patchStudioSupportConversation(conversation, botID: bot.id)
            if selectedBotID == bot.id {
                conversations.removeAll { $0.id == conversation.id }
                conversations.insert(conversation, at: 0)
            }
        }
        return conversation
    }

    /// Persist dest used to listConversations after the store wrote
    /// this thread. Patch it locally so dest does not reread threads.
    private func adoptWrittenConversation(_ conversation: BotConversation) {
        selectedConversation = conversation
        selectedConversationByBot[conversation.botID] = conversation.id
        conversations.removeAll { $0.id == conversation.id }
        conversations.insert(conversation, at: 0)
        rememberStudioSupport(for: conversation.botID)
    }

    /// Follow-through dest used to listConversations when dest was not
    /// already on this thread. Dest already has this row from persist
    /// dest or the last dest snapshot.
    private func destFollowThroughConversation(
        for bot: BotDefinition,
        fallback: BotConversation
    ) -> BotConversation {
        if let selected = selectedConversation, selected.id == fallback.id {
            return selected
        }
        if selectedBotID == bot.id,
           let dest = conversations.first(where: { $0.id == fallback.id }) {
            return dest
        }
        if let cached = studioSupportByBot[bot.id]?.conversations.first(where: { $0.id == fallback.id }) {
            return cached
        }
        return fallback
    }

    /// Follow-through dest used to reloadFleet after dest already
    /// painted the completed turn. Patch this dest thread locally.
    private func adoptFollowThroughConversation(_ conversation: BotConversation) {
        if selectedConversation?.id == conversation.id {
            selectedConversation = conversation
        }
        if selectedBotID == conversation.botID {
            conversations.removeAll { $0.id == conversation.id }
            conversations.insert(conversation, at: 0)
            rememberStudioSupport(for: conversation.botID)
        } else {
            patchStudioSupportConversation(conversation, botID: conversation.botID)
        }
    }

    /// Follow-through dest used to listAttention after dest already
    /// upserted this row. Insert it locally so dest inbox is current.
    private func adoptWrittenAttention(_ item: BotAttentionItem) {
        attentionItems.removeAll { $0.id == item.id }
        attentionItems.insert(item, at: 0)
    }

    /// Acknowledge dest used to listAttention after dest already
    /// painted Chat. Drop this row locally so dest does not reread
    /// the inbox. Cold dest still lists.
    private func dropAcknowledgedAttention(_ id: BotAttentionItemID) {
        let botID = attentionItems.first(where: { $0.id == id })?.botID
        attentionItems.removeAll { $0.id == id }
        if let botID {
            applyAttentionState(for: botID, conversations: destConversations(botID: botID))
        }
    }

    private func destConversations(botID: BotID) -> [BotConversation] {
        if let cached = studioSupportByBot[botID]?.conversations, !cached.isEmpty {
            return cached
        }
        if selectedBotID == botID, conversations.contains(where: { $0.botID == botID }) {
            return conversations
        }
        return []
    }

    private func destConversations(botID: BotID, patched: BotConversation) -> [BotConversation] {
        if selectedBotID == botID {
            return conversations
        }
        if var items = studioSupportByBot[botID]?.conversations {
            if let index = items.firstIndex(where: { $0.id == patched.id }) {
                items[index] = patched
            } else {
                items.insert(patched, at: 0)
            }
            return items
        }
        return [patched]
    }

    private func recordNeedsAttention(bot: BotDefinition, conversation: BotConversation, userText: String) {
        do {
            var next = conversation
            next.attentionState = .needsAttention
            next.updatedAt = Date()
            try botStore.upsertConversation(next)
            // Dest first. Needs-you dest used to listAttention after dest
            // painted the bubble. The upserted row is dest inbox state.
            adoptFollowThroughConversation(next)
            let item = BotAttentionItem(
                botID: bot.id,
                conversationID: next.id,
                kind: .question,
                title: "Needs you",
                detail: userText
            )
            try botStore.upsertAttention(item)
            appendDeskMessage(
                BotDeskMessage(role: .assistant, text: Self.assistantPlaceholder),
                botID: bot.id,
                conversationID: next.id
            )
            adoptWrittenAttention(item)
            applyAttentionState(
                for: bot.id,
                conversations: destConversations(botID: bot.id, patched: next)
            )
            Self.publishDestAttentionChanged()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    static func publishDestAttentionChanged() {
        EventBus.shared.publish(kind: .botsAttentionChanged, payload: .object([:]))
    }

    private func currentRevision(for bot: BotDefinition) throws -> BotRevision? {
        cachedRevision(for: bot)
    }

    /// Roster dest used to getRevision for every teammate chip on every
    /// dest paint. Revisions are immutable by id; a new publish is a new id.
    private func cachedRevision(for bot: BotDefinition) -> BotRevision? {
        if selectedBotID == bot.id,
           let selectedRevision,
           selectedRevision.id == bot.currentRevisionID {
            revisionByID[selectedRevision.id] = selectedRevision
            return selectedRevision
        }
        guard let revisionID = bot.currentRevisionID else { return nil }
        if let cached = revisionByID[revisionID] {
            return cached
        }
        rosterRevisionFetchCountForTesting += 1
        guard let revision = try? botStore.getRevision(id: revisionID) else { return nil }
        revisionByID[revisionID] = revision
        return revision
    }

    /// Send dest used to listMemory/listSkillBindings after dest
    /// painted the bubble. Use dest cache when this teammate is open.
    private func destBrainInputs(for bot: BotDefinition) -> (memoryFiles: [BotMemoryFileText], skills: [BotSkillBinding], routines: [BotRoutine]) {
        if selectedBotID == bot.id {
            return (memoryFileTexts(for: bot), skillBindings, routines)
        }
        skillListCountForTesting += 1
        routineListCountForTesting += 1
        let skills = (try? botStore.listSkillBindings(botID: bot.id)) ?? []
        let listedRoutines = (try? botStore.listRoutines(botID: bot.id)) ?? []
        return (memoryFileTexts(for: bot), skills, listedRoutines)
    }

    /// Live turns must flip attention to working on first send and on
    /// reuse. Otherwise Active Bots only sees the first brand-new thread.
    @discardableResult
    private func persistWorkingConversation(_ conversation: BotConversation) throws -> BotConversation {
        var working = conversation
        working.attentionState = .working
        working.updatedAt = Date()
        try botStore.upsertConversation(working)
        lastStartedConversationByBot[working.botID] = working
        adoptFollowThroughConversation(working)
        // The attention state settles into one roster pass (see
        // applyAttentionState); repeating the hydration here paid two.
        applyAttentionState(
            for: working.botID,
            conversations: destConversations(botID: working.botID, patched: working)
        )
        return working
    }

    private func frozenDeskRouting(for conversation: BotConversation) -> BotDeskRouting {
        if selectedConversation?.id == conversation.id {
            return deskRouting
        }
        if let saved = deskRoutingByConversation[conversation.id] {
            return saved
        }
        guard let threadID = conversation.linkedAgentThreadID,
              let thread = try? context.threadRepo.get(id: threadID) else {
            return BotDeskRouting()
        }
        return BotDeskRouting(thread: thread)
    }

    // MARK: - Embedded Agent App desk

    /// One fixed workspace for every embedded bot desk. Bot threads have no
    /// workspace row (created with nil); the pinned VM accepts them whatever
    /// their workspace is, and this id only scopes rail/event filters that an
    /// embedded desk never lists.
    static let botDeskWorkspaceID = WorkspaceID(
        UUID(uuidString: "00000000-0000-0000-0000-00000000B07D")!
    )

    struct BotDeskSendRefused: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    private struct DeskAgentKey: Equatable {
        let botID: BotID
        let conversationID: BotConversationID
        let threadID: AgentThreadID
    }

    private var deskAgentKey: DeskAgentKey?
    private var isSyncingDeskAgent = false
    private var pendingDeskReceipts: [AgentRunID: ContextAssemblyReceipt] = [:]

    /// Keeps at most one pinned Agent App VM on the selected conversation's
    /// linked thread; creates the thread eagerly when the conversation has none.
    func syncDeskAgentVM() {
        guard !isSyncingDeskAgent else { return }
        isSyncingDeskAgent = true
        defer {
            isSyncingDeskAgent = false
            publishInterestedDeskThreadID()
        }
        guard screen == .desk,
              let bot = selectedBot,
              let conversation = selectedConversation,
              conversation.botID == bot.id,
              let router = resolvedRouter() else {
            tearDownDeskAgentVM()
            return
        }
        // Unlinked conversations get their thread (and BotHome) on first send.
        guard let threadID = conversation.linkedAgentThreadID else {
            tearDownDeskAgentVM()
            return
        }
        let live = conversation
        let key = DeskAgentKey(botID: bot.id, conversationID: live.id, threadID: threadID)
        if deskAgentKey == key, deskAgentVM != nil { return }
        tearDownDeskAgentVM()
        let deskCwd: String
        if let workspaceCwd = workspaceExecutionCwd(forThread: threadID) {
            deskCwd = workspaceCwd
        } else {
            deskCwd = BotHome(appSupportDirectory: context.appSupportDirectory, bot: bot).root.path
            try? FileManager.default.createDirectory(
                at: URL(fileURLWithPath: deskCwd),
                withIntermediateDirectories: true
            )
        }
        let embedding = AgentAppEmbedding(
            pinnedThreadId: threadID,
            executionCwd: deskCwd,
            promptTransform: { [weak self] text, threadId, runId in
                guard let self else { return text }
                return try self.compileDeskPrompt(
                    botID: bot.id,
                    conversationID: live.id,
                    text: text,
                    threadID: threadId,
                    runID: runId
                )
            },
            onRunStarted: { [weak self] runId, _ in
                self?.deskAgentRunStarted(botID: bot.id, conversationID: live.id, runID: runId)
            }
        )
        let vm = AgentAppViewModel(
            workspaceID: Self.botDeskWorkspaceID,
            cwd: deskCwd,
            coordinator: context.coordinator,
            threadRepo: context.threadRepo,
            messageRepo: context.messageRepo,
            draftRepo: AgentThreadDraftRepository(db: context.db),
            attachmentStore: attachmentStore(),
            queuedMessageRepo: context.queuedMessageRepo,
            providerSessionRepo: context.providerSessionRuntimeRepo,
            pendingCallbackRepo: context.providerPendingCallbackRepo,
            proposedPlanRepo: context.proposedPlanRepo,
            checkpointRepo: context.turnCheckpointRepo,
            promptHistoryStore: PromptHistoryStore(db: context.db),
            customModelStore: AgentCustomModelStore(repo: context.settingsRepo),
            planNotesStore: PlanNotesStore(db: context.db),
            initialThreadId: threadID,
            // Routing is frozen per conversation on the thread row.
            initialRoutingMode: .manual,
            orchestrationRuntime: context.orchestrationRuntime,
            embedding: embedding
        )
        vm.providerSnapshotLoader = { [weak router] in
            await router?.listAgentProviderSnapshots(runAsUser: nil) ?? []
        }
        vm.providerLaunchConfig = { [weak router] provider, instanceId in
            (
                router?.providerBinary(provider: provider, instanceId: instanceId),
                router?.providerEnvironment(provider: provider, instanceId: instanceId) ?? [:]
            )
        }
        vm.mentionableBotsProvider = { [weak self] in
            (try? self?.botStore.listCached()) ?? []
        }
        vm.mentionableBotsRevisionProvider = { [weak self] in
            self?.botStore.botsListRevision ?? 0
        }
        vm.botNameProvider = { [weak self] botID in
            (try? self?.botStore.get(id: botID))??.name
        }
        if workspaceExecutionCwd(forThread: threadID) != nil {
            vm.handoffHost = { [weak self, weak router] oldID, actor in
                do {
                    try router?.startBotHandoff(from: oldID, actor: actor)
                } catch {
                    self?.errorMessage = String(describing: error)
                }
            }
        }
        vm.markThreadRead = { [weak router] id in
            try router?.markAgentThreadRead(thread: id)
        }
        vm.refreshProviderSnapshotsInBackground()
        AppCommandRouter.wireTokenSaverThreadFooter(on: vm, context: context)
        deskAgentKey = key
        deskAgentVM = vm
    }

    /// Workspace-linked threads keep running in their workspace (or worktree), not the bot home.
    private func workspaceExecutionCwd(forThread threadID: AgentThreadID) -> String? {
        guard let thread = (try? context.threadRepo.get(id: threadID)) ?? nil,
              let workspaceID = thread.workspaceId else { return nil }
        if let worktree = thread.worktreePath, !worktree.isEmpty { return worktree }
        return context.state.workspaces[workspaceID]?.cwd
    }

    /// Queue-drained follow-ups bypass the embedded composer, so the router asks
    /// here to compile the brain for any bot-linked thread, selected or not.
    private func installBotQueueHooks(on router: AppCommandRouter) {
        router.botWorkspaceRunHooks = AppCommandRouter.BotWorkspaceRunHooks(
            link: { [weak self] botID, threadID in
                try self?.linkWorkspaceThread(threadID, toBot: botID)
            },
            promptTransform: { [weak self] botID, text, threadID, runID in
                guard let self else { throw BotDeskSendRefused(reason: "Bot indisponível.") }
                let bot = try self.liveBotForWorkspaceRun(botID)
                guard let conversation = try self.botStore.conversationLinked(to: threadID),
                      conversation.botID == bot.id else {
                    throw BotDeskSendRefused(reason: "Bot indisponível.")
                }
                return try self.compileDeskPrompt(
                    botID: bot.id,
                    conversationID: conversation.id,
                    text: text,
                    threadID: threadID,
                    runID: runID
                )
            },
            runStarted: { [weak self] botID, runID, threadID in
                guard let self,
                      let conversation = try? self.botStore.conversationLinked(to: threadID),
                      conversation.botID == botID else { return }
                self.deskAgentRunStarted(botID: botID, conversationID: conversation.id, runID: runID)
            }
        )
        router.botThreadPromptTransform = { [weak self] threadID, text, runID in
            guard let self else { return nil }
            let thread = try? self.context.threadRepo.get(id: threadID)
            let conversation = try? self.botStore.conversationLinked(to: threadID)
            let actorBotID: BotID? = {
                if case .bot(let id)? = thread?.actor { return id }
                return nil
            }()
            guard let botID = actorBotID ?? conversation?.botID else { return nil }
            let bot = actorBotID != nil
                ? try self.liveBotForWorkspaceRun(botID)
                : (self.bots.first(where: { $0.id == botID }) ?? (try? self.botStore.get(id: botID)))
            guard let bot, let conversation, conversation.botID == bot.id else {
                if actorBotID != nil { throw BotDeskSendRefused(reason: "Bot indisponível.") }
                return nil
            }
            let prompt = try self.compileDeskPrompt(
                botID: bot.id,
                conversationID: conversation.id,
                text: text,
                threadID: threadID,
                runID: runID
            )
            // Workspace threads keep the workspace cwd; only bot-home threads move.
            if thread?.workspaceId != nil {
                return AppCommandRouter.BotThreadQueuedPrompt(prompt: prompt, cwd: nil)
            }
            let cwd = BotHome(appSupportDirectory: self.context.appSupportDirectory, bot: bot).root.path
            try? FileManager.default.createDirectory(
                at: URL(fileURLWithPath: cwd),
                withIntermediateDirectories: true
            )
            return AppCommandRouter.BotThreadQueuedPrompt(prompt: prompt, cwd: cwd)
        }
        router.botThreadRunStarted = { [weak self] runID, threadID in
            guard let self,
                  let conversation = try? self.botStore.conversationLinked(to: threadID) else { return }
            self.deskAgentRunStarted(
                botID: conversation.botID,
                conversationID: conversation.id,
                runID: runID
            )
        }
    }

    /// Deleted or missing bots refuse the send with a recovery hint.
    private func liveBotForWorkspaceRun(_ botID: BotID) throws -> BotDefinition {
        let stored = try? botStore.get(id: botID)
        guard let bot = stored ?? nil, bot.deletedAt == nil else {
            let label = (stored ?? nil).map { "Bot \($0.name)" } ?? "Bot"
            throw BotDeskSendRefused(reason: "\(label) foi apagado. Use \"Continuar sem bot\".")
        }
        return bot
    }

    /// First bot send on a workspace thread: link the existing thread to a new bot
    /// conversation (single thread, no copy). Idempotent for the same bot.
    private func linkWorkspaceThread(_ threadID: AgentThreadID, toBot botID: BotID) throws {
        let bot = try liveBotForWorkspaceRun(botID)
        if let existing = try botStore.conversationLinked(to: threadID) {
            guard existing.botID == bot.id else {
                throw BotDeskSendRefused(reason: "Esta conversa já pertence a outro bot.")
            }
            return
        }
        guard let thread = try context.threadRepo.get(id: threadID) else {
            throw BotDeskSendRefused(reason: "A conversa sumiu antes de iniciar.")
        }
        let conversation = BotConversation(
            botID: bot.id,
            title: thread.title,
            linkedAgentThreadID: threadID
        )
        try botStore.upsertConversation(conversation)
        adoptFollowThroughConversation(conversation)
    }

    func lastStartedConversationForTesting(botID: BotID) -> BotConversation? {
        lastStartedConversationByBot[botID]
    }

    private func tearDownDeskAgentVM() {
        deskAgentKey = nil
        guard let vm = deskAgentVM else { return }
        deskAgentVM = nil
        vm.dispose()
    }

    /// Bot-specific half of a desk send: admission, then brain compile. The raw
    /// user text stays the visible message; the compiled payload is the prompt.
    private func compileDeskPrompt(
        botID: BotID,
        conversationID: BotConversationID,
        text: String,
        threadID: AgentThreadID,
        runID: AgentRunID
    ) throws -> String {
        guard let bot = bots.first(where: { $0.id == botID }) ?? (try? botStore.get(id: botID)),
              let revision = try currentRevision(for: bot) else {
            throw BotDeskSendRefused(reason: "Bot runtime is unavailable.")
        }
        if selectedBotID == botID, let message = deskDistillEffortValidationMessage {
            throw BotDeskSendRefused(reason: message)
        }
        do {
            try admitDesktopSend(bot: bot)
        } catch {
            switch guestLaunchState(for: bot.id) {
            case .starting:
                throw BotDeskSendRefused(reason: "Linux desktop is starting. Try again when it is ready.")
            case .failed(let message):
                throw BotDeskSendRefused(reason: message)
            case .idle:
                throw BotDeskSendRefused(reason: "Docker desktop is not ready.")
            }
        }
        let thread = try context.threadRepo.get(id: threadID)
        let routing = thread.map { BotDeskRouting(thread: $0) } ?? deskRouting
        let model = routing.resolvedModel(defaultModel: Self.defaultModel(for:))
        let conversation = conversations.first(where: { $0.id == conversationID })
            ?? ((try? botStore.conversation(id: conversationID)) ?? nil)
        let brain = destBrainInputs(for: bot)
        let receipt = BotBrainCompiler.assemble(
            bot: bot,
            revision: revision,
            userText: text,
            memoryFiles: brain.memoryFiles,
            skills: brain.skills,
            ownedSkills: ownedSkillTexts(for: bot),
            routines: brain.routines,
            workspace: nil,
            browser: advertisedBrowser,
            conversationID: conversation?.id ?? conversationID,
            liveRunMode: routing.permissionMode,
            runProvider: routing.provider,
            runModel: model,
            turnDirective: BotPeerDelegation.turnDirective(
                mentionedBots: BotMentionParser.mentionedBots(
                    in: text,
                    bots: bots,
                    excluding: bot.id
                )
            )
        )
        lastSupervisedRunUserTextForTesting = text
        pendingDeskReceipts[runID] = receipt
        if let conversation {
            _ = try? persistUserMessage(
                bot: bot,
                text: text,
                adoptSelection: selectedConversation?.id == conversation.id,
                conversationID: conversation.id
            )
        }
        return Self.supervisedRunPrompt(
            userText: text,
            compiledPayload: receipt.compiledPayload,
            provider: routing.provider
        )
    }

    /// Distill resolves `/name args` only when the prompt starts with the slash;
    /// the brain wrap would bury it, so slash commands go through raw. Shared by
    /// the embedded desk and the paired-device (iOS) supervised run.
    nonisolated static func supervisedRunPrompt(
        userText: String,
        compiledPayload: String,
        provider: AgentProvider
    ) -> String {
        if provider == .distill,
           userText.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") {
            return userText
        }
        return compiledPayload
    }

    private func deskAgentRunStarted(
        botID: BotID,
        conversationID: BotConversationID,
        runID: AgentRunID
    ) {
        guard let bot = bots.first(where: { $0.id == botID }) ?? (try? botStore.get(id: botID)),
              let conversation = conversations.first(where: { $0.id == conversationID })
                ?? (try? botStore.conversation(id: conversationID)) ?? nil else { return }
        lastLinkedRunIDByBot[botID] = runID
        lastSendStartedProviderRun = true
        if let receipt = pendingDeskReceipts.removeValue(forKey: runID) {
            recordStartedRun(bot: bot, conversation: conversation, receipt: receipt, resultRunID: runID)
        } else {
            _ = try? persistWorkingConversation(conversation)
        }
        restoreDeskWorkLog(botID: botID)
        restoreDeskLiveTurn(botID: botID)
    }

    /// Peer rows persisted for the linked thread repaint in the embedded desk.
    func applyDeskPeerMessage(
        messageID: AgentMessageID,
        threadID: AgentThreadID,
        terminalStatus: AgentRunStatus?
    ) {
        deskAgentVM?.applyPersistedBotPeerMessage(
            messageID: messageID,
            threadId: threadID,
            terminalStatus: terminalStatus
        )
    }

    /// Reuses the conversation's linked thread (drifting model/effort/permission
    /// in place) or creates it. Shared by the send path and the embedded desk.
    private func ensureLinkedThread(
        bot: BotDefinition,
        conversation: BotConversation,
        routing: BotDeskRouting,
        router: AppCommandRouter,
        markStarted: Bool = true
    ) throws -> (thread: AgentThread, conversation: BotConversation) {
        let model = routing.resolvedModel(defaultModel: Self.defaultModel(for:))
        var liveConversation = conversation
        // 1.8: Bot runs use BotHome as cwd (not "/") so provider file tools
        // operate inside the bot's home directory. Workspace-less threads
        // fall back to BotHome via executionCwdOverride at send time.
        let botHomeURL = BotHome(appSupportDirectory: context.appSupportDirectory, bot: bot).root
        try FileManager.default.createDirectory(at: botHomeURL, withIntermediateDirectories: true)
        let thread: AgentThread
        let reusableThread: AgentThread? = try conversation.linkedAgentThreadID.flatMap { linked -> AgentThread? in
            guard let existing = try context.threadRepo.get(id: linked),
                  !threadBelongsToAnotherBot(linked, botID: bot.id),
                  existing.provider == routing.provider,
                  existing.providerInstanceId == routing.providerInstanceID else { return nil }
            let existingRunAsUser = existing.runAsUser ?? AgentRunAsUser.current()
            guard existingRunAsUser.uid == routing.runAsUser.uid,
                  existingRunAsUser.shortName == routing.runAsUser.shortName else { return nil }
            // 1.3: model/reasoning/permission drift updates the existing thread
            // in place instead of forking a new thread and losing history.
            var updated = existing
            var didUpdate = false
            if updated.model != model { updated.model = model; didUpdate = true }
            if updated.reasoningEffort != routing.reasoningEffort { updated.reasoningEffort = routing.reasoningEffort; didUpdate = true }
            if updated.reasoningModel != routing.reasoningModel { updated.reasoningModel = routing.reasoningModel; didUpdate = true }
            if updated.permissionMode != routing.permissionMode { updated.permissionMode = routing.permissionMode; didUpdate = true }
            if updated.serviceTier != routing.serviceTier { updated.serviceTier = routing.serviceTier; didUpdate = true }
            if didUpdate {
                updated.modelSelection = AgentModelSelection(
                    provider: routing.provider,
                    modelId: model,
                    reasoningEffort: routing.reasoningEffort,
                    serviceTier: routing.serviceTier,
                    distillMainEffortSelection: routing.provider == .distill
                        ? (routing.distillMainEffortSelection ?? .fixed(routing.reasoningEffort)) : nil,
                    distillReasoningEffortSelection: routing.provider == .distill
                        ? (routing.distillReasoningEffortSelection ?? .automatic) : nil
                )
                try context.threadRepo.upsert(updated)
            }
            return updated
        }
        if let reusableThread {
            thread = reusableThread
        } else {
            var createdThread = try router.createAgentThread(
                workspace: nil,
                title: conversation.title,
                provider: routing.provider,
                model: model,
                permissionMode: routing.permissionMode,
                reasoningEffort: routing.reasoningEffort,
                serviceTier: routing.serviceTier,
                modelSelection: AgentModelSelection(
                    provider: routing.provider,
                    modelId: model,
                    reasoningEffort: routing.reasoningEffort,
                    serviceTier: routing.serviceTier,
                    distillMainEffortSelection: routing.provider == .distill
                        ? (routing.distillMainEffortSelection ?? .fixed(routing.reasoningEffort)) : nil,
                    distillReasoningEffortSelection: routing.provider == .distill
                        ? (routing.distillReasoningEffortSelection ?? .automatic) : nil
                ),
                providerInstanceId: routing.providerInstanceID,
                runAsUser: routing.runAsUser,
                surfaceID: nil,
                routingConfiguration: nil,
                quiet: true
            )
            createdThread.reasoningModel = routing.reasoningModel
            try context.threadRepo.upsert(createdThread)
            thread = createdThread
            liveConversation.linkedAgentThreadID = thread.id
            try botStore.upsertConversation(liveConversation)
            if markStarted {
                lastStartedConversationByBot[liveConversation.botID] = liveConversation
            }
            adoptFollowThroughConversation(liveConversation)
        }
        return (thread, liveConversation)
    }

    private func prepareSupervisedRun(
        bot: BotDefinition,
        conversation: BotConversation,
        routing: BotDeskRouting,
        router: AppCommandRouter,
        runID: AgentRunID = AgentRunID()
    ) throws -> BotStartedRun {
        let (thread, liveConversation) = try ensureLinkedThread(
            bot: bot,
            conversation: conversation,
            routing: routing,
            router: router
        )
        // The rail memo is filled per id and never re-read: a send that drifts
        // the model on the existing thread must republish the row it wrote, or
        // the chip keeps painting the model the thread had before this send.
        deskThreadRailRoutingCache[thread.id] = BotDeskThreadRailRouting(
            provider: thread.provider,
            model: thread.model
        )
        armExactRun(runID)
        return BotStartedRun(
            conversation: liveConversation,
            thread: thread,
            runID: runID,
            routing: routing
        )
    }

    @discardableResult
    private func enqueueSupervisedBotRun(
        bot: BotDefinition,
        conversation: BotConversation,
        userText: String,
        attachments: [AgentAttachment],
        routingOverride: BotDeskRouting? = nil
    ) throws -> BotStartedRun? {
        // Dest first. Send used to listMemory/listSkillBindings after the
        // bubble painted. Both Desk and host-catalog sends snapshot the same
        // cached brain before starting the provider.
        let brain = destBrainInputs(for: bot)
        lastSendUsedDestBrainForTesting = selectedBotID == bot.id
        guard let router = resolvedRouter(),
              let revision = try currentRevision(for: bot) else {
            recordNeedsAttention(bot: bot, conversation: conversation, userText: userText)
            return nil
        }
        let routing = routingOverride ?? frozenDeskRouting(for: conversation)
        let prepared = try prepareSupervisedRun(
            bot: bot,
            conversation: conversation,
            routing: routing,
            router: router
        )
        beginDeskSendInFlight(for: bot.id)
        let epoch = deskStopEpoch[bot.id] ?? 0
        let work = DeskSendWork()
        work.threadID = prepared.thread.id
        work.runID = prepared.runID
        context.coordinator.reserveProviderStart(threadId: prepared.thread.id, runId: prepared.runID)
        work.task = EventBus.outsideMutationCapture {
            Task { [weak self] in
                guard let self else { return }
                defer {
                    if let threadID = work.threadID, let runID = work.runID {
                        self.context.coordinator.discardProviderStartReservation(
                            threadId: threadID,
                            runId: runID
                        )
                    }
                }
                await Task.yield()
                guard !Task.isCancelled, (self.deskStopEpoch[bot.id] ?? 0) == epoch else {
                    self.forgetDeskSend(work, botID: bot.id)
                    self.clearDeskSendInFlight(for: bot.id)
                    return
                }
                while let join = self.deskStopJoins[bot.id] {
                    if Task.isCancelled || (self.deskStopEpoch[bot.id] ?? 0) != epoch {
                        self.forgetDeskSend(work, botID: bot.id)
                        self.clearDeskSendInFlight(for: bot.id)
                        return
                    }
                    if (self.deskSendTasks[bot.id] ?? []).contains(where: { $0 === work }) {
                        await Task.yield()
                        continue
                    }
                    _ = await join.task.value
                    break
                }
                guard !Task.isCancelled, (self.deskStopEpoch[bot.id] ?? 0) == epoch else {
                    self.forgetDeskSend(work, botID: bot.id)
                    self.clearDeskSendInFlight(for: bot.id)
                    return
                }
                let started = await self.startSupervisedRun(
                    bot: bot,
                    revision: revision,
                    prepared: prepared,
                    userText: userText,
                    attachments: attachments,
                    memoryFiles: brain.memoryFiles,
                    skills: brain.skills,
                    routines: brain.routines,
                    router: router,
                    expectedEpoch: epoch
                )
                self.forgetDeskSend(work, botID: bot.id)
                self.clearDeskSendInFlight(for: bot.id)
                if let started {
                    self.lastSendStartedProviderRun = true
                    self.lastLinkedRunIDByBot[bot.id] = started.runID
                    self.restoreDeskWorkLog(botID: bot.id)
                    self.restoreDeskLiveTurn(botID: bot.id)
                    _ = await self.followLinkedRun(bot: bot, started: started)
                } else {
                    self.deskSendInFlightStartedAt = nil
                    self.recordNeedsAttention(bot: bot, conversation: prepared.conversation, userText: userText)
                }
            }
        }
        rememberDeskSend(work, botID: bot.id)
        return prepared
    }

    /// Dest persist cannot unstart a live provider turn: bookkeeping after the
    /// provider accepted a bot turn (Desk send path and the embedded Agent App).
    private func recordStartedRun(
        bot: BotDefinition,
        conversation: BotConversation,
        receipt: ContextAssemblyReceipt,
        resultRunID: AgentRunID?
    ) {
        var receipt = receipt
        _ = try? persistWorkingConversation(conversation)
        _ = try? botStore.insertContextReceipt(receipt)
        if selectedBotID == bot.id {
            lastContextReceipt = receipt
            rememberStudioSupport(for: bot.id)
        }
        if let runId = resultRunID {
            receipt.runID = runId
            try? botStore.insertContextReceipt(receipt)
            if selectedBotID == bot.id {
                lastContextReceipt = receipt
            }
        }
    }

    private func startSupervisedRun(
        bot: BotDefinition,
        revision: BotRevision,
        prepared: BotStartedRun,
        userText: String,
        attachments: [AgentAttachment] = [],
        memoryFiles: [BotMemoryFileText],
        skills: [BotSkillBinding],
        routines: [BotRoutine] = [],
        router: AppCommandRouter,
        expectedEpoch: Int
    ) async -> BotStartedRun? {
        guard !Task.isCancelled, (deskStopEpoch[bot.id] ?? 0) == expectedEpoch else {
            return nil
        }
        let routing = prepared.routing
        let model = routing.resolvedModel(defaultModel: Self.defaultModel(for:))
        let effort = routing.reasoningEffort
        lastDeskRunProviderForTesting = routing.provider
        lastDeskRunModelForTesting = model
        lastDeskRunPermissionForTesting = routing.permissionMode
        lastDeskRunReasoningForTesting = effort
        do {
            lastSupervisedRunUserTextForTesting = userText
            supervisedRunBotIDsForTesting.append(bot.id)
            if selectedBotID == bot.id, screen == .desk {
                startDeskLiveTurnWatch(botID: bot.id, threadID: prepared.thread.id)
            }
            let compressedUser = await context.tokenSaverCompress(
                prompt: userText,
                provider: routing.provider,
                threadId: prepared.thread.id,
                runId: prepared.runID
            )
            let receipt = BotBrainCompiler.assemble(
                bot: bot,
                revision: revision,
                userText: compressedUser,
                memoryFiles: memoryFiles,
                skills: skills,
                ownedSkills: ownedSkillTexts(for: bot),
                routines: routines,
                workspace: nil,
                browser: advertisedBrowser,
                conversationID: prepared.conversation.id,
                liveRunMode: routing.permissionMode,
                runProvider: routing.provider,
                runModel: model,
                turnDirective: BotPeerDelegation.turnDirective(
                    mentionedBots: BotMentionParser.mentionedBots(
                        in: userText,
                        bots: bots,
                        excluding: bot.id
                    )
                )
            )
            // Dest already listed Source on open. Stamp that catalog so
            // sendAgentMessage preflight does not rediscover models.
            if !providers.isEmpty {
                router.rememberProviderSnapshotsForSend(providers)
            }
            try persistDeskTokenSaverUserTranslation(
                threadID: prepared.thread.id,
                runID: prepared.runID,
                botID: bot.id,
                conversationID: prepared.conversation.id,
                humanText: userText,
                attachments: attachments,
                wireRequest: compressedUser
            )
            beforeBotRunDispatchForTesting?(prepared.runID)
            guard !Task.isCancelled, (deskStopEpoch[bot.id] ?? 0) == expectedEpoch else {
                cancelExactRunWait(prepared.runID)
                return nil
            }
            // 1.8: Bot threads are workspace-less; provider file tools
            // must start in the bot's home directory, not "/".
            let botHomeCwd = BotHome(appSupportDirectory: context.appSupportDirectory, bot: bot).root.path
            try? FileManager.default.createDirectory(at: URL(fileURLWithPath: botHomeCwd), withIntermediateDirectories: true)
            let result = try await router.sendAgentMessage(
                thread: prepared.thread.id,
                text: Self.supervisedRunPrompt(
                    userText: userText,
                    compiledPayload: receipt.compiledPayload,
                    provider: routing.provider
                ),
                provider: routing.provider,
                model: model,
                permissionMode: routing.permissionMode,
                reasoningEffort: effort,
                serviceTier: routing.serviceTier,
                modelSelection: AgentModelSelection(
                    provider: routing.provider,
                    modelId: model,
                    reasoningEffort: effort,
                    serviceTier: routing.serviceTier,
                    distillMainEffortSelection: routing.provider == .distill
                        ? (routing.distillMainEffortSelection ?? .fixed(effort)) : nil,
                    distillReasoningEffortSelection: routing.provider == .distill
                        ? (routing.distillReasoningEffortSelection ?? .automatic) : nil
                ),
                providerInstanceId: routing.providerInstanceID,
                attachments: attachments,
                requestedRunID: prepared.runID,
                executionCwdOverride: botHomeCwd
            )
            recordStartedRun(
                bot: bot,
                conversation: prepared.conversation,
                receipt: receipt,
                resultRunID: result.runId
            )
            guard result.runId == prepared.runID else {
                cancelExactRunWait(prepared.runID)
                return nil
            }
            return prepared
        } catch {
            cancelExactRunWait(prepared.runID)
            errorMessage = String(describing: error)
            return nil
        }
    }

    private func followLinkedRun(
        bot: BotDefinition,
        started: BotStartedRun
    ) async -> AgentRun? {
        if selectedBotID == bot.id, screen == .desk {
            startDeskLiveTurnWatch(botID: bot.id, threadID: started.thread.id)
        }
        let run = await awaitExactRunTerminal(started)
        guard let run else { return nil }
        applyFollowThrough(bot: bot, conversation: started.conversation, run: run)
        return run
    }

    private func armExactRun(_ runID: AgentRunID) {
        armedRunIDs.insert(runID)
    }

    private func cancelExactRunWait(_ runID: AgentRunID) {
        armedRunIDs.remove(runID)
        observedTerminalRuns[runID] = nil
        let waiters = exactRunWaiters.removeValue(forKey: runID) ?? []
        waiters.forEach { $0.resume(returning: nil) }
    }

    private func resumeExactRunWaiters(runID: AgentRunID, run: AgentRun) {
        armedRunIDs.remove(runID)
        observedTerminalRuns[runID] = nil
        let waiters = exactRunWaiters.removeValue(forKey: runID) ?? []
        waiters.forEach { $0.resume(returning: run) }
    }

    private func awaitExactRunTerminal(_ started: BotStartedRun) async -> AgentRun? {
        await awaitExactRunTerminal(runID: started.runID, threadID: started.thread.id)
    }

    private func awaitExactRunTerminal(
        runID: AgentRunID,
        threadID: AgentThreadID
    ) async -> AgentRun? {
        return await withCheckedContinuation { continuation in
            exactRunWaiters[runID, default: []].append(continuation)
            if let run = try? context.runRepo.get(id: runID),
               run.threadId == threadID,
               BotsDeskFollowThrough.isTerminal(run.status),
               run.status != .completed
                    || exactAssistantMessage(threadID: threadID, runID: runID) != nil {
                resumeExactRunWaiters(runID: runID, run: run)
                return
            }
            if let observed = observedTerminalRuns[runID] {
                resumeExactRunWaiters(runID: runID, run: observed)
            }
        }
    }

    private func hostRunCompletedExactly(
        _ run: AgentRun?,
        threadID: AgentThreadID,
        runID: AgentRunID
    ) -> Bool {
        guard run?.id == runID,
              run?.threadId == threadID,
              run?.status == .completed else { return false }
        return exactAssistantMessage(threadID: threadID, runID: runID) != nil
    }

    func markAgentAppHostDispatchFailed(activityMessageID: AgentMessageID) {
        guard let handoff = peerHandoffs[activityMessageID.value] else { return }
        if let runID = handoff.hostRunID { cancelExactRunWait(runID) }
        setHandoffPhase(activityMessageID.value, .needsAttention)
    }

    func markAgentAppHostDispatched(activityMessageID: AgentMessageID) {
        setHandoffPhase(activityMessageID.value, .hostRunning)
    }

    func settleAgentAppHost(activityMessageID: AgentMessageID) async {
        guard let handoff = peerHandoffs[activityMessageID.value],
              let threadID = handoff.hostThreadID,
              let runID = handoff.hostRunID else {
            setHandoffPhase(activityMessageID.value, .needsAttention)
            return
        }
        armExactRun(runID)
        let run = await awaitExactRunTerminal(runID: runID, threadID: threadID)
        setHandoffPhase(
            activityMessageID.value,
            hostRunCompletedExactly(run, threadID: threadID, runID: runID)
                ? .completed
                : .needsAttention
        )
    }

    private func resolveExactRunWaiters(
        runID: AgentRunID,
        threadID: AgentThreadID,
        finalMessage _: String?,
        providerThreadID _: String?
    ) {
        guard armedRunIDs.contains(runID),
              let run = try? context.runRepo.get(id: runID),
              run.threadId == threadID,
              BotsDeskFollowThrough.isTerminal(run.status) else { return }
        if exactRunWaiters[runID]?.isEmpty == false {
            resumeExactRunWaiters(runID: runID, run: run)
        } else {
            observedTerminalRuns[runID] = run
        }
    }

    private func enqueueFollowUp(_ item: BotQueuedFollowUp, botID: BotID) {
        queuedFollowUpsByBot[botID, default: []].append(item)
        persistQueuedFollowUps()
        syncQueuedFollowUps()
    }

    private func syncQueuedFollowUps() {
        queuedFollowUps = selectedBotID.flatMap { queuedFollowUpsByBot[$0] } ?? []
    }

    private func drainQueuedFollowUp() {
        guard let bot = selectedBot else { return }
        guard !deskRunIsLive else { return }
        guard let next = queuedFollowUpsByBot[bot.id]?.first else {
            syncQueuedFollowUps()
            return
        }
        composerText = next.text
        attachments = next.attachments
        guard send() else { return }
        queuedFollowUpsByBot[bot.id]?.removeAll { $0.id == next.id }
        if queuedFollowUpsByBot[bot.id]?.isEmpty == true {
            queuedFollowUpsByBot[bot.id] = nil
        }
        persistQueuedFollowUps()
        syncQueuedFollowUps()
    }

    /// Host sends are accepted for an exact conversation even when the user is
    /// looking at another Bot. Drain those after that conversation's terminal
    /// transition without borrowing selection/composer state from the UI.
    private func drainHostQueuedFollowUp(
        bot: BotDefinition,
        conversation: BotConversation
    ) {
        guard let index = queuedFollowUpsByBot[bot.id]?.firstIndex(where: {
            $0.conversationID == conversation.id
        }), let next = queuedFollowUpsByBot[bot.id]?[index] else { return }
        if let threadID = conversation.linkedAgentThreadID,
           context.coordinator.activeRunId(threadId: threadID) != nil {
            return
        }
        do {
            try admitDesktopSend(bot: bot)
            let display = AgentChatTranscriptChrome.displayUserLine(
                text: next.text,
                attachments: next.attachments
            )
            let target = try persistUserMessage(
                bot: bot,
                text: display,
                adoptSelection: false,
                conversationID: conversation.id
            )
            appendDeskMessage(
                BotDeskMessage(role: .user, text: display),
                botID: bot.id,
                conversationID: target.id
            )
            if let started = try enqueueSupervisedBotRun(
                bot: bot,
                conversation: target,
                userText: next.text,
                attachments: next.attachments,
                routingOverride: next.routing
            ) {
                stampDeskUserMessageIdentity(runID: started.runID, botID: bot.id)
            }
        } catch {
            errorMessage = String(describing: error)
            return
        }
        queuedFollowUpsByBot[bot.id]?.removeAll { $0.id == next.id }
        if queuedFollowUpsByBot[bot.id]?.isEmpty == true {
            queuedFollowUpsByBot[bot.id] = nil
        }
        persistQueuedFollowUps()
        syncQueuedFollowUps()
    }

    private func applyFollowThrough(
        bot: BotDefinition,
        conversation: BotConversation,
        run: AgentRun?
    ) {
        followThroughApplyCountForTesting += 1
        var next = destFollowThroughConversation(for: bot, fallback: conversation)
        if next.linkedAgentThreadID == nil {
            next.linkedAgentThreadID = conversation.linkedAgentThreadID
        }
        restoreDeskMessages(botID: bot.id)
        if let run {
            lastLinkedRunIDByBot[bot.id] = run.id
        }
        let status = run?.status ?? .interrupted
        let reason = run?.terminalReason
        restoreDeskWorkLog(botID: bot.id, preferredRun: run)
        restoreDeskLiveTurn(
            botID: bot.id,
            reconcileObservedAtTerminal: BotsDeskFollowThrough.isTerminal(status)
        )
        refreshPublishedIdentity(for: bot.id)
        let viewingDesk = isViewing(bot.id)
        next.attentionState = BotsDeskFollowThrough.conversationState(
            for: status,
            viewingDesk: viewingDesk,
            terminalReason: reason
        )
        if viewingDesk {
            next.unread = false
        } else if status == .completed {
            next.unread = true
        }
        next.updatedAt = Date()
        do {
            // Dest first. Follow-through used to listConversations,
            // listAttention, and reloadFleet (every teammate's
            // conversations + recent messages) after dest already
            // painted the completed turn. The upserted row is dest
            // state; dest must not scan the fleet to settle.
            try botStore.upsertConversation(next)
            adoptFollowThroughConversation(next)
            if let kind = BotsDeskFollowThrough.attentionKind(for: status, terminalReason: reason) {
                let item = BotAttentionItem(
                    botID: bot.id,
                    conversationID: next.id,
                    kind: kind,
                    title: BotsDeskFollowThrough.attentionTitle(for: status, terminalReason: reason),
                    detail: run?.errorMessage ?? "The supervised turn ended without a clean completion."
                )
                try botStore.upsertAttention(item)
                adoptWrittenAttention(item)
            }
            applyAttentionState(
                for: bot.id,
                conversations: destConversations(botID: bot.id, patched: next)
            )
            Self.publishDestAttentionChanged()
        } catch {
            errorMessage = String(describing: error)
        }
        isStopping = false
        clearDeskSendInFlight(for: bot.id)
        if BotsDeskFollowThrough.isTerminal(status) {
            deskSendInFlightStartedAt = nil
            drainHostQueuedFollowUp(bot: bot, conversation: next)
            if isViewing(bot.id) {
                drainQueuedFollowUp()
            }
        }
    }

    private func beginDeskSendInFlight(for botID: BotID) {
        deskSendInFlightBotID = botID
        deskSendInFlight = true
        deskSendInFlightStartedAt = Date()
        deskTimelineRejoinToken &+= 1
    }

    private func clearDeskSendInFlight(for botID: BotID) {
        guard deskSendInFlightBotID == nil || deskSendInFlightBotID == botID else { return }
        if !(deskSendTasks[botID] ?? []).isEmpty { return }
        deskSendInFlight = false
        deskSendInFlightBotID = nil
    }

    private func rememberDeskSend(_ work: DeskSendWork, botID: BotID) {
        deskSendTasks[botID, default: []].append(work)
    }

    private func forgetDeskSend(_ work: DeskSendWork, botID: BotID) {
        guard var works = deskSendTasks[botID] else { return }
        works.removeAll { $0 === work }
        if works.isEmpty {
            deskSendTasks[botID] = nil
        } else {
            deskSendTasks[botID] = works
        }
    }

    private func takeDeskSendWorks(for botID: BotID) -> [DeskSendWork] {
        deskSendTasks.removeValue(forKey: botID) ?? []
    }

    public var dockerDesktopSelectable: Bool {
        BotDesktopKind.dockerDesktop.isSelectable(
            flags: settingsStore.load().botControlPlaneFlags,
            guestReady: dockerGuestReady
        )
    }

    public var dockerDesktopStatus: String? {
        if dockerDesktopSelectable { return nil }
        return dockerGuestProbeReason ?? "Guest is proving the screen…"
    }

    /// Machine probe. Tests inject a ready/not-ready override.
    public var dockerGuestReadyOverrideForTesting: Bool?
    public var desktopKindOverrideForTesting: BotDesktopKind?
    public var dockerGuestProbeReason: String?
    @Published public var lastGuestScreenURL: URL?
    @Published public var guestScreenURLByBot: [UUID: URL] = [:]
    @Published public var guestRunningByBot: [UUID: Bool] = [:]
    @Published private var guestRebuildingByBot: [UUID: Bool] = [:]
    @Published private(set) var guestLaunchStateByBot: [UUID: BotComputerGuestLaunchState] = [:]

    func guestScreenURL(for botID: BotID) -> URL? {
        guestScreenURLByBot[botID.value]
    }

    func isGuestRunning(_ botID: BotID) -> Bool {
        guestRunningByBot[botID.value] == true
    }

    func isGuestRebuilding(_ botID: BotID) -> Bool {
        guestRebuildingByBot[botID.value] == true
    }

    func guestLaunchState(for botID: BotID) -> BotComputerGuestLaunchState {
        guestLaunchStateByBot[botID.value] ?? .idle
    }

    func rememberGuestScreen(url: URL, botID: BotID, running: Bool) {
        guestScreenURLByBot[botID.value] = url
        guestRunningByBot[botID.value] = running
        if running {
            guestLaunchStateByBot[botID.value] = .idle
        }
        if selectedBotID == botID {
            lastGuestScreenURL = url
        }
        objectWillChange.send()
    }

    func presentGuestDesktop(botID: BotID, onSettled: ((BotComputerGuestReady?) -> Void)? = nil) {
        guard guestLaunchState(for: botID) != .starting else {
            DispatchQueue.main.async { onSettled?(nil) }
            return
        }
        guard dockerGuestReadyOverrideForTesting == nil,
              let service = computerGuestService else {
            guestLaunchStateByBot[botID.value] = .failed(
                BotComputerDockerError.cliMissing.description
            )
            DispatchQueue.main.async { onSettled?(nil) }
            return
        }
        guestLaunchStateByBot[botID.value] = .starting
        Task.detached {
            do {
                let ready = try service.provision(botID: botID)
                let url = try BotComputerGuestSpec.viewerURL(ready.screenURL)
                await MainActor.run {
                    self.rememberGuestScreen(url: url, botID: botID, running: true)
                    onSettled?(ready)
                }
            } catch {
                await MainActor.run {
                    self.dockerGuestProbeReason = String(describing: error)
                    self.guestRunningByBot[botID.value] = false
                    self.guestLaunchStateByBot[botID.value] = .failed(
                        (error as? BotComputerDockerError)?.description
                            ?? BotComputerDockerError.provisioningFailed.description
                    )
                    self.objectWillChange.send()
                    onSettled?(nil)
                }
            }
        }
    }

    func stopDockerGuest(botID: BotID, onSettled: ((Bool) -> Void)? = nil) {
        guard let service = computerGuestService else {
            DispatchQueue.main.async { onSettled?(false) }
            return
        }
        Task.detached { [service] in
            do {
                try service.stop(botID: botID)
                await MainActor.run {
                    self.guestRunningByBot[botID.value] = false
                    self.guestLaunchStateByBot[botID.value] = .idle
                    self.objectWillChange.send()
                    onSettled?(true)
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Could not stop the Linux desktop."
                    onSettled?(false)
                }
            }
        }
    }

    func rebuildDockerGuest(botID: BotID, onSettled: ((BotComputerGuestReady?) -> Void)? = nil) {
        guard !isGuestRebuilding(botID) else {
            DispatchQueue.main.async { onSettled?(nil) }
            return
        }
        guard let service = computerGuestService else {
            errorMessage = "Docker desktop is not ready."
            DispatchQueue.main.async { onSettled?(nil) }
            return
        }
        let wasRunning = isGuestRunning(botID)
        guestRebuildingByBot[botID.value] = true
        Task.detached {
            do {
                let ready = try service.rebuild(botID: botID)
                let url = try BotComputerGuestSpec.viewerURL(ready.screenURL)
                await MainActor.run {
                    self.guestRebuildingByBot[botID.value] = false
                    self.rememberGuestScreen(url: url, botID: botID, running: true)
                    onSettled?(ready)
                }
            } catch {
                await MainActor.run {
                    self.guestRebuildingByBot[botID.value] = false
                    self.errorMessage = wasRunning
                        ? "Could not rebuild the Linux desktop. The current desktop is still running."
                        : "Could not rebuild the Linux desktop."
                    onSettled?(nil)
                }
            }
        }
    }

    public var dockerGuestReady: Bool {
        if let dockerGuestReadyOverrideForTesting { return dockerGuestReadyOverrideForTesting }
        return computerGuestService?.lastReady != nil
    }

    public func admitDesktopSend(bot: BotDefinition) throws {
        let revision = try currentRevision(for: bot)
        let kind = desktopKindOverrideForTesting
            ?? resolvedDesktopKind(revision?.desktopKind ?? .logicalExecutionSpace)
        let ready: Bool
        if let dockerGuestReadyOverrideForTesting {
            ready = dockerGuestReadyOverrideForTesting
        } else if kind == .dockerDesktop {
            ready = isGuestRunning(bot.id)
            if !ready {
                presentGuestDesktop(botID: bot.id)
            }
        } else {
            ready = dockerGuestReady
        }
        _ = try BotDesktopAdmission.requireSend(kind: kind, guestReady: ready)
    }

    private var dockerGuestProbeTask: Task<Void, Never>?
    private var dockerGuestProbeGeneration = 0

    public func refreshDockerGuestProbe() {
        guard dockerGuestReadyOverrideForTesting == nil else { return }
        guard let service = computerGuestService else { return }
        guard dockerGuestProbeTask == nil else { return }
        dockerGuestProbeGeneration += 1
        let generation = dockerGuestProbeGeneration
        dockerGuestProbeTask = Task.detached { [weak self] in
            let ready = service.proveReady()
            await MainActor.run {
                guard let self, self.dockerGuestProbeGeneration == generation else { return }
                self.dockerGuestProbeReason = ready ? nil : service.lastReason
                self.objectWillChange.send()
                self.dockerGuestProbeTask = nil
            }
        }
    }

    private func resolvedDesktopKind(_ requested: BotDesktopKind) -> BotDesktopKind {
        let flags = settingsStore.load().botControlPlaneFlags
        if requested.isSelectable(flags: flags, guestReady: dockerGuestReady) {
            return requested
        }
        if requested == .dockerDesktop, selectedRevision?.desktopKind == .dockerDesktop {
            return .dockerDesktop
        }
        return requested.advertisedOrLogical == .botOwnedBrowser ? .botOwnedBrowser : .logicalExecutionSpace
    }

    private static func shouldDestTitleAsBubble(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != "New thread"
    }

    private static func titleFromFirstMessage(_ text: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.count <= 72 { return collapsed }
        return String(collapsed.prefix(72))
    }

    static func composeRunPrompt(bot: BotDefinition, revision: BotRevision, userText: String) -> String {
        BotsDeskFollowThrough.composeRunPrompt(bot: bot, revision: revision, userText: userText)
    }

    /// Persist + chip used to stay Working after the linked run was Done.
    /// Finish events and relaunch must settle that row, not just refresh
    /// Active Bots from the stale attention flag.
    public private(set) var followThroughApplyCountForTesting = 0

    /// `false` only when this terminal already settled — the caller pairs its
    /// Active Bots refresh with the `true` pass so the duplicate callback does
    /// not re-run the roster queries.
    @discardableResult
    private func adoptLinkedRunTerminal(runId: AgentRunID, threadId: AgentThreadID) -> Bool {
        // BT-24: `didChangeStatus(terminal)` and `didFinish` both deliver the
        // same terminal; the second pass re-ran every restore + SQLite write.
        // BT-28: that second pass also re-ran `refreshActiveBotCount()`
        // (two roster queries + coordinator lock); the refresh rides the
        // first settle now.
        guard settledTerminalRunIDByThread[threadId] != runId else { return false }
        settledTerminalRunIDByThread[threadId] = runId
        if botStore.cachedBotID(linkedTo: threadId) == nil {
            if screen == .desk,
               let botID = selectedBotID,
               selectedConversation?.linkedAgentThreadID == threadId {
                restoreDeskWorkLog(botID: botID)
                restoreDeskLiveTurn(botID: botID)
            }
            return true
        }
        guard let conversation = try? botStore.conversationLinked(to: threadId) else {
            if screen == .desk,
               let botID = selectedBotID,
               selectedConversation?.linkedAgentThreadID == threadId {
                restoreDeskWorkLog(botID: botID)
                restoreDeskLiveTurn(botID: botID)
            }
            return true
        }
        let bot = bots.first(where: { $0.id == conversation.botID })
            ?? (try? botStore.get(id: conversation.botID))
        let run = try? context.runRepo.get(id: runId)
        if let bot {
            applyFollowThrough(bot: bot, conversation: conversation, run: run)
            return true
        }
        reloadActiveBotsScreen()
        return true
    }

    private func repairLegacyUserStopAttentionIfNeeded() {
        let proofs = (try? context.coordinator.terminalTransitionLedger?.records(reason: .userStop))?.map {
            BotStore.LegacyUserStopLedgerProof(
                runId: $0.runId,
                threadId: $0.threadId,
                eventTime: $0.eventTime,
                reason: $0.reason.rawValue
            )
        } ?? []
        try? botStore.repairLegacyUserStopAttention(proofs: proofs)
    }

    private var isSettlingTerminalWorking = false

    private func settleTerminalWorkingConversations() {
        guard !isSettlingTerminalWorking else { return }
        isSettlingTerminalWorking = true
        defer { isSettlingTerminalWorking = false }
        for bot in bots {
            settleTerminalWorkingConversation(bot: bot)
        }
    }

    private func settleTerminalWorkingConversation(bot: BotDefinition) {
        guard let conversation = workingConversation(for: bot.id) else { return }
        guard let threadID = conversation.linkedAgentThreadID else { return }
        let activeIDs = activeThreadIDsOverrideForTesting
            ?? context.coordinator.activeThreadIdsSnapshot()
        if activeIDs.contains(threadID) { return }
        guard let run = linkedRun(for: threadID, botID: bot.id),
              BotsDeskFollowThrough.isTerminal(run.status) else { return }
        applyFollowThrough(bot: bot, conversation: conversation, run: run)
    }

    private func workingConversation(for botID: BotID) -> BotConversation? {
        if let hit = destConversations(botID: botID).first(where: { $0.attentionState == .working }) {
            return hit
        }
        if let selected = selectedConversation, selected.botID == botID, selected.attentionState == .working {
            return selected
        }
        return nil
    }

    func adoptLinkedRunTerminalForTests(runId: AgentRunID, threadId: AgentThreadID) {
        adoptLinkedRunTerminal(runId: runId, threadId: threadId)
    }

    func applyFollowThroughForTests(
        bot: BotDefinition,
        conversation: BotConversation,
        status: AgentRunStatus,
        terminalReason: String? = nil
    ) {
        applyFollowThrough(
            bot: bot,
            conversation: conversation,
            run: AgentRun(
                threadId: conversation.linkedAgentThreadID ?? AgentThreadID(),
                provider: .claude,
                model: "test",
                status: status,
                finishedAt: Date(),
                terminalReason: terminalReason
            )
        )
    }
}

extension BotsViewModel: BotPeerHandoffAuthorityObserver {
    fileprivate func botPeerHandoffAuthority(
        _ authority: BotPeerHandoffAuthority,
        didApply delta: BotPeerHandoffDelta
    ) {
        if let current = delta.current {
            peerHandoffs[delta.activityID] = current
        } else {
            peerHandoffs[delta.activityID] = nil
        }
        if let errorMessage = delta.errorMessage {
            self.errorMessage = errorMessage
        }
        guard delta.previous != delta.current, let handoff = delta.current else { return }

        if let conversationID = handoff.originConversationID {
            if delta.previous == nil, let hostID = handoff.originBotID {
                let outbound = BotDeskMessage(
                    id: handoff.activityID,
                    role: .user,
                    text: handoff.outboundText,
                    createdAt: handoff.createdAt,
                    peer: deskPeer(
                        direction: .messaged,
                        botID: handoff.peerBotID,
                        name: handoff.peerName,
                        title: handoff.peerTitle,
                        handle: handoff.peerHandle,
                        avatarSymbol: handoff.peerAvatarSymbol,
                        activityPhase: .waiting
                    )
                )
                if !cachedMessages(botID: hostID, conversationID: conversationID)
                    .contains(where: { $0.id == outbound.id }) {
                    appendDeskMessage(outbound, botID: hostID, conversationID: conversationID)
                }
            }
            let activity: BotPeerActivityPhase?
            switch handoff.phase {
            case .peerPrepared, .peerRunning: activity = .waiting
            case .needsAttention: activity = .needsAttention
            default: activity = nil
            }
            updatePeerActivity(
                originConversationID: conversationID,
                messageID: delta.activityID,
                phase: activity
            )
            if delta.previous?.replyText == nil,
               let reply = handoff.replyText,
               let hostID = handoff.originBotID {
                let inbound = BotDeskMessage(
                    id: handoff.inboundMessageID,
                    role: .assistant,
                    text: reply,
                    createdAt: handoff.replyCreatedAt ?? handoff.createdAt,
                    peer: deskPeer(
                        direction: .fromPeer,
                        botID: handoff.peerBotID,
                        name: handoff.peerName,
                        title: handoff.peerTitle,
                        handle: handoff.peerHandle,
                        avatarSymbol: handoff.peerAvatarSymbol
                    )
                )
                if !cachedMessages(botID: hostID, conversationID: conversationID)
                    .contains(where: { $0.id == inbound.id }) {
                    appendDeskMessage(inbound, botID: hostID, conversationID: conversationID)
                }
                if handoff.hostRunID != nil {
                    lastHopUserTextForTesting = BotPeerTranscript.hostHopPrompt(
                        peerName: handoff.peerName,
                        reply: reply,
                        userText: handoff.resolvedHostInstructionText
                    )
                }
            }
        }

        switch handoff.phase {
        case .peerRunning:
            lastSendStartedProviderRun = true
            lastMentionedBotIDForTesting = handoff.peerBotID
            if !supervisedRunBotIDsForTesting.contains(handoff.peerBotID) {
                supervisedRunBotIDsForTesting.append(handoff.peerBotID)
            }
            if let peerRunID = handoff.peerRunID {
                lastLinkedRunIDByBot[handoff.peerBotID] = peerRunID
            }
            if let originBotID = handoff.originBotID {
                clearDeskSendInFlight(for: originBotID)
            }
        case .hostRunning:
            lastSendStartedProviderRun = true
            if let originBotID = handoff.originBotID,
               let hostRunID = handoff.hostRunID {
                lastLinkedRunIDByBot[originBotID] = hostRunID
                if !supervisedRunBotIDsForTesting.contains(originBotID) {
                    supervisedRunBotIDsForTesting.append(originBotID)
                }
            }
        case .completed, .needsAttention:
            if let originBotID = handoff.originBotID {
                clearDeskSendInFlight(for: originBotID)
            }
            deskSendInFlightStartedAt = nil
        case .peerPrepared, .peerCompleted, .hostPrepared:
            break
        }

        let conversationIDs = [handoff.originConversationID, Optional(handoff.peerConversationID)]
            .compactMap { $0 }
        var appliedStates = false
        for conversationID in conversationIDs {
            guard let conversation = try? botStore.conversation(id: conversationID) else { continue }
            adoptFollowThroughConversation(conversation)
            applyAttentionState(
                for: conversation.botID,
                conversations: destConversations(botID: conversation.botID, patched: conversation),
                reload: false
            )
            refreshPublishedIdentity(for: conversation.botID)
            appliedStates = true
        }
        // One delta is one turn: the states above all landed before this pass,
        // so Active Bots hydrates once instead of once per conversation.
        if appliedStates {
            reloadActiveBotsScreen()
        }
    }
}

/// Lock-protected selected desk-thread mirror for stream filtering.
/// Safe from coordinator background threads and the main actor.
/// BT-20: stream events for the interested desk thread are collected on the
/// coordinator's thread and drained by ONE MainActor hop per batch. Before,
/// every token scheduled its own `Task { @MainActor }` and its own
/// `@Published` write on the monolithic `BotsViewModel`, so the whole Bots tree
/// (rail, header, timeline, inspector) re-evaluated per token.
final class DeskStreamEventBatchBox: @unchecked Sendable {
    struct Entry {
        let event: AssistantEvent
        let runId: AgentRunID?
        let threadId: AgentThreadID
    }

    private let lock = NSLock()
    private var pending: [Entry] = []

    /// Returns true when this entry opened a new batch (caller schedules the hop).
    func append(_ entry: Entry) -> Bool {
        lock.lock(); defer { lock.unlock() }
        pending.append(entry)
        return pending.count == 1
    }

    func drain() -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        let drained = pending
        pending.removeAll(keepingCapacity: true)
        return drained
    }
}

final class InterestedDeskThreadBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: AgentThreadID?
    private var hopCount = 0

    func set(_ id: AgentThreadID?) {
        lock.lock()
        value = id
        lock.unlock()
    }

    func get() -> AgentThreadID? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func incrementHopCount() {
        lock.lock()
        hopCount += 1
        lock.unlock()
    }

    func hopCountValue() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return hopCount
    }

    func resetHopCount() {
        lock.lock()
        hopCount = 0
        lock.unlock()
    }
}

extension BotsViewModel: AgentRunObserver {
    nonisolated public func runCoordinator(
        _ c: AgentRunCoordinator,
        didReceive event: AssistantEvent,
        run: AgentRunID,
        threadId: AgentThreadID
    ) {
        guard currentInterestedDeskThreadID() == threadId else { return }
        // BT-20: one hop per batch. Events that arrive while the main actor is
        // busy pile into the same batch and publish once.
        let opensBatch = deskStreamEventBatch.append(.init(event: event, runId: run, threadId: threadId))
        guard opensBatch else { return }
        interestedDeskThread.incrementHopCount()
        // Same ~30 Hz paint coalesce as Agent App: events arriving in the window share one publish.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: AgentAppViewModel.streamPaintCoalesceInterval)
            self?.flushDeskStreamEventBatch()
        }
    }

    nonisolated public func runCoordinator(
        _ c: AgentRunCoordinator,
        didFinish runId: AgentRunID,
        threadId: AgentThreadID,
        status: AgentRunStatus,
        finalMessage: String?,
        providerThreadId: String?
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Pending paint batch must land before terminal reconciliation reads the timeline.
            self.flushDeskStreamEventBatch()
            self.resolveExactRunWaiters(
                runID: runId,
                threadID: threadId,
                finalMessage: finalMessage,
                providerThreadID: providerThreadId
            )
            if self.adoptLinkedRunTerminal(runId: runId, threadId: threadId) {
                self.refreshActiveBotCount()
            }
        }
    }

    nonisolated public func runCoordinator(
        _ c: AgentRunCoordinator,
        didChangeStatus status: AgentRunStatus,
        runId: AgentRunID,
        threadId: AgentThreadID
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if BotsDeskFollowThrough.isTerminal(status) {
                self.flushDeskStreamEventBatch()
                if self.adoptLinkedRunTerminal(runId: runId, threadId: threadId) {
                    self.refreshActiveBotCount()
                }
                return
            }
            guard let botID = self.botStore.cachedBotID(linkedTo: threadId) else {
                if self.screen == .desk,
                   let selectedBotID = self.selectedBotID,
                   self.selectedConversation?.linkedAgentThreadID == threadId {
                    self.restoreDeskWorkLog(botID: selectedBotID)
                }
                return
            }
            if self.screen.resolvedDestination == .activeBots {
                self.reloadActiveBotsScreen()
            } else {
                self.refreshActiveBotCount()
            }
            self.refreshPublishedIdentity(for: botID)
            guard self.screen == .desk, let selectedBotID = self.selectedBotID else { return }
            guard self.selectedConversation?.linkedAgentThreadID == threadId else { return }
            self.restoreDeskWorkLog(botID: selectedBotID)
        }
    }
}

// MARK: - Shared sidebar chrome

/// One control for the single shell sidebar: Workspaces or Bots (roster).
public struct BotsModeSwitcher: View {
    public var isBotsSelected: Bool
    public var onSelectAgentic: () -> Void
    public var onSelectBots: () -> Void

    public init(
        isBotsSelected: Bool,
        onSelectAgentic: @escaping () -> Void,
        onSelectBots: @escaping () -> Void
    ) {
        self.isBotsSelected = isBotsSelected
        self.onSelectAgentic = onSelectAgentic
        self.onSelectBots = onSelectBots
    }

    public var body: some View {
        HStack(spacing: 2) {
            segment(
                title: BotsChrome.Label.agentic,
                symbol: "square.grid.2x2",
                selected: !isBotsSelected,
                identifier: "bots.chrome.agentic",
                action: onSelectAgentic
            )
            segment(
                title: BotsChrome.Label.bots,
                symbol: "person.2",
                selected: isBotsSelected,
                identifier: "bots.chrome.bots",
                action: onSelectBots
            )
        }
        .padding(2)
        // Glass track: the sidebar sits on NSVisualEffectView. An opaque
        // surfaceRaised slab punches a dark block through that material.
        .background(DS.Palette.hover)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .strokeBorder(DS.Palette.line.opacity(0.45), lineWidth: DS.Border.hairline)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bots.chrome.mode")
        .accessibilityLabel("Sidebar mode")
        .accessibilityValue(isBotsSelected ? BotsChrome.Label.bots : BotsChrome.Label.agentic)
    }

    /// Native-feeling segmented control: recessed glass track, frosted
    /// selected segment, compact height (desktop control, not a touch target).
    private func segment(
        title: String,
        symbol: String,
        selected: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .accessibilityHidden(true)
                Text(title)
                    .font(DS.Font.caption.weight(selected ? .semibold : .medium))
            }
            .foregroundColor(selected ? DS.Palette.text : DS.Palette.textSecondary)
            .frame(maxWidth: .infinity, minHeight: 26)
            .background(selected ? Color.white.opacity(0.12) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}

/// Roster body shared by the shell sidebar and the detached Bots window.
public struct BotsRosterList: View {
    @ObservedObject private var vm: BotsViewModel
    /// Sidebar hosts the roster in a sibling NSHostingView from BotsRootView.
    /// Attach the delete confirm here so right-click Delete is not a silent latch.
    private let attachDeleteConfirmation: Bool
    @State private var searchFocusRequest = false

    public init(
        vm: BotsViewModel,
        attachDeleteConfirmation: Bool = false,
        isScheduledTasksSelected: Bool = false,
        onOpenScheduledTasks: (() -> Void)? = nil
    ) {
        self.vm = vm
        self.attachDeleteConfirmation = attachDeleteConfirmation
        _ = isScheduledTasksSelected
        _ = onOpenScheduledTasks
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Button(action: vm.beginCreate) {
                    SidebarActionRow(symbol: "person.badge.plus", title: BotsChrome.Label.newBot)
                }
                .buttonStyle(.plain)
                .disabled(!vm.isControlPlaneActive)
                .help("Create a named teammate")
                .accessibilityIdentifier("bots.new")

                Button(action: vm.openActiveBots) {
                    SidebarActionRow(
                        symbol: "bolt.horizontal.circle",
                        title: BotsChrome.Label.activeBots,
                        isSelected: vm.screen.resolvedDestination == .activeBots,
                        badgeText: PetActiveThreadCountFormatter.badgeText(count: vm.activeBotCount),
                        badgeIsBlue: true
                    )
                }
                .buttonStyle(.plain)
                .help(
                    vm.activeBotCount == 0
                        ? BotsChrome.Label.activeBots
                        : "\(BotsChrome.Label.activeBots) \(vm.activeBotCount)"
                )
                .accessibilityLabel(
                    vm.activeBotCount == 0
                        ? BotsChrome.Label.activeBots
                        : "\(BotsChrome.Label.activeBots) \(vm.activeBotCount)"
                )
                .accessibilityIdentifier("bots.active")
                .accessibilityAddTraits(vm.screen.resolvedDestination == .activeBots ? .isSelected : [])

                Button(action: vm.openScheduleTasks) {
                    SidebarActionRow(
                        symbol: "calendar.badge.clock",
                        title: BotsChrome.Label.scheduleTasks,
                        isSelected: vm.screen.resolvedDestination == .scheduleTasks
                    )
                }
                .buttonStyle(.plain)
                .help("Create and manage scheduled bot tasks")
                .accessibilityIdentifier("bots.scheduleTasks")
                .accessibilityAddTraits(vm.screen.resolvedDestination == .scheduleTasks ? .isSelected : [])
            }
            .padding(.horizontal, DS.Space.md)
            .padding(.bottom, DS.Space.lg)

            HStack(spacing: DS.Space.sm) {
                Text(BotsChrome.Label.myBots)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textTertiary)
                Spacer(minLength: 0)
                Toggle("Show hidden", isOn: $vm.showHidden)
                    .toggleStyle(.checkbox)
                    .font(DS.Font.caption2)
                    .foregroundColor(DS.Palette.textTertiary)
                    .accessibilityIdentifier("bots.roster.showHidden")
            }
            .padding(.horizontal, DS.Space.lg)
            .padding(.bottom, DS.Space.sm)

            SidebarSearchField(
                placeholder: BotsChrome.Label.search,
                text: $vm.searchText,
                focusRequest: $searchFocusRequest,
                accessibilityIdentifier: "bots.roster.search"
            )
            .padding(.horizontal, DS.Space.md)
            .padding(.bottom, DS.Space.sm)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Space.lg) {
                    if vm.publishedRoster.isEmpty {
                        Text(vm.searchText.isEmpty ? "No bots yet" : "No matches")
                            .font(DS.Font.body)
                            .foregroundColor(DS.Palette.textTertiary)
                            .padding(.horizontal, DS.Space.md)
                            .padding(.vertical, DS.Space.sm)
                    } else {
                        ForEach(vm.publishedRoster, id: \.id) { bot in
                            rosterRow(bot)
                        }
                    }
                }
                .padding(.horizontal, DS.Space.sm)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("bots.roster")
        .modifier(BotsDeleteConfirmation(vm: vm, enabled: attachDeleteConfirmation))
    }

    private func rosterStatusColor(_ state: BotAttentionState) -> Color {
        switch state {
        case .needsAttention: return DS.Palette.warning
        case .unreadActivity: return DS.Palette.accent
        case .working, .none: return DS.Palette.success
        }
    }

    private func rosterRow(_ bot: BotDefinition) -> some View {
        let selected = vm.selectedBotID == bot.id
            && vm.screen.resolvedDestination != .activeBots
            && vm.screen.resolvedDestination != .scheduleTasks
        let state = vm.attentionState(for: bot)
        let preview = vm.rosterPreview(for: bot)
        let identity = BotsChrome.identityColor(
            name: bot.name,
            handle: bot.handle,
            symbol: bot.avatarSymbol
        )
        return Button {
            vm.openDeskFromRoster(bot)
        } label: {
            HStack(spacing: DS.Space.sm) {
                ZStack(alignment: .bottomTrailing) {
                    BotsAvatarView(
                        name: bot.name,
                        handle: bot.handle,
                        symbol: bot.avatarSymbol,
                        size: BotsChrome.rosterAvatarSize,
                        attention: state
                    )
                    Circle()
                        .fill(rosterStatusColor(state))
                        .frame(width: 7, height: 7)
                        .overlay(Circle().stroke(DS.Palette.surface, lineWidth: 1))
                }
                .frame(width: BotsChrome.rosterAvatarSize, height: BotsChrome.rosterAvatarSize)
                VStack(alignment: .leading, spacing: 1) {
                    Text(bot.name)
                        .font(selected ? DS.Font.bodyStrong : DS.Font.body)
                        .foregroundColor(DS.Palette.text)
                        .lineLimit(1)
                    Text(preview)
                        .font(DS.Font.caption2)
                        .foregroundColor(DS.Palette.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if BotsChrome.rosterShowsBusySpinner(for: state) {
                    DSBusySpinner(
                        label: BotsChrome.statusTitle(for: .working),
                        identifier: "bots.roster.busy.\(bot.handle)"
                    )
                }
                if bot.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(DS.Palette.textTertiary)
                        .accessibilityHidden(true)
                }
                if bot.hidden {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(DS.Palette.textTertiary)
                        .accessibilityHidden(true)
                }

            }
            .padding(.horizontal, DS.Space.sm)
            .frame(minHeight: BotsChrome.hitTarget)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .fill(selected ? identity.opacity(0.22) : Color.white.opacity(0.001))
            )
            .overlay(alignment: .leading) {
                if selected {
                    identity
                        .frame(width: 3)
                        .clipShape(RoundedRectangle(cornerRadius: 1.5, style: .continuous))
                        .padding(.vertical, 5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(bot.name) · \(BotsChrome.statusTitle(for: state))")
        .accessibilityLabel(bot.name)
        .accessibilityValue("\(bot.pinned ? "Pinned. " : "")\(bot.hidden ? "Hidden. " : "")\(BotsChrome.statusTitle(for: state)). \(preview)")
        .accessibilityIdentifier("bots.roster.row.\(bot.handle)")
        .contextMenu {
            botManagementButtons(bot: bot, vm: vm, fromRoster: true)
        }
    }
}

@MainActor
@ViewBuilder
private func botManagementButtons(
    bot: BotDefinition,
    vm: BotsViewModel,
    fromRoster: Bool
) -> some View {
    let locked = !vm.isControlPlaneActive
    Button(bot.pinned ? "Unpin" : "Pin") {
        vm.setPinned(id: bot.id, pinned: !bot.pinned)
    }
    .disabled(locked)
    .accessibilityIdentifier("bots.menu.pin")
    Button(bot.hidden ? "Unhide" : "Hide") {
        vm.setHidden(id: bot.id, hidden: !bot.hidden)
    }
    .disabled(locked)
    .accessibilityIdentifier("bots.menu.hide")
    Button("Duplicate") {
        if fromRoster {
            vm.duplicateFromRoster(bot)
        } else {
            _ = try? vm.duplicate(id: bot.id)
        }
    }
    .disabled(locked)
    .accessibilityIdentifier("bots.menu.duplicate")
    Button("Edit") {
        vm.beginEdit(bot)
    }
    .disabled(locked)
    .accessibilityIdentifier("bots.menu.edit")
    Divider()
    Button("Delete", role: .destructive) {
        vm.pendingDeleteID = bot.id
    }
    .disabled(locked)
    .accessibilityIdentifier("bots.menu.delete")
}

private struct BotsTitlebarBleed: ViewModifier {
    let edges: Edge.Set

    func body(content: Content) -> some View {
        content.ignoresSafeArea(.container, edges: edges)
    }
}

private struct BotsUnsavedNewBotConfirmation: ViewModifier {
    @ObservedObject var vm: BotsViewModel

    func body(content: Content) -> some View {
        content.confirmationDialog(
            BotsChrome.Label.unsavedNewBotConfirmTitle,
            isPresented: Binding(
                get: { vm.pendingUnsavedNewBotConfirm },
                set: { if !$0 { vm.cancelUnsavedNewBotLeave() } }
            ),
            titleVisibility: .visible
        ) {
            Button(BotsChrome.Label.unsavedNewBotDontSave, role: .destructive) {
                vm.discardUnsavedNewBotAndLeave()
            }
            .accessibilityIdentifier("bots.studio.unsaved.discard")
            Button("Cancel", role: .cancel) {
                vm.cancelUnsavedNewBotLeave()
            }
            .accessibilityIdentifier("bots.studio.unsaved.cancel")
        } message: {
            Text(BotsChrome.Label.unsavedNewBotConfirmMessage)
        }
    }
}

private struct BotsDeleteConfirmation: ViewModifier {
    @ObservedObject var vm: BotsViewModel
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.confirmationDialog(
                title,
                isPresented: Binding(
                    get: { vm.pendingDeleteID != nil },
                    set: { if !$0 { vm.pendingDeleteID = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let id = vm.pendingDeleteID {
                        vm.delete(id: id)
                    }
                    vm.pendingDeleteID = nil
                }
                .accessibilityIdentifier("bots.menu.delete.confirm")
                Button("Cancel", role: .cancel) { vm.pendingDeleteID = nil }
            } message: {
                Text("This teammate is removed from the fleet. Conversations and routines are deleted.")
            }
        } else {
            content
        }
    }

    private var title: String {
        if let id = vm.pendingDeleteID, let bot = vm.bots.first(where: { $0.id == id }) {
            return "Delete \(bot.name)?"
        }
        return "Delete this Bot?"
    }
}

// MARK: - Root view

/// Studio fields publish only inside Studio. A keystroke must not rebuild the
/// roster, conversations, schedules, and every other Bots destination.
private struct BotsStudioReactiveScope<Content: View>: View {
    @ObservedObject var studioState: BotsStudioDraftState
    @ViewBuilder var content: () -> Content

    var body: some View { content() }
}

public struct BotsRootView: View {
    @ObservedObject private var vm: BotsViewModel
    /// Standalone Bots window keeps its own rail. The main shell hosts the
    /// roster inside the single sidebar instead.
    private let embedsRosterRail: Bool
    @State private var pendingClearAllDeskThreads = false
    @State private var pendingDockerDataClear: BotID?

    public init(vm: BotsViewModel, embedsRosterRail: Bool = true) {
        self.vm = vm
        self.embedsRosterRail = embedsRosterRail
    }

    private var titlebarSafeAreaEdges: Edge.Set {
        BotsViewModel.ignoredSafeAreaEdges(
            embedsRosterRail: embedsRosterRail,
            presentsAsDetachedWindow: vm.presentsAsDetachedWindow
        )
    }

    public var body: some View {
        HStack(spacing: 0) {
            if showsRosterRail {
                rosterRail
                Rectangle()
                    .fill(DS.Palette.line)
                    .frame(width: 1)
                    .accessibilityHidden(true)
            }
            Group {
                switch vm.screen.resolvedDestination {
                case .studio:
                    BotsStudioReactiveScope(studioState: vm.studioState) {
                        studioScreen
                    }
                case .activeBots:
                    ActiveBotsRootView(vm: vm)
                case .scheduleTasks:
                    BotScheduleTasksRootView(vm: vm)
                case .desk, .fleet, .attention:
                    deskScreen
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: embedsRosterRail ? 980 : 700, minHeight: 680)
        .background(DS.Palette.bg)
        // Sidebar (open) or the 34pt restore bar (collapsed) owns the
        // traffic lights, so Desk drops every titlebar inset: .top or the
        // Ceo header floats a titlebar below the traffic lights, .leading
        // or it hangs in empty padding beside the open sidebar.
        .modifier(BotsTitlebarBleed(edges: titlebarSafeAreaEdges))
        .alert("Bots", isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button("OK") { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "")
        }
        .confirmationDialog(
            "Remove secret?",
            isPresented: Binding(
                get: { vm.pendingSecretDeleteName != nil },
                set: { if !$0 { vm.pendingSecretDeleteName = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove secret", role: .destructive) {
                if let name = vm.pendingSecretDeleteName {
                    vm.removeBotSecret(name)
                }
            }
            .accessibilityIdentifier("bots.studio.secrets.remove.confirm")
            Button("Cancel", role: .cancel) {
                vm.pendingSecretDeleteName = nil
            }
        } message: {
            Text("This deletes the protected value from this Bot's storage.")
        }
        .modifier(BotsDeleteConfirmation(vm: vm, enabled: embedsRosterRail))
        .modifier(BotsUnsavedNewBotConfirmation(vm: vm))
        .onAppear { vm.scheduleFreshnessPass() }
    }

    private var showsRosterRail: Bool {
        embedsRosterRail && vm.isControlPlaneActive
    }

    private var rosterRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            BotsModeSwitcher(
                isBotsSelected: true,
                onSelectAgentic: { vm.requestLeaveBotsMode() },
                onSelectBots: {}
            )
            .padding(.horizontal, DS.Space.lg)
            .padding(.top, DS.Space.xl)
            BotsRosterList(vm: vm)
        }
        .frame(width: BotsChrome.rosterWidth)
        .background(DS.Palette.surface)
    }

    // MARK: Empty desk

    private var emptyDesk: some View {
        DSEmptyState(
            icon: "bubble.left.and.bubble.right",
            title: vm.isControlPlaneActive ? "Select a teammate" : "Turn on Bot control plane in Settings",
            subtitle: vm.isControlPlaneActive
                ? "Chat opens here. Studio is the other destination."
                : "Bots stay off until the control plane is enabled."
        ) {
            if vm.isControlPlaneActive {
                Button(action: vm.beginCreate) {
                    HStack(spacing: DS.Space.sm) {
                        Image(systemName: "person.badge.plus")
                            .font(.system(size: 12, weight: .semibold))
                            .accessibilityHidden(true)
                        Text(BotsChrome.Label.newBot)
                    }
                }
                .buttonStyle(DSPrimaryButtonStyle())
                .frame(minHeight: BotsChrome.hitTarget)
                .contentShape(Rectangle())
                .help("Create a named teammate")
                .accessibilityIdentifier("bots.desk.empty.new")
                .padding(.top, DS.Space.xs)
            }
        }
        .accessibilityIdentifier("bots.desk.empty")
    }

    @ViewBuilder
    private func attentionBadge(_ state: BotAttentionState) -> some View {
        switch state {
        case .needsAttention:
            DSPill(BotsChrome.statusTitle(for: state), tone: .warning)
        case .unreadActivity:
            DSPill(BotsChrome.statusTitle(for: state), tone: .accent)
        case .working:
            DSPill(BotsChrome.statusTitle(for: state), tone: .success)
        case .none:
            EmptyView()
        }
    }

    private var studioScreen: some View {
        VStack(spacing: 0) {
            studioHeader
            studioTabs
            Group {
                switch resolvedStudioTab {
                case .profile:
                    studioPage { studioProfile }
                case .brain:
                    studioPage { studioProfile }
                case .files:
                    filesTab
                case .routines:
                    studioPage { routinesTab }
                case .security:
                    studioPage {
                        VStack(alignment: .leading, spacing: DS.Space.xl) {
                            studioSecurity
                            studioSecrets
                            studioDesktop
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityIdentifier("bots.studio")
    }

    /// Every Studio tab scrolls and fills the available width; side gutters
    /// only, no artificial column cap.
    private func studioPage<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            content()
                .padding(.horizontal, DS.Space.huge)
                .padding(.vertical, DS.Space.xxl)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Studio open-form grammar (no boxes; typography, rhythm, hairlines)

    /// Section title with an optional quiet caption underneath. Sections sit
    /// directly on the canvas — chrome comes from spacing and rules, not cards.
    private func studioSectionHeader(_ title: String, caption: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(title)
                .font(DS.Font.bodyStrong)
                .foregroundColor(DS.Palette.text)
            if let caption {
                Text(caption)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Full-width hairline rule separating sections and list rows.
    private var studioRule: some View {
        Rectangle()
            .fill(DS.Palette.line)
            .frame(height: DS.Border.hairline)
            .accessibilityHidden(true)
    }

    /// Empty list placeholder on the open canvas.
    private func studioEmptyState(icon: String, title: String, subtitle: String) -> some View {
        DSEmptyState(icon: icon, title: title, subtitle: subtitle)
            .frame(maxWidth: .infinity, minHeight: 240)
    }

    private var studioHeader: some View {
        HStack(alignment: .center, spacing: DS.Space.lg) {
            if !showsRosterRail {
                backButton {
                    vm.requestLeaveUnsavedNewBot { [weak vm] in
                        vm?.leaveStudioAfterUnsavedGate()
                    }
                }
            }
            BotsAvatarView(
                name: vm.studioDraft.name,
                handle: vm.studioDraft.handle,
                symbol: vm.studioDraft.avatarSymbol,
                size: 40,
                attention: studioAvatarAttention
            )
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: DS.Space.sm) {
                    Text("Bot Studio")
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.textTertiary)
                    if vm.studioHasUnpublishedChanges {
                        DSPill("Draft", tone: .warning)
                    }
                }
                Text(vm.studioDraft.name.isEmpty ? "New Bot" : vm.studioDraft.name)
                    .font(DS.Font.title2.weight(.semibold))
                    .foregroundColor(DS.Palette.text)
                    .accessibilityIdentifier("bots.studio.name")
                Text(vm.studioDraft.title.isEmpty ? "No job yet" : vm.studioDraft.title)
                    .font(DS.Font.body)
                    .foregroundColor(DS.Palette.textSecondary)
                    .accessibilityIdentifier("bots.studio.role")
            }
            Spacer(minLength: DS.Space.lg)
            studioHeaderNotify
            if showsRosterRail, vm.selectedBot != nil {
                Button(BotsChrome.Label.openChat) {
                    vm.requestLeaveUnsavedNewBot { [weak vm] in
                        vm?.leaveStudioAfterUnsavedGate()
                    }
                }
                    .buttonStyle(DSSecondaryButtonStyle())
                    .accessibilityIdentifier("bots.studio.openChat")
            }
            Button(BotsChrome.Label.saveBot) {
                do {
                    _ = try vm.saveStudio()
                } catch {
                    vm.presentAlertError(error)
                }
            }
            .buttonStyle(BotsPrimaryButtonStyle())
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!vm.isControlPlaneActive)
            .accessibilityIdentifier("bots.studio.save")
        }
        .padding(.horizontal, DS.Space.xxl)
        .padding(.vertical, DS.Space.xl)
        .dsBar(edge: .bottom)
    }

    /// Quiet header setting. Save stays the only solid CTA; a Profile
    /// section would bury a switch that applies on every Studio tab.
    private var studioHeaderNotify: some View {
        Toggle(isOn: $vm.studioDraft.notificationsEnabled) {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: vm.studioDraft.notificationsEnabled ? "bell.fill" : "bell")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(
                        vm.studioDraft.notificationsEnabled
                            ? DS.Palette.textSecondary
                            : DS.Palette.textTertiary
                    )
                    .frame(width: 14)
                    .accessibilityHidden(true)
                Text("Notify")
                    .font(DS.Font.caption.weight(.medium))
                    .foregroundColor(DS.Palette.textSecondary)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .disabled(!vm.isControlPlaneActive)
        .help("Notify when this Bot needs you. Alerts stay on this Mac; they are not an isolated Desktop.")
        .accessibilityLabel("Notify when this Bot needs you")
        .accessibilityHint("Alerts stay on this Mac. They are not an isolated Desktop.")
        .accessibilityIdentifier("bots.studio.notifications")
        .frame(minHeight: BotsChrome.hitTarget)
    }

    private var studioTabs: some View {
        HStack(spacing: DS.Space.sm) {
            ForEach(BotStudioTab.allCases.filter(\.isUserFacing)) { tab in
                let selected = resolvedStudioTab == tab
                Button {
                    vm.studioTab = tab
                } label: {
                    HStack(spacing: DS.Space.xs) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .accessibilityHidden(true)
                        Text(tab.title)
                            .font(DS.Font.caption.weight(selected ? .semibold : .medium))
                    }
                    .foregroundColor(selected ? DS.Palette.onAccent : DS.Palette.textSecondary)
                    .padding(.horizontal, DS.Space.lg)
                    .padding(.vertical, DS.Space.sm)
                    .background(selected ? DS.Palette.accent : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                    .frame(minHeight: BotsChrome.hitTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier(tab.accessibilityIdentifier)
            }
            Spacer()
        }
        .padding(.horizontal, DS.Space.xxl)
        .overlay(alignment: .bottom) {
            Rectangle().fill(DS.Palette.line).frame(height: 1)
        }
    }

    private var studioProfile: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: DS.Space.huge) {
                studioIdentity
                studioRule
                studioSoul
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, DS.Space.huge)
            studioAvatarPane
                .frame(width: 280, alignment: .top)
                .padding(.leading, DS.Space.huge)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(DS.Palette.line)
                        .frame(width: DS.Border.hairline)
                        .accessibilityHidden(true)
                }
        }
    }

    private var studioIdentity: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            studioSectionHeader(BotsChrome.Label.roleAndIdentity)
            HStack(alignment: .top, spacing: DS.Space.xl) {
                labeledField("Name") {
                    studioField(
                        placeholder: "e.g. Piper",
                        text: Binding(
                            get: { vm.studioDraft.name },
                            set: { vm.didEditStudioName($0) }
                        )
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                labeledField("Role") {
                    studioField(placeholder: "What this teammate does", text: $vm.studioDraft.title)
                        .onChange(of: vm.studioDraft.title) { _ in
                            vm.refreshGeneratedStandingInstructions()
                        }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            labeledField("Slug") {
                HStack(spacing: DS.Space.xs) {
                    Text("@")
                        .font(DS.Font.body)
                        .foregroundColor(DS.Palette.textTertiary)
                        .accessibilityHidden(true)
                    studioField(
                        placeholder: "ceo",
                        text: Binding(
                            get: { vm.studioDraft.handle },
                            set: { vm.didEditStudioSlug($0) }
                        )
                    )
                    .accessibilityLabel("Slug")
                    .accessibilityValue(vm.studioDraft.handle.isEmpty ? "" : "@\(vm.studioDraft.handle)")
                    .accessibilityIdentifier("bots.studio.slug")
                }
            }
            labeledField(BotsChrome.Label.description, caption: BotsChrome.Label.descriptionCaption) {
                studioMultiline(text: $vm.studioDraft.description, minHeight: 60)
                    .accessibilityIdentifier("bots.studio.description")
                    .accessibilityHint(BotsChrome.Label.descriptionCaption)
                    .onChange(of: vm.studioDraft.description) { _ in
                        vm.refreshGeneratedStandingInstructions()
                    }
            }
        }
        .accessibilityIdentifier("bots.studio.identity")
    }

    private var studioSoul: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            studioSectionHeader(
                BotsChrome.Label.instructions,
                caption: BotsChrome.Label.instructionsCaption
            )
            studioMultiline(text: $vm.studioDraft.soul, minHeight: 140)
                .accessibilityLabel(BotsChrome.Label.instructions)
                .accessibilityHint(BotsChrome.Label.instructionsCaption)
        }
        .accessibilityIdentifier("bots.studio.soul")
    }

    private var studioDesktop: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            studioSectionHeader(BotsChrome.Label.desktop)
            desktopOption(
                kind: .logicalExecutionSpace,
                title: BotDesktopKind.logicalExecutionSpace.displayTitle,
                enabled: true,
                identifier: "bots.studio.desktop.logical"
            )
            desktopOption(
                kind: .botOwnedBrowser,
                title: BotDesktopKind.botOwnedBrowser.displayTitle,
                enabled: true,
                identifier: "bots.studio.desktop.botBrowser"
            )
            desktopOption(
                kind: .dockerDesktop,
                title: BotDesktopKind.dockerDesktop.displayTitle,
                enabled: vm.dockerDesktopSelectable,
                status: vm.dockerDesktopStatus,
                identifier: "bots.studio.desktop.docker"
            )
            Text(vm.desktopHonestyLabel)
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.warning)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("bots.studio.desktop.honesty")
            if vm.displayedDesktopKind == .dockerDesktop {
                BotComputerGuestCanvas(
                    url: (vm.studioDraft.botID.flatMap { vm.guestScreenURL(for: $0) }) ?? vm.lastGuestScreenURL,
                    running: vm.studioDraft.botID.map { vm.isGuestRunning($0) } ?? false,
                    rebuilding: vm.studioDraft.botID.map { vm.isGuestRebuilding($0) } ?? false,
                    launchState: vm.studioDraft.botID.map { vm.guestLaunchState(for: $0) } ?? .idle,
                    startIdentifier: "bots.studio.desktop.start",
                    rebuildIdentifier: "bots.studio.desktop.rebuild",
                    stopIdentifier: "bots.studio.desktop.stop",
                    screenIdentifier: "bots.studio.desktop.guestScreen",
                    onStart: {
                        if let id = vm.studioDraft.botID { vm.presentGuestDesktop(botID: id) }
                    },
                    onRebuild: {
                        if let id = vm.studioDraft.botID { vm.rebuildDockerGuest(botID: id) }
                    },
                    onStop: {
                        if let id = vm.studioDraft.botID { vm.stopDockerGuest(botID: id) }
                    }
                )
            }
        }
        .accessibilityIdentifier("bots.studio.desktop")
    }

    private func desktopOption(
        kind: BotDesktopKind,
        title: String,
        enabled: Bool,
        status: String? = nil,
        identifier: String
    ) -> some View {
        Button {
            guard enabled else { return }
            vm.studioDraft.desktopKind = kind
        } label: {
            HStack(alignment: .top, spacing: DS.Space.md) {
                Image(systemName: vm.displayedDesktopKind == kind ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(enabled ? DS.Palette.accent : DS.Palette.textTertiary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: DS.Space.sm) {
                        Text(title)
                            .font(DS.Font.bodyStrong)
                            .foregroundColor(enabled ? DS.Palette.text : DS.Palette.textTertiary)
                        if let status, !status.isEmpty {
                            DSPill(status, tone: .neutral)
                        }
                    }
                    Text(kind.honestyLabel)
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minHeight: BotsChrome.hitTarget)
        .disabled(!enabled)
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(vm.displayedDesktopKind == kind ? .isSelected : [])
    }

    private var studioSecurity: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            studioSectionHeader(
                BotsChrome.Label.security,
                caption: "Manage secrets and review runtime access."
            )
            VStack(alignment: .leading, spacing: 0) {
                securityRow(symbol: "hand.raised", title: "Approvals", detail: "Allow once / Deny stay off until P1b.")
                studioRule
                securityRow(symbol: "pencil.and.outline", title: "Host-brokered writes", detail: "Effects stay off until that phase ships.")
                studioRule
                securityRow(symbol: "desktopcomputer", title: "Desktop", detail: "Logical space is not a security boundary.")
            }
            Text("No Allow once / Deny actions are live. Desktop isolation is not a security boundary.")
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("bots.studio.security")
    }

    private var studioSecrets: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            studioSectionHeader(
                "Secrets",
                caption: "Stored in protected macOS storage for this Bot. Values are write-only here and are only exposed to this Bot's runtime."
            )
            if vm.isBotSecretsLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("bots.studio.secrets.loading")
            } else if vm.botSecretsLoadFailed {
                Text("Protected secret storage is unavailable.")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("bots.studio.secrets.error")
            } else if vm.botSecrets.isEmpty {
                studioEmptyState(
                    icon: "key",
                    title: "No secrets saved",
                    subtitle: "Add an environment-variable name and value for this Bot."
                )
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(vm.botSecrets) { secret in
                        HStack(spacing: DS.Space.lg) {
                            Image(systemName: "key.fill")
                                .foregroundColor(DS.Palette.textSecondary)
                                .accessibilityHidden(true)
                            Text(secret.name)
                                .font(DS.Font.body)
                                .foregroundColor(DS.Palette.text)
                            Spacer(minLength: 0)
                            Button("Update") {
                                vm.editBotSecret(secret.name)
                            }
                            .buttonStyle(DSSecondaryButtonStyle())
                            .accessibilityIdentifier("bots.studio.secrets.update.\(secret.name)")
                            Button("Remove", role: .destructive) {
                                vm.requestDeleteBotSecret(secret.name)
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(DS.Palette.danger)
                            .accessibilityIdentifier("bots.studio.secrets.remove.\(secret.name)")
                        }
                        .frame(minHeight: BotsChrome.hitTarget)
                        if secret.id != vm.botSecrets.last?.id {
                            studioRule
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                labeledField("Name", caption: "Environment-variable name used only by this Bot's runtime.") {
                    studioField(
                        placeholder: "SERVICE_TOKEN",
                        text: Binding(
                            get: { vm.studioState.secretNameDraft },
                            set: { vm.studioState.secretNameDraft = $0 }
                        )
                    )
                    .disabled(vm.studioState.editingSecretName != nil)
                    .accessibilityIdentifier("bots.studio.secrets.name")
                }
                labeledField(
                    "Value",
                    caption: vm.studioState.editingSecretName == nil
                        ? "The value is cleared after save."
                        : "Enter the replacement value."
                ) {
                    SecureField(
                        "Enter secret value",
                        text: Binding(
                            get: { vm.studioState.secretValueDraft },
                            set: { vm.studioState.secretValueDraft = $0 }
                        )
                    )
                    .textFieldStyle(.plain)
                    .font(DS.Font.body)
                    .foregroundColor(DS.Palette.text)
                    .padding(.horizontal, DS.Space.lg)
                    .padding(.vertical, DS.Space.md)
                    .frame(minHeight: 34)
                    .background(DS.Palette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                            .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
                    )
                    .accessibilityIdentifier("bots.studio.secrets.value")
                }
                HStack(spacing: DS.Space.md) {
                    if vm.studioState.editingSecretName != nil {
                        Button("Cancel") {
                            vm.cancelBotSecretEdit()
                        }
                        .buttonStyle(DSSecondaryButtonStyle())
                        .accessibilityIdentifier("bots.studio.secrets.cancel")
                    }
                    Button(vm.studioState.editingSecretName == nil ? "Save secret" : "Update secret") {
                        vm.saveBotSecret()
                    }
                    .buttonStyle(BotsPrimaryButtonStyle())
                    .disabled(!vm.isControlPlaneActive)
                    .accessibilityIdentifier("bots.studio.secrets.save")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("bots.studio.secrets")
    }

    private func securityRow(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .center, spacing: DS.Space.lg) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(DS.Palette.textSecondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DS.Font.body)
                    .foregroundColor(DS.Palette.text)
                Text(detail)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, DS.Space.lg)
        .frame(minHeight: BotsChrome.hitTarget)
    }

    private var studioAvatarAttention: BotAttentionState {
        guard let bot = vm.selectedBot else { return .none }
        return vm.attentionState(for: bot)
    }

    private var studioAvatarPillTone: DSPill.Tone {
        switch studioAvatarAttention {
        case .needsAttention: return .warning
        case .working: return .success
        case .unreadActivity: return .accent
        case .none: return .neutral
        }
    }

    private var studioAvatarPane: some View {
        let seed = vm.studioDraft.name.isEmpty ? vm.studioDraft.handle : vm.studioDraft.name
        let base = BotBlobatarSpec.parse(vm.studioDraft.avatarSymbol) ?? .default
        let live = base.liveFaced(attention: studioAvatarAttention)
        let mood = BotsChrome.statusTitle(for: studioAvatarAttention)
        return VStack(spacing: DS.Space.xxl) {
            VStack(spacing: DS.Space.md) {
                BotBlobatarView(
                    name: seed,
                    spec: live,
                    size: 188,
                    motion: .always,
                    handle: vm.studioDraft.handle
                )
                .accessibilityHidden(false)
                .accessibilityLabel("Avatar, \(mood)")
                if studioAvatarAttention != .none {
                    DSPill(mood, tone: studioAvatarPillTone)
                }
            }
            .frame(maxWidth: .infinity)
            BotBlobatarEditor(
                token: $vm.studioDraft.avatarSymbol,
                seed: seed,
                handle: vm.studioDraft.handle,
                columns: 2
            )
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .accessibilityIdentifier("bots.studio.avatar.pane")
    }

    // MARK: Desk

    private var deskScreen: some View {
        Group {
            if let bot = vm.selectedBot {
                VStack(spacing: 0) {
                    deskHeader(bot)
                    deskChat(bot)
                }
                .accessibilityIdentifier("bots.desk")
            } else {
                emptyDesk
            }
        }
    }

    /// Visual gap between Desk header glyphs. DSIconButton lays out at
    /// 44pt so the 26pt icon can keep a 44pt hit box; subtract that extra
    /// so the glyphs sit `DS.Space.xs` apart like workspace header icons.
    private static var deskHeaderIconSpacing: CGFloat {
        DS.Space.xs - (DSIconButton.hitTargetSize - DSIconButton.visualSize.width)
    }

    /// Toolbar-sized identity row. Title2 + xl padding was a page hero;
    /// Desk is chat, so this stays a 44pt chrome strip.
    private func deskHeader(_ bot: BotDefinition) -> some View {
        HStack(spacing: DS.Space.md) {
            DSIconButton(
                "sidebar.left",
                help: vm.isDeskThreadRailVisible
                    ? AgentChatThreadRailCopy.hideHelp
                    : AgentChatThreadRailCopy.showHelp
            ) {
                withAnimation(DS.Motion.standard) {
                    vm.isDeskThreadRailVisible.toggle()
                }
            }
            .accessibilityIdentifier("bots.desk.thread.toggle")
            Button {
                vm.openStudio(bot)
            } label: {
                HStack(spacing: DS.Space.sm) {
                    BotsAvatarView(
                        name: bot.name,
                        handle: bot.handle,
                        symbol: bot.avatarSymbol,
                        size: 22,
                        attention: vm.attentionState(for: bot)
                    )
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: DS.Space.sm) {
                            Text(bot.name)
                                .font(DS.Font.bodyStrong)
                                .foregroundColor(DS.Palette.text)
                                .accessibilityIdentifier("bots.desk.name")
                            attentionBadge(vm.attentionState(for: bot))
                        }
                        HStack(spacing: DS.Space.sm) {
                            Text(bot.title.isEmpty ? "No job yet" : bot.title)
                                .font(DS.Font.caption2)
                                .foregroundColor(DS.Palette.textSecondary)
                                .accessibilityIdentifier("bots.desk.job")
                            Text("@\(bot.handle)")
                                .font(DS.Font.caption2)
                                .foregroundColor(DS.Palette.textTertiary)
                                .accessibilityIdentifier("bots.desk.handle")
                            Text(vm.permissionLabel(for: bot))
                                .font(DS.Font.caption2)
                                .foregroundColor(DS.Palette.textTertiary)
                                .accessibilityIdentifier("bots.desk.permission")
                        }
                        .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open Studio for \(bot.name)")
            .accessibilityIdentifier("bots.desk.identity")
            Spacer(minLength: DS.Space.lg)
            HStack(spacing: Self.deskHeaderIconSpacing) {
                DSIconButton("gearshape", help: "Studio") {
                    vm.openStudio(bot)
                }
                .accessibilityIdentifier("bots.desk.studio")
                if !vm.presentsAsDetachedWindow {
                    DSIconButton("rectangle.on.rectangle", help: "Open in New Window") {
                        vm.openInNewWindow(bot)
                    }
                    .accessibilityIdentifier("bots.desk.openInNewWindow")
                }
                DSIconButton("plus", help: AgentChatThreadRailCopy.newHelp) {
                    vm.createDeskThread()
                }
                .accessibilityIdentifier("bots.desk.thread.new.header")
                DSIconButton(
                    "sidebar.right",
                    help: vm.isDeskSidePaneVisible ? "Hide inspector" : "Show inspector"
                ) {
                    withAnimation(DS.Motion.standard) {
                        vm.isDeskSidePaneVisible.toggle()
                    }
                }
                .accessibilityIdentifier("bots.desk.inspectorToggle")
            }
        }
        .padding(.leading, BotsViewModel.deskIdentityLeadingPadding(
            shellSidebarCollapsed: vm.isShellSidebarCollapsed
        ))
        .padding(.trailing, DS.Space.xl)
        .frame(height: 44)
        .dsBar(edge: .bottom)
    }

    private func deskChat(_ bot: BotDefinition) -> some View {
        HStack(spacing: 0) {
            if vm.isDeskThreadRailVisible {
                deskThreadRail
                    .frame(width: vm.deskThreadRailWidth)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                DSResizeDivider(axis: .vertical, help: "Resize threads") { delta in
                    vm.resizeDeskThreadRail(by: delta)
                }
            }
            Group {
                if let agentVM = vm.deskAgentVM {
                    AgentAppView(
                        vm: agentVM,
                        layout: AgentAppViewLayout(
                            showsThreadRail: false,
                            showsHeader: false,
                            showsPlanSidebar: false
                        )
                    )
                    .id(agentVM.selectedThreadId)
                } else if let conversation = vm.selectedConversation,
                          conversation.botID == bot.id,
                          conversation.linkedAgentThreadID == nil {
                    deskUnlinkedComposer(bot)
                } else {
                    AgentChatLoadingStatusStrip()
                        .padding(DS.Space.lg)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("bots.desk.timeline")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if vm.isDeskSidePaneVisible {
                DSResizeDivider(axis: .vertical, help: "Resize inspector") { delta in
                    // Divider reports + when the pointer moves right. This
                    // pane is trailing, so pull the handle left to widen.
                    vm.resizeDeskSidePane(by: -delta)
                }
                VStack(spacing: 0) {
                    deskDesktopPane(bot)
                    deskInspector(bot)
                }
                .frame(width: vm.deskSidePaneWidth)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(DS.Motion.standard, value: vm.isDeskSidePaneVisible)
        .animation(DS.Motion.standard, value: vm.isDeskThreadRailVisible)
        .animation(nil, value: vm.selectedBotID)
        .animation(nil, value: vm.selectedConversation?.id)
        .confirmationDialog(
            "Clear all threads?",
            isPresented: $pendingClearAllDeskThreads,
            titleVisibility: .visible
        ) {
            Button(AgentChatThreadRailCopy.clearAllTitle, role: .destructive) {
                vm.clearAllDeskThreads()
            }
            Button("Cancel", role: .cancel) { pendingClearAllDeskThreads = false }
        } message: {
            Text("Deletes every thread for this teammate. A live run will be stopped first. This cannot be undone.")
        }
    }

    /// Unlinked conversation: no thread exists yet. The first send creates it
    /// through the legacy send path, then the embedded Agent App takes over.
    private func deskUnlinkedComposer(_ bot: BotDefinition) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            AgentChatComposerBar(
                text: $vm.composerText,
                attachments: vm.attachments,
                placeholder: "Message \(bot.name)…",
                sendEnabled: vm.deskSendEnabled,
                runActive: vm.deskRunIsLive,
                isStopping: vm.isStopping,
                onSend: { vm.send() },
                onStop: { vm.stopDeskRun() },
                onAttach: { vm.addAttachments($0) },
                onRemoveAttachment: { vm.removeAttachment($0) },
                composerIdentifier: "bots.desk.composer",
                sendIdentifier: "bots.desk.send",
                suggestions: vm.composerSuggestions,
                onApplySuggestion: { vm.applyComposerSuggestion($0) },
                onCursorMoved: { vm.composerCursorOffset = $0 },
                suggestionIdentifier: "bots.desk.suggestion.popup",
                onFileDrop: { vm.insertDroppedFilePaths($0) }
            )
        }
    }

    private func deskDesktopPane(_ bot: BotDefinition) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Palette.textSecondary)
                    .accessibilityHidden(true)
                Text("\(bot.name) Desktop")
                    .font(DS.Font.bodyStrong)
                    .foregroundColor(DS.Palette.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
                DSPill(vm.desktopStatusPill, tone: .neutral)
            }
            if vm.displayedDesktopKind == .dockerDesktop {
                BotComputerGuestCanvas(
                    url: vm.guestScreenURL(for: bot.id),
                    running: vm.isGuestRunning(bot.id),
                    rebuilding: vm.isGuestRebuilding(bot.id),
                    launchState: vm.guestLaunchState(for: bot.id),
                    startIdentifier: "bots.desk.desktop.start",
                    rebuildIdentifier: "bots.desk.desktop.rebuild",
                    stopIdentifier: "bots.desk.desktop.stop",
                    screenIdentifier: "bots.desk.desktop.guestScreen",
                    onStart: { vm.presentGuestDesktop(botID: bot.id) },
                    onRebuild: { vm.rebuildDockerGuest(botID: bot.id) },
                    onStop: { vm.stopDockerGuest(botID: bot.id) },
                    onOpenInNewWindow: { vm.openGuestDesktopInNewWindow(bot) }
                )
            }
            Text(vm.desktopHonestyLabel)
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.warning)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("bots.desk.desktop.honesty")
        }
        .padding(DS.Space.lg)
        .dsBar(edge: .bottom)
        .accessibilityIdentifier("bots.desk.desktop")
        .accessibilityLabel("Desktop for \(bot.name). \(vm.desktopHonestyLabel)")
    }

    private func deskInspector(_ bot: BotDefinition) -> some View {
        VStack(spacing: 0) {
            // Routines is the only user-facing tab, so a tab strip renders a
            // single always-selected chip that reads as a dead button. Show a
            // plain section header instead (same language as the desktop pane).
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "clock.arrow.2.circlepath")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Palette.textSecondary)
                    .accessibilityHidden(true)
                Text(resolvedInspectorTab.title)
                    .font(DS.Font.bodyStrong)
                    .foregroundColor(DS.Palette.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Space.lg)
            .padding(.top, DS.Space.lg)
            .padding(.bottom, DS.Space.md)

            Group {
                switch resolvedInspectorTab {
                case .brain:
                    inspectorBrain
                case .routines:
                    inspectorRoutines
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DS.Palette.surface)
        .accessibilityIdentifier("bots.desk.inspector")
    }

    private var resolvedStudioTab: BotStudioTab {
        vm.studioTab.isUserFacing ? vm.studioTab : .profile
    }

    private var resolvedInspectorTab: BotDeskInspectorTab {
        vm.inspectorTab.isUserFacing ? vm.inspectorTab : .routines
    }

    private var studioBrain: some View {
        brainInspector(compact: false)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("bots.studio.brain")
    }

    private var inspectorBrain: some View {
        ScrollView {
            brainInspector(compact: true)
                .padding(.horizontal, DS.Space.lg)
                .padding(.bottom, DS.Space.md)
        }
        .accessibilityIdentifier("bots.desk.inspector.brain")
    }

    private func brainInspector(compact: Bool) -> some View {
        let receipt = vm.inspectedBrain
        return VStack(alignment: .leading, spacing: DS.Space.md) {
            HStack(spacing: DS.Space.sm) {
                Text("What this Bot sees")
                    .font(DS.Font.bodyStrong)
                    .foregroundColor(DS.Palette.text)
                Spacer(minLength: 0)
                if vm.inspectedBrainIsLastCall {
                    DSPill("Last call", tone: .accent)
                } else if vm.inspectedBrainIsPreview {
                    DSPill("Preview", tone: .neutral)
                } else {
                    DSPill("Compiled", tone: .neutral)
                }
            }
            Text(vm.inspectedBrainIsLastCall ? BotsChrome.Label.brainReceiptHonesty : BotsChrome.Label.brainPreviewHonesty)
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.warning)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("bots.brain.honesty")
            HStack(spacing: DS.Space.sm) {
                ForEach(BotBrainInspectorPane.allCases) { pane in
                    let selected = vm.brainPane == pane
                    Button {
                        vm.brainPane = pane
                    } label: {
                        Text(pane.title)
                            .font(DS.Font.caption.weight(selected ? .semibold : .regular))
                            .foregroundColor(selected ? DS.Palette.onAccent : DS.Palette.textSecondary)
                            .padding(.horizontal, DS.Space.md)
                            .padding(.vertical, DS.Space.sm)
                            .background(selected ? DS.Palette.accent : DS.Palette.surfaceRaised)
                            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: BotsChrome.hitTarget)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier(pane.accessibilityIdentifier)
                }
                Spacer(minLength: 0)
            }
            if let receipt {
                brainReceiptMeta(receipt, compact: compact)
                if vm.brainPane == .source {
                    brainSource(receipt)
                } else {
                    brainEffective(receipt)
                }
                brainWhyMemory(receipt)
                brainCapabilities(receipt)
            } else {
                Text("Save or select a Bot to compile Source and Effective Brain.")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textTertiary)
            }
        }
    }

    private func brainReceiptMeta(_ receipt: ContextAssemblyReceipt, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Revision \(receipt.revisionNumber) · \(vm.providerChipTitle(receipt.provider)) · \(receipt.model.isEmpty ? "model unset" : receipt.model) · \(receipt.permissionMode.rawValue)")
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textSecondary)
            AgentSelectablePlainText(
                text: "payload \(receipt.payloadDigest)",
                fontSize: 11,
                monospaced: true,
                textColor: DS.NS.textTertiary
            )
            .accessibilityIdentifier("bots.brain.digest")
            if !compact {
                Text("compiler \(receipt.compilerVersion) · no opaque RemoteCode layer")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textTertiary)
            }
        }
        .accessibilityIdentifier("bots.brain.receipt")
    }

    private func brainSource(_ receipt: ContextAssemblyReceipt) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            ForEach(receipt.layers) { layer in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: DS.Space.sm) {
                        DSPill(layer.included ? "Included" : "Excluded", tone: layer.included ? .success : .neutral)
                        Text(layer.title)
                            .font(DS.Font.caption.weight(.semibold))
                            .foregroundColor(DS.Palette.text)
                    }
                    if !layer.text.isEmpty {
                        AgentSelectablePlainText(
                            text: layer.text,
                            fontSize: 11,
                            textColor: DS.NS.textSecondary
                        )
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(layer.reason)
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
            }
        }
        .accessibilityIdentifier("bots.brain.source")
    }

    private func brainEffective(_ receipt: ContextAssemblyReceipt) -> some View {
        AgentSelectablePlainText(
            text: receipt.compiledPayload.isEmpty ? "(empty payload)" : receipt.compiledPayload,
            fontSize: 11,
            monospaced: true,
            textColor: DS.NS.text
        )
        .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.Space.md)
            .background(DS.Palette.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .accessibilityIdentifier("bots.brain.effective")
    }

    private func brainWhyMemory(_ receipt: ContextAssemblyReceipt) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text("Why this memory?")
                .font(DS.Font.bodyStrong)
                .foregroundColor(DS.Palette.text)
            if receipt.memoryLayers.isEmpty {
                Text("No memory items were considered.")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textTertiary)
            } else {
                ForEach(receipt.memoryLayers) { layer in
                    VStack(alignment: .leading, spacing: 2) {
                        AgentSelectablePlainText(
                            text: layer.text.isEmpty ? "(empty fact)" : layer.text,
                            fontSize: 11,
                            textColor: DS.NS.textSecondary
                        )
                        Text(layer.reason)
                            .font(DS.Font.caption)
                            .foregroundColor(DS.Palette.textTertiary)
                    }
                }
            }
        }
        .accessibilityIdentifier("bots.brain.whyMemory")
    }

    private func brainCapabilities(_ receipt: ContextAssemblyReceipt) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text("What this Bot can do")
                .font(DS.Font.bodyStrong)
                .foregroundColor(DS.Palette.text)
            Text(BotPermission.honestyLabel)
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textSecondary)
            Text(receipt.desktopKind.honestyLabel)
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.warning)
                .fixedSize(horizontal: false, vertical: true)
            let skills = receipt.layers.reduce(into: [String]()) { partial, layer in
                if layer.kind == .skill && layer.included {
                    partial.append(layer.text)
                }
            }
            Text(skills.isEmpty ? "No enabled skills." : "Skills: \(skills.joined(separator: ", "))")
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textTertiary)
        }
        .accessibilityIdentifier("bots.brain.capabilities")
    }

    private var inspectorRoutines: some View {
        VStack(spacing: 0) {
            if vm.routines.isEmpty {
                // The button below is the way in — the subtitle sells the
                // feature instead of pointing somewhere else.
                DSEmptyState(
                    icon: "clock.arrow.2.circlepath",
                    title: "No scheduled tasks",
                    subtitle: "Run this teammate automatically at times you choose.",
                    background: .clear
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DS.Space.sm) {
                        ForEach(vm.routines, id: \.definition.id) { routine in
                            deskRoutineRow(routine)
                        }
                    }
                    .padding(.horizontal, DS.Space.lg)
                    .padding(.bottom, DS.Space.md)
                }
            }
            Button {
                vm.openStudioToAddRoutine()
            } label: {
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .accessibilityHidden(true)
                    Text("Add scheduled task")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(DSSecondaryButtonStyle())
            .frame(minHeight: BotsChrome.hitTarget)
            .padding(.horizontal, DS.Space.lg)
            .padding(.vertical, DS.Space.md)
            .accessibilityIdentifier("bots.desk.inspector.routines.add")
        }
        .accessibilityIdentifier("bots.desk.inspector.routines")
    }

    private func deskRoutineRow(_ routine: BotRoutine) -> some View {
        HStack(alignment: .center, spacing: DS.Space.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(routine.definition.name)
                    .font(DS.Font.bodyStrong)
                    .foregroundColor(DS.Palette.text)
                    .lineLimit(1)
                if !routine.definition.scheduleNote.isEmpty {
                    Text(routine.definition.scheduleNote)
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.textTertiary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("Active", isOn: Binding(
                get: { routine.activation.isEnabled },
                set: { vm.setRoutineEnabled(id: routine.definition.id, enabled: $0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
            .accessibilityLabel("Active, \(routine.definition.name)")
            .accessibilityIdentifier("bots.routines.active")
        }
        .dsPanel(padding: DS.Space.md)
        .frame(maxWidth: .infinity, minHeight: BotsChrome.hitTarget, alignment: .leading)
    }

    private var deskThreadRail: some View {
        AgentChatThreadRail(
            title: AgentChatThreadRailCopy.headerTitle(activeCount: vm.deskThreadActiveCount),
            isEmpty: vm.conversations.isEmpty,
            emptySubtitle: "Start a conversation or mention this teammate.",
            searchQuery: $vm.deskThreadSearchQuery,
            hasSearchMatches: !vm.filteredDeskConversations.isEmpty,
            identifier: "bots.desk.threads",
            hideIdentifier: "bots.desk.thread.hide",
            clearAllIdentifier: "bots.desk.thread.clearAll",
            newIdentifier: "bots.desk.thread.new",
            searchIdentifier: "bots.desk.thread.search",
            onHide: {
                withAnimation(DS.Motion.standard) {
                    vm.isDeskThreadRailVisible = false
                }
            },
            onClearAll: { pendingClearAllDeskThreads = true },
            onNew: { vm.createDeskThread() }
        ) {
            ScrollView {
                // BT-25: one coordinator snapshot per pass, not one per row.
                let liveThreadIDs = vm.liveDeskThreadIDsSnapshot()
                LazyVStack(alignment: .leading, spacing: DS.Space.xxs) {
                    ForEach(vm.filteredDeskConversations, id: \.id) { conversation in
                        deskThreadRow(conversation, liveThreadIDs: liveThreadIDs)
                    }
                }
                .padding(DS.Space.sm)
            }
        }
    }

    /// Desk rows are the Agent App rail rows: same provider monogram,
    /// same provider · model · time subtitle, same status marks. The
    /// rails must not fork the chrome.
    private func deskThreadRow(
        _ conversation: BotConversation,
        liveThreadIDs: Set<AgentThreadID>
    ) -> some View {
        let unread = conversation.unread || conversation.attentionState == .unreadActivity
        let running = vm.isDeskConversationRunning(conversation, liveThreadIDs: liveThreadIDs)
        let rowID = conversation.id.value.uuidString
        let status: AgentChatThreadStatusMark = {
            if running { return .running }
            if conversation.pinned {
                return .symbol(name: "pin.fill", color: DS.Palette.textTertiary, size: 9)
            }
            if !unread {
                return .symbol(name: "circle.fill", color: DS.Palette.textTertiary, size: 7)
            }
            return .hidden
        }()
        let routing = vm.deskThreadRailRouting(for: conversation)
        let title = AgentThreadTitle.display(
            conversation.title.isEmpty ? AgentThreadTitle.defaultTitle : conversation.title
        )
        return AgentChatThreadRow(
            title: title,
            subtitle: AgentThreadRailRowCopy.subtitle(
                provider: routing.provider,
                model: routing.model,
                updatedAt: conversation.updatedAt
            ),
            unread: unread,
            selected: vm.selectedConversation?.id == conversation.id,
            status: status,
            identifier: "bots.desk.thread.row.\(rowID)",
            runningIdentifier: "bots.desk.thread.row.running.\(rowID)",
            stopIdentifier: "bots.desk.thread.row.stop.\(rowID)",
            onSelect: { vm.selectDeskThread(conversation.id) },
            onStop: running ? { vm.stopDeskThread(conversation.id) } : nil,
            leading: { AgentThreadProviderMonogram(provider: routing.provider) },
            trailing: { EmptyView() }
        )
        .help(conversation.title.isEmpty ? AgentThreadTitle.defaultTitle : conversation.title)
    }

    private var filesTab: some View {
        VStack(spacing: 0) {
            if let bot = vm.selectedBot, vm.supportsDockerHomeFiles(for: bot) {
                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    Picker("Files location", selection: Binding(
                        get: { vm.studioFilesLocation },
                        set: { vm.setStudioFilesLocation($0, for: bot) }
                    )) {
                        Text(BotStudioFilesLocation.botFiles.title)
                            .tag(BotStudioFilesLocation.botFiles)
                        Text(BotStudioFilesLocation.dockerHome.title)
                            .tag(BotStudioFilesLocation.dockerHome)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 280)
                    .accessibilityIdentifier("bots.studio.files.location")
                    if vm.studioFilesLocation == .dockerHome {
                        HStack(alignment: .firstTextBaseline, spacing: DS.Space.lg) {
                            Text("Persisted on this Mac and mounted in Docker at /home/remotecode.")
                                .font(DS.Font.caption)
                                .foregroundColor(DS.Palette.textSecondary)
                            Spacer(minLength: 0)
                            Button("Clear Docker data…", role: .destructive) {
                                pendingDockerDataClear = bot.id
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(DS.Palette.danger)
                            .accessibilityIdentifier("bots.studio.files.docker.clear")
                        }
                    }
                }
                .padding(.horizontal, DS.Space.xl)
                .padding(.vertical, DS.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .dsBar(edge: .bottom)
            }
            Group {
                if let model = vm.homeFilesModel {
                    FilesSurfaceRoot(model: model)
                } else {
                    studioEmptyState(
                        icon: "folder",
                        title: "Bot files",
                        subtitle: "This teammate’s exclusive folder."
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("bots.studio.files")
        .onAppear {
            if let bot = vm.selectedBot {
                vm.attachHomeFilesSurface(for: bot)
            }
        }
        .onChange(of: vm.selectedBotID) { _ in
            if let bot = vm.selectedBot {
                vm.attachHomeFilesSurface(for: bot)
            }
        }
        .confirmationDialog(
            "Clear Docker data?",
            isPresented: Binding(
                get: { pendingDockerDataClear != nil },
                set: { presented in
                    if !presented { pendingDockerDataClear = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Clear Docker data", role: .destructive) {
                let botID = pendingDockerDataClear
                pendingDockerDataClear = nil
                if let botID,
                   let bot = vm.fleet.first(where: { $0.id == botID }) {
                    vm.confirmClearDockerData(for: bot)
                }
            }
            Button("Cancel", role: .cancel) { pendingDockerDataClear = nil }
        } message: {
            Text("Deletes this teammate’s Docker container and every file in /home/remotecode. This cannot be undone.")
        }
    }

    // MARK: Routines

    private var routinesTab: some View {
        VStack(alignment: .leading, spacing: DS.Space.xxl) {
            studioSectionHeader(BotsChrome.Label.routines)
            Text(BotRoutineCopy.testRunHonestyCaption)
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.warning)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("bots.routines.honesty")
            if !vm.isAutonomyActive {
                Text("Enabling a schedule does not run while RemoteCode is closed.")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textTertiary)
            }
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                labeledField("Name") {
                    studioField(placeholder: "Morning scan", text: $vm.routineName)
                        .accessibilityIdentifier("bots.routines.name")
                }
                labeledField("Instruction") {
                    studioMultiline(text: $vm.routinePrompt, minHeight: 72, maxHeight: 140)
                        .accessibilityIdentifier("bots.routines.instruction")
                }
                BotScheduleSpecEditor(
                    spec: $vm.routineSpec,
                    providers: vm.providers,
                    providersLoading: false
                )
                .accessibilityIdentifier("bots.routines.when")
                Button("Save task") { vm.saveRoutine() }
                    .buttonStyle(BotsPrimaryButtonStyle())
                    .accessibilityIdentifier("bots.routines.save")
            }

            if vm.routines.isEmpty {
                studioEmptyState(
                    icon: "clock.arrow.2.circlepath",
                    title: "No scheduled tasks",
                    subtitle: "Name an instruction and when it should run."
                )
            } else {
                VStack(alignment: .leading, spacing: DS.Space.xl) {
                    studioRule
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(vm.routines.enumerated()), id: \.element.definition.id) { index, routine in
                            if index > 0 { studioRule }
                            routineRow(routine)
                        }
                    }
                }
            }
        }
    }

    /// Studio lists routines as open rows between hairline rules; the Desk
    /// inspector keeps its own compact card per routine.
    @ViewBuilder
    private func routineRow(_ routine: BotRoutine, compact: Bool = false) -> some View {
        if compact {
            routineRowBody(routine)
                .dsPanel(padding: DS.Space.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            routineRowBody(routine)
                .padding(.vertical, DS.Space.lg)
        }
    }

    private func routineRowBody(_ routine: BotRoutine) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.lg) {
                Button {
                    vm.editRoutine(routine)
                } label: {
                    Text(routine.definition.name)
                        .font(DS.Font.bodyStrong)
                        .foregroundColor(DS.Palette.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit \(routine.definition.name)")
                Button("Edit") { vm.editRoutine(routine) }
                    .buttonStyle(DSSecondaryButtonStyle())
                    .accessibilityIdentifier("bots.routines.edit")
                Button("Test run") { vm.requestRoutineTestRun(id: routine.definition.id) }
                    .buttonStyle(DSSecondaryButtonStyle())
                    .accessibilityIdentifier("bots.routines.test")
                Toggle("Active", isOn: Binding(
                    get: { routine.activation.isEnabled },
                    set: { vm.setRoutineEnabled(id: routine.definition.id, enabled: $0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel("Active, \(routine.definition.name)")
                .accessibilityIdentifier("bots.routines.active")
            }
            Text(routine.definition.prompt)
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textSecondary)
            if !routine.definition.scheduleNote.isEmpty {
                Text(routine.definition.scheduleNote)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textTertiary)
            }
            if let at = routine.activation.lastTestRunRequestedAt {
                Text("Test run requested \(at.formatted(date: .abbreviated, time: .shortened))")
                    .font(DS.Font.caption2)
                    .foregroundColor(DS.Palette.textTertiary)
            }
        }
    }

    // MARK: Shared chrome

    private func backButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(DS.Palette.textSecondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back")
    }

    private func labeledField<Content: View>(
        _ label: String,
        caption: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(label)
                .font(DS.Font.caption.weight(.medium))
                .foregroundColor(DS.Palette.textSecondary)
                .accessibilityHidden(true)
            if let caption {
                Text(caption)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content()
                .accessibilityLabel(label)
        }
    }

    private func studioField(placeholder: String, text: Binding<String>) -> some View {
        StudioFocusField(placeholder: placeholder, text: text)
    }

    private func studioMultiline(text: Binding<String>, minHeight: CGFloat, maxHeight: CGFloat? = nil) -> some View {
        StudioFocusMultiline(text: text, minHeight: minHeight, maxHeight: maxHeight)
    }
}

/// Field in the chat-composer skin: surface on the canvas, hairline border,
/// DS focus ring when focused. Fields are the only boxes on the page.
private struct StudioFocusField: View {
    let placeholder: String
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(DS.Font.body)
            .foregroundColor(DS.Palette.text)
            .focused($focused)
            .padding(.horizontal, DS.Space.lg)
            .padding(.vertical, DS.Space.md)
            .frame(minHeight: 34)
            .background(DS.Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
                    .opacity(focused ? 0 : 1)
            )
            .dsFocusRing(isFocused: focused, cornerRadius: DS.Radius.card)
    }
}

/// Multiline editor in the chat-composer skin.
private struct StudioFocusMultiline: View {
    @Binding var text: String
    let minHeight: CGFloat
    let maxHeight: CGFloat?
    @FocusState private var focused: Bool

    var body: some View {
        TextEditor(text: $text)
            .font(DS.Font.body)
            .foregroundColor(DS.Palette.text)
            .scrollContentBackground(.hidden)
            .focused($focused)
            .frame(minHeight: minHeight, maxHeight: maxHeight)
            .padding(.horizontal, DS.Space.md)
            .padding(.vertical, DS.Space.md)
            .background(DS.Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
                    .opacity(focused ? 0 : 1)
            )
            .dsFocusRing(isFocused: focused, cornerRadius: DS.Radius.card)
    }
}

// MARK: - Optional detached window (fallback if the shell presenter is missing)

public final class BotsWindowController: NSWindowController, NSWindowDelegate {
    private let viewModel: BotsViewModel

    public init(context: AppContext, router: AppCommandRouter) {
        let vm = BotsViewModel(context: context, router: router, loadImmediately: false)
        vm.enableNavigationFirstFrameDeferral()
        self.viewModel = vm
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Bots"
        window.minSize = NSSize(width: 980, height: 680)
        window.center()
        window.backgroundColor = DS.NS.bg
        // Unified look: the titlebar paints as part of the window surface.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentView = NSHostingView(rootView: BotsRootView(vm: viewModel))
        window.setAccessibilityIdentifier("bots.window")
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// One bot Desk in its own window. The fleet fallback above keeps the roster.
public final class BotDeskWindowController: NSWindowController, NSWindowDelegate {
    private let viewModel: BotsViewModel
    private let onClose: () -> Void

    public init(
        botID: BotID,
        context: AppContext,
        router: AppCommandRouter,
        onClose: @escaping () -> Void
    ) {
        let vm = BotsViewModel(context: context, router: router, loadImmediately: false)
        vm.presentsAsDetachedWindow = true
        vm.enableNavigationFirstFrameDeferral()
        vm.prepareDetachedDesk(botID: botID)
        self.viewModel = vm
        self.onClose = onClose
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = vm.selectedBot?.name ?? "Bot"
        window.minSize = NSSize(width: 700, height: 520)
        window.backgroundColor = DS.NS.bg
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentView = NSHostingView(rootView: BotsRootView(vm: vm, embedsRosterRail: false))
        window.setAccessibilityIdentifier("bots.desk.window")
        super.init(window: window)
        window.delegate = self
        let autosave = "io.remotecode.detachedBot.\(botID.value.uuidString)"
        if !window.setFrameUsingName(autosave) {
            window.center()
        }
        window.setFrameAutosaveName(autosave)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public func show() {
        viewModel.scheduleFreshnessPass()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

/// Linux desktop only. Reuses the same guest container as Desk.
public final class BotGuestDesktopWindowController: NSWindowController, NSWindowDelegate {
    private let viewModel: BotsViewModel
    private let botID: BotID
    private let onClose: () -> Void

    public init(
        botID: BotID,
        context: AppContext,
        router: AppCommandRouter,
        onClose: @escaping () -> Void
    ) {
        self.botID = botID
        let vm = BotsViewModel(context: context, router: router, loadImmediately: false)
        vm.enableNavigationFirstFrameDeferral()
        vm.prepareDetachedDesk(botID: botID)
        self.viewModel = vm
        self.onClose = onClose
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let title = "\((vm.selectedBot?.name ?? "Bot")) Desktop"
        window.title = title
        window.minSize = NSSize(width: 640, height: 420)
        window.backgroundColor = DS.NS.bg
        window.titlebarAppearsTransparent = true
        window.contentView = NSHostingView(rootView: BotGuestDesktopRoot(vm: vm))
        window.setAccessibilityIdentifier("bots.desk.desktop.window")
        super.init(window: window)
        window.delegate = self
        let autosave = "io.remotecode.detachedBotDesktop.\(botID.value.uuidString)"
        if !window.setFrameUsingName(autosave) {
            window.center()
        }
        window.setFrameAutosaveName(autosave)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public func show() {
        viewModel.scheduleFreshnessPass()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

private struct BotGuestDesktopRoot: View {
    @ObservedObject var vm: BotsViewModel

    var body: some View {
        Group {
            if let bot = vm.selectedBot {
                BotComputerGuestCanvas(
                    url: vm.guestScreenURL(for: bot.id),
                    running: vm.isGuestRunning(bot.id),
                    rebuilding: vm.isGuestRebuilding(bot.id),
                    launchState: vm.guestLaunchState(for: bot.id),
                    startIdentifier: "bots.desk.desktop.window.start",
                    rebuildIdentifier: "bots.desk.desktop.window.rebuild",
                    stopIdentifier: "bots.desk.desktop.window.stop",
                    screenIdentifier: "bots.desk.desktop.window.guestScreen",
                    onStart: { vm.presentGuestDesktop(botID: bot.id) },
                    onRebuild: { vm.rebuildDockerGuest(botID: bot.id) },
                    onStop: { vm.stopDockerGuest(botID: bot.id) }
                )
                .padding(DS.Space.lg)
            } else {
                Text("Start the Linux desktop to use this machine.")
                    .font(DS.Font.body)
                    .foregroundColor(DS.Palette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Palette.surface)
        .alert("Bots", isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button("OK") { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "")
        }
        .onAppear { vm.scheduleFreshnessPass() }
    }
}
