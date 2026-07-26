import Foundation

public enum AgentPermissionMode: String, Codable, Sendable, CaseIterable {
    case supervised
    case autoAcceptEdits = "auto_accept_edits"
    case fullAccess = "full_access"
}

public enum AgentReasoningEffort: String, Codable, Sendable, CaseIterable {
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max
    case ultracode

    public static var supportedCases: [AgentReasoningEffort] {
        [.low, .medium, .high, .xhigh]
    }

    /// Claude Code's effort picker exposes two levels beyond the Codex picker:
    /// `max` and `ultracode`. Both are kept out of `supportedCases` because
    /// Codex models fall back to that list and the `codex` CLI rejects them.
    /// `ultracode` is not a `--effort` flag value (the CLI rejects it); it is
    /// the `ultracode` settings key, meaning "xhigh effort + standing dynamic
    /// workflow orchestration". The runner translates it accordingly.
    public static var claudeSupportedCases: [AgentReasoningEffort] {
        [.low, .medium, .high, .xhigh, .max, .ultracode]
    }

    /// Human label for menus. `xhigh` is shown as "Extra High" to match
    /// the Codex CLI's effort picker.
    public var displayName: String {
        switch self {
        case .minimal: return "Minimal"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Extra High"
        case .max: return "Max"
        case .ultracode: return "Ultracode"
        }
    }
}

public enum AgentInteractionMode: String, Codable, Sendable, CaseIterable {
    case `default`
    case plan
}

public enum AgentExecutionMode: String, Codable, Sendable, Equatable, CaseIterable {
    case local
    case worktree
}

public enum AgentServiceTier: String, Codable, Sendable, Equatable, CaseIterable {
    case auto
    case fast
}

public enum AgentAttachmentKind: String, Codable, Sendable, Equatable, Hashable {
    case file
    case image
}

public struct AgentProviderCapabilities: Codable, Sendable, Equatable {
    public let supportsAttachments: Bool
    public let supportedAttachmentKinds: [AgentAttachmentKind]
    public let supportedAttachmentMediaTypes: [String]
    public let supportsApprovals: Bool
    public let supportsUserInput: Bool
    public let supportsStreaming: Bool
    public let supportsFork: Bool
    public let supportsRollback: Bool
    public let supportsPlanReview: Bool

    public init(
        supportsAttachments: Bool = false,
        supportedAttachmentKinds: [AgentAttachmentKind] = [],
        supportedAttachmentMediaTypes: [String] = [],
        supportsApprovals: Bool = false,
        supportsUserInput: Bool = false,
        supportsStreaming: Bool = false,
        supportsFork: Bool = false,
        supportsRollback: Bool = false,
        supportsPlanReview: Bool = false
    ) {
        self.supportsAttachments = supportsAttachments
        self.supportedAttachmentKinds = supportedAttachmentKinds
        self.supportedAttachmentMediaTypes = supportedAttachmentMediaTypes
        self.supportsApprovals = supportsApprovals
        self.supportsUserInput = supportsUserInput
        self.supportsStreaming = supportsStreaming
        self.supportsFork = supportsFork
        self.supportsRollback = supportsRollback
        self.supportsPlanReview = supportsPlanReview
    }

    public static let conservative = AgentProviderCapabilities()

    private enum CodingKeys: String, CodingKey {
        case supportsAttachments, supportedAttachmentKinds, supportedAttachmentMediaTypes
        case supportsApprovals, supportsUserInput, supportsStreaming
        case supportsFork, supportsRollback, supportsPlanReview
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        supportsAttachments = try container.decodeIfPresent(Bool.self, forKey: .supportsAttachments) ?? false
        supportedAttachmentKinds = try container.decodeIfPresent([AgentAttachmentKind].self, forKey: .supportedAttachmentKinds) ?? []
        supportedAttachmentMediaTypes = try container.decodeIfPresent([String].self, forKey: .supportedAttachmentMediaTypes) ?? []
        supportsApprovals = try container.decodeIfPresent(Bool.self, forKey: .supportsApprovals) ?? false
        supportsUserInput = try container.decodeIfPresent(Bool.self, forKey: .supportsUserInput) ?? false
        supportsStreaming = try container.decodeIfPresent(Bool.self, forKey: .supportsStreaming) ?? false
        supportsFork = try container.decodeIfPresent(Bool.self, forKey: .supportsFork) ?? false
        supportsRollback = try container.decodeIfPresent(Bool.self, forKey: .supportsRollback) ?? false
        supportsPlanReview = try container.decodeIfPresent(Bool.self, forKey: .supportsPlanReview) ?? false
    }
}

public struct AgentAttachment: Codable, Sendable, Equatable, Hashable {
    public let id: String?
    public let path: String
    public let displayName: String
    public let kind: AgentAttachmentKind
    public let mimeType: String?
    public let sha256: String?
    public let sizeBytes: Int?

    public init(
        id: String? = nil,
        path: String,
        displayName: String? = nil,
        kind: AgentAttachmentKind,
        mimeType: String? = nil,
        sha256: String? = nil,
        sizeBytes: Int? = nil
    ) {
        self.id = id
        self.path = path
        self.displayName = displayName ?? URL(fileURLWithPath: path).lastPathComponent
        self.kind = kind
        self.mimeType = mimeType
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
    }
}

/// Path-free attachment metadata safe to expose to paired clients. `id` is an
/// opaque host-owned attachment-reference identifier; clients must return it unchanged and
/// never receive or manufacture the provider-visible host path.
public struct AgentAttachmentReference: Codable, Sendable, Equatable, Hashable {
    public let id: String
    public let displayName: String
    public let kind: AgentAttachmentKind
    public let mimeType: String?
    public let sha256: String
    public let sizeBytes: Int

    public init(
        id: String,
        displayName: String,
        kind: AgentAttachmentKind,
        mimeType: String?,
        sha256: String,
        sizeBytes: Int
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.mimeType = mimeType
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
    }

    public init?(_ attachment: AgentAttachment) {
        guard let id = attachment.id ?? attachment.sha256,
              let sha256 = attachment.sha256 ?? Self.legacyDigest(id),
              let sizeBytes = attachment.sizeBytes else { return nil }
        self.init(
            id: id,
            displayName: attachment.displayName,
            kind: attachment.kind,
            mimeType: attachment.mimeType,
            sha256: sha256,
            sizeBytes: sizeBytes
        )
    }

    private static func legacyDigest(_ value: String) -> String? {
        let normalized = value.lowercased()
        guard normalized.count == 64,
              normalized.allSatisfy(\.isHexDigit) else { return nil }
        return normalized
    }
}

public struct AgentAttachmentUploadResult: Codable, Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let kind: AgentAttachmentKind
    public let mimeType: String?
    public let sha256: String
    public let sizeBytes: Int
    /// Absolute host path for paired clients to insert into composer text
    /// (macOS drag/drop parity). Not a structured-attachment wire field.
    public let composerInsertionText: String

    public init(
        id: String,
        displayName: String,
        kind: AgentAttachmentKind,
        mimeType: String?,
        sha256: String,
        sizeBytes: Int,
        composerInsertionText: String
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.mimeType = mimeType
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.composerInsertionText = composerInsertionText
    }

    public init(_ reference: AgentAttachmentReference, composerInsertionText: String) {
        self.init(
            id: reference.id,
            displayName: reference.displayName,
            kind: reference.kind,
            mimeType: reference.mimeType,
            sha256: reference.sha256,
            sizeBytes: reference.sizeBytes,
            composerInsertionText: composerInsertionText
        )
    }
}

public enum AgentAttachmentResolverError: Error, CustomStringConvertible, Equatable {
    case notFound(String)
    case notReadableFile(String)
    case exceedsMaximumSize(String, Int)
    case malformedReference(String)

    public var description: String {
        switch self {
        case .notFound(let path): return "Attachment not found: \(path)"
        case .notReadableFile(let path): return "Attachment is not a readable file: \(path)"
        case .exceedsMaximumSize(let name, let maximumBytes):
            return "Attachment exceeds the \(maximumBytes)-byte limit: \(name)"
        case .malformedReference(let value): return "Malformed attachment reference: \(value)"
        }
    }
}

public enum AgentAttachmentResolver {
    public static func resolve(paths: [String], fileManager: FileManager = .default) throws -> [AgentAttachment] {
        var seen = Set<String>()
        var resolved: [AgentAttachment] = []
        for raw in paths {
            let expanded = (raw.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
            guard !expanded.isEmpty else { continue }
            let url = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                throw AgentAttachmentResolverError.notFound(raw)
            }
            guard !isDirectory.boolValue, fileManager.isReadableFile(atPath: url.path) else {
                throw AgentAttachmentResolverError.notReadableFile(raw)
            }
            guard seen.insert(url.path).inserted else { continue }
            resolved.append(AgentAttachment(
                path: url.path,
                displayName: url.lastPathComponent,
                kind: imageExtensions.contains(url.pathExtension.lowercased()) ? .image : .file,
                mimeType: mimeType(forExtension: url.pathExtension.lowercased())
            ))
        }
        return resolved
    }

    private static let imageExtensions = Set(["png", "jpg", "jpeg", "gif", "bmp", "tif", "tiff", "heic", "webp", "svg", "avif"])

    private static func mimeType(forExtension ext: String) -> String? {
        switch ext {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "bmp": return "image/bmp"
        case "tif", "tiff": return "image/tiff"
        case "heic": return "image/heic"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "avif": return "image/avif"
        case "txt", "log", "csv", "swift", "m", "mm", "h", "c", "cc", "cpp", "js", "ts", "tsx", "jsx", "css", "html", "xml", "yaml", "yml": return "text/plain"
        case "md", "markdown": return "text/markdown"
        case "json": return "application/json"
        case "pdf": return "application/pdf"
        default: return nil
        }
    }
}

public struct AgentModelSelection: Codable, Sendable, Equatable, Hashable {
    public var provider: AgentProvider
    public var modelId: String
    public var customModelId: String?
    public var reasoningEffort: AgentReasoningEffort
    public var serviceTier: AgentServiceTier

    public var effectiveModel: String {
        let custom = customModelId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return custom.isEmpty ? modelId : custom
    }

    public init(
        provider: AgentProvider,
        modelId: String,
        customModelId: String? = nil,
        reasoningEffort: AgentReasoningEffort = .medium,
        serviceTier: AgentServiceTier = .auto
    ) {
        self.provider = provider
        self.modelId = modelId
        self.customModelId = customModelId?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.reasoningEffort = reasoningEffort
        self.serviceTier = serviceTier
    }
}

public enum AgentRoutingMode: String, Codable, Sendable, Equatable, CaseIterable {
    case manual
    case auto
}

public enum AgentRoutingRevisionError: Error, Sendable, Equatable {
    case conflict(expected: Int, actual: Int)
}

/// Thread-owned model-routing state. The manual selection remains authoritative
/// while Auto is enabled so turning Auto off restores every picker value exactly.
public struct AgentRoutingConfiguration: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var mode: AgentRoutingMode
    public var manualSelection: AgentModelSelection
    public var manualProviderInstanceId: String?
    public var eligibleProviders: [AgentProvider]
    public var policyDigest: String
    public var revision: Int
    public var updatedAt: Date

    public init(
        schemaVersion: Int = AgentRoutingConfiguration.currentSchemaVersion,
        mode: AgentRoutingMode,
        manualSelection: AgentModelSelection,
        manualProviderInstanceId: String? = nil,
        eligibleProviders: [AgentProvider] = AgentProvider.allCases,
        policyDigest: String = "",
        revision: Int = 0,
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.mode = mode
        self.manualSelection = manualSelection
        self.manualProviderInstanceId = manualProviderInstanceId
        self.eligibleProviders = eligibleProviders
        self.policyDigest = policyDigest
        self.revision = revision
        self.updatedAt = updatedAt
    }

    public static func legacyManual(
        selection: AgentModelSelection,
        providerInstanceId: String? = nil,
        updatedAt: Date = Date()
    ) -> AgentRoutingConfiguration {
        AgentRoutingConfiguration(
            mode: .manual,
            manualSelection: selection,
            manualProviderInstanceId: providerInstanceId,
            updatedAt: updatedAt
        )
    }

    public func replacing(
        expectedRevision: Int,
        mode: AgentRoutingMode,
        manualSelection: AgentModelSelection,
        manualProviderInstanceId: String?,
        eligibleProviders: [AgentProvider],
        policyDigest: String,
        updatedAt: Date = Date()
    ) throws -> AgentRoutingConfiguration {
        guard expectedRevision == revision else {
            throw AgentRoutingRevisionError.conflict(expected: expectedRevision, actual: revision)
        }
        return AgentRoutingConfiguration(
            schemaVersion: schemaVersion,
            mode: mode,
            manualSelection: manualSelection,
            manualProviderInstanceId: manualProviderInstanceId,
            eligibleProviders: eligibleProviders,
            policyDigest: policyDigest,
            revision: revision + 1,
            updatedAt: updatedAt
        )
    }
}

public enum AgentRunAcceptanceError: Error, LocalizedError, Sendable {
    case cancelled

    public var errorDescription: String? {
        "Provider start was cancelled before prompt acceptance."
    }
}

public enum AgentRunAcceptanceOutcome: Sendable, Equatable {
    case notAccepted
    case accepted
    case unknown
}

/// Completion for a provider write that already claimed its acceptance permit.
/// Invalidation never waits on provider I/O; destructive callers may await this
/// object asynchronously after issuing provider stop.
public final class AgentRunAcceptanceAttempt: @unchecked Sendable {
    private let lock = NSLock()
    private var isComplete = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    fileprivate init() {}

    public func wait() async {
        if lock.withLock({ isComplete }) { return }
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                guard !isComplete else { return true }
                waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    fileprivate func complete() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            guard !isComplete else { return [] }
            isComplete = true
            let pending = waiters
            waiters.removeAll()
            return pending
        }
        pending.forEach { $0.resume() }
    }
}

/// Linearizes a queued dispatch's final cancellation check with the provider's
/// actual prompt write without holding a lock across provider I/O. A claimed
/// write linearizes before later invalidation; destructive flows then stop and
/// await that provider instead of blocking the MainActor on a pipe write.
public final class AgentRunAcceptancePermit: @unchecked Sendable {
    private enum State {
        case pending
        case invalidated
        case claimed(AgentRunAcceptanceAttempt)
        case accepted
        case unknown
    }

    private let lock = NSLock()
    private var state: State = .pending

    public init() {}

    @discardableResult
    public func invalidate() -> AgentRunAcceptanceAttempt? {
        lock.withLock {
            if case .pending = state {
                state = .invalidated
                return nil
            }
            if case .claimed(let attempt) = state {
                return attempt
            }
            return nil
        }
    }

    public var outcome: AgentRunAcceptanceOutcome {
        lock.withLock {
            switch state {
            case .pending, .invalidated:
                return .notAccepted
            case .accepted:
                return .accepted
            case .claimed, .unknown:
                return .unknown
            }
        }
    }

    public func withAcceptance<T>(
        failureOutcome: AgentRunAcceptanceOutcome = .unknown,
        _ body: () throws -> T
    ) throws -> T {
        let attempt = try lock.withLock { () throws -> AgentRunAcceptanceAttempt in
            guard case .pending = state else {
                throw AgentRunAcceptanceError.cancelled
            }
            let attempt = AgentRunAcceptanceAttempt()
            state = .claimed(attempt)
            return attempt
        }
        defer { attempt.complete() }
        do {
            let result = try body()
            lock.withLock { state = .accepted }
            return result
        } catch {
            lock.withLock {
                state = failureOutcome == .notAccepted ? .invalidated : .unknown
            }
            throw error
        }
    }
}

public struct AgentRunRequest: Codable, Sendable, Equatable {
    public let runId: AgentRunID
    public let threadId: AgentThreadID
    public let provider: AgentProvider
    public let providerInstanceId: String?
    public let model: String
    public let cwd: String
    public let prompt: String
    public let userMessageContent: String?
    public let attachments: [AgentAttachment]
    public let providerThreadId: String?
    public let permissionMode: AgentPermissionMode
    public let reasoningEffort: AgentReasoningEffort?
    public let serviceTier: AgentServiceTier
    public let interactionMode: AgentInteractionMode
    public let providerBinary: String?
    public let environment: [String: String]
    public let extraArgs: [String]
    public let runAsUser: AgentRunAsUser?
    /// Runtime-only queue dispatch gate. Intentionally excluded from Codable and
    /// value equality; it has no meaning outside the current host process.
    public var acceptancePermit: AgentRunAcceptancePermit?

    public init(
        runId: AgentRunID = AgentRunID(),
        threadId: AgentThreadID,
        provider: AgentProvider,
        providerInstanceId: String? = nil,
        model: String,
        cwd: String,
        prompt: String,
        userMessageContent: String? = nil,
        attachments: [AgentAttachment] = [],
        providerThreadId: String? = nil,
        permissionMode: AgentPermissionMode = .supervised,
        reasoningEffort: AgentReasoningEffort? = nil,
        serviceTier: AgentServiceTier = .auto,
        interactionMode: AgentInteractionMode = .default,
        providerBinary: String? = nil,
        environment: [String: String] = [:],
        extraArgs: [String] = [],
        runAsUser: AgentRunAsUser? = nil,
        acceptancePermit: AgentRunAcceptancePermit? = nil
    ) {
        self.runId = runId
        self.threadId = threadId
        self.provider = provider
        self.providerInstanceId = providerInstanceId
        self.model = model
        self.cwd = cwd
        self.prompt = prompt
        self.userMessageContent = userMessageContent
        self.attachments = attachments
        self.providerThreadId = providerThreadId
        self.permissionMode = permissionMode
        self.reasoningEffort = reasoningEffort
        self.serviceTier = serviceTier
        self.interactionMode = interactionMode
        self.providerBinary = providerBinary
        self.environment = environment
        self.extraArgs = extraArgs
        self.runAsUser = runAsUser
        self.acceptancePermit = acceptancePermit
    }

    private enum CodingKeys: String, CodingKey {
        case runId, threadId, provider, providerInstanceId, model, cwd, prompt, userMessageContent, attachments, providerThreadId, permissionMode, reasoningEffort, serviceTier, interactionMode, providerBinary, environment, extraArgs, runAsUser
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runId = try c.decodeIfPresent(AgentRunID.self, forKey: .runId) ?? AgentRunID()
        threadId = try c.decode(AgentThreadID.self, forKey: .threadId)
        provider = try c.decode(AgentProvider.self, forKey: .provider)
        providerInstanceId = try c.decodeIfPresent(String.self, forKey: .providerInstanceId)
        model = try c.decode(String.self, forKey: .model)
        cwd = try c.decode(String.self, forKey: .cwd)
        prompt = try c.decode(String.self, forKey: .prompt)
        userMessageContent = try c.decodeIfPresent(String.self, forKey: .userMessageContent)
        attachments = try c.decodeIfPresent([AgentAttachment].self, forKey: .attachments) ?? []
        providerThreadId = try c.decodeIfPresent(String.self, forKey: .providerThreadId)
        permissionMode = try c.decodeIfPresent(AgentPermissionMode.self, forKey: .permissionMode) ?? .supervised
        reasoningEffort = try c.decodeIfPresent(AgentReasoningEffort.self, forKey: .reasoningEffort)
        serviceTier = try c.decodeIfPresent(AgentServiceTier.self, forKey: .serviceTier) ?? .auto
        interactionMode = try c.decodeIfPresent(AgentInteractionMode.self, forKey: .interactionMode) ?? .default
        providerBinary = try c.decodeIfPresent(String.self, forKey: .providerBinary)
        environment = try c.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        extraArgs = try c.decodeIfPresent([String].self, forKey: .extraArgs) ?? []
        runAsUser = try c.decodeIfPresent(AgentRunAsUser.self, forKey: .runAsUser)
        acceptancePermit = nil
    }

    public static func == (lhs: AgentRunRequest, rhs: AgentRunRequest) -> Bool {
        lhs.runId == rhs.runId
            && lhs.threadId == rhs.threadId
            && lhs.provider == rhs.provider
            && lhs.providerInstanceId == rhs.providerInstanceId
            && lhs.model == rhs.model
            && lhs.cwd == rhs.cwd
            && lhs.prompt == rhs.prompt
            && lhs.userMessageContent == rhs.userMessageContent
            && lhs.attachments == rhs.attachments
            && lhs.providerThreadId == rhs.providerThreadId
            && lhs.permissionMode == rhs.permissionMode
            && lhs.reasoningEffort == rhs.reasoningEffort
            && lhs.serviceTier == rhs.serviceTier
            && lhs.interactionMode == rhs.interactionMode
            && lhs.providerBinary == rhs.providerBinary
            && lhs.environment == rhs.environment
            && lhs.extraArgs == rhs.extraArgs
            && lhs.runAsUser == rhs.runAsUser
    }

    public var providerPrompt: String {
        AgentProviderInstructionText.providerPrompt(for: interactionMode, prompt: prompt)
    }
}

public enum AgentProviderInstructionText {
    public static func providerPrompt(for mode: AgentInteractionMode, prompt: String) -> String {
        """
        \(providerPreamble(for: mode))

        User request:
        \(prompt)
        """
    }

    /// The base mode instruction Codex receives every turn as `developer_instructions`. The Token
    /// Saver distill spec is composed on top of this in `CodexAppServerClient` (it owns the full
    /// distill body, which lives in the AgentRuntime layer); this stays a focused, mode-only base.
    public static func developerInstructions(for mode: AgentInteractionMode) -> String {
        switch mode {
        case .default:
            return "Implement clear requests; keep scope; preserve unrelated work; verify; ask before ambiguous/risky edits."
        case .plan:
            return "Plan only. Do not edit, run destructive commands, or implement until user approval."
        }
    }

    public static func providerPreamble(for mode: AgentInteractionMode) -> String {
        switch mode {
        case .default:
            return "Default mode. Implement clear requests; keep scope; preserve unrelated work; verify; ask before ambiguous/risky edits."
        case .plan:
            return "Plan mode. Produce a concrete plan only. Do not edit files, run destructive commands, or implement until approved. If available, call ExitPlanMode once with the final plan, then wait."
        }
    }
}

public enum AgentRunStatus: String, Codable, Sendable {
    case pending
    case running
    case completed
    case failed
    case cancelled
    case interrupted
}

public struct AgentModelDescriptor: Codable, Sendable, Equatable, Hashable {
    public let id: String
    public let label: String
    public let provider: AgentProvider
    public let supportsReasoning: Bool
    public let supportedReasoningEfforts: [AgentReasoningEffort]
    public let supportsServiceTier: Bool
    public let supportsCustomModel: Bool
    public let contextWindowTokens: Int?

    public init(
        id: String,
        label: String,
        provider: AgentProvider,
        supportsReasoning: Bool = false,
        supportedReasoningEfforts: [AgentReasoningEffort]? = nil,
        supportsServiceTier: Bool = false,
        supportsCustomModel: Bool = false,
        contextWindowTokens: Int? = nil
    ) {
        self.id = id
        self.label = label
        self.provider = provider
        self.supportsReasoning = supportsReasoning
        self.supportedReasoningEfforts = supportedReasoningEfforts ?? (supportsReasoning ? AgentReasoningEffort.supportedCases : [])
        self.supportsServiceTier = supportsServiceTier
        self.supportsCustomModel = supportsCustomModel
        self.contextWindowTokens = contextWindowTokens
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, provider, supportsReasoning, supportedReasoningEfforts, supportsServiceTier, supportsCustomModel, contextWindowTokens
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        provider = try c.decode(AgentProvider.self, forKey: .provider)
        supportsReasoning = try c.decodeIfPresent(Bool.self, forKey: .supportsReasoning) ?? false
        supportedReasoningEfforts = try c.decodeIfPresent([AgentReasoningEffort].self, forKey: .supportedReasoningEfforts)
            ?? (supportsReasoning ? AgentReasoningEffort.supportedCases : [])
        supportsServiceTier = try c.decodeIfPresent(Bool.self, forKey: .supportsServiceTier) ?? false
        supportsCustomModel = try c.decodeIfPresent(Bool.self, forKey: .supportsCustomModel) ?? false
        contextWindowTokens = try c.decodeIfPresent(Int.self, forKey: .contextWindowTokens)
    }
}

public enum AgentProviderDriverKind: String, Codable, Sendable {
    case codexCLI = "codex_cli"
    case claudeCLI = "claude_cli"
    case grokCLI = "grok_cli"
}

public enum AgentProviderSnapshotStatus: String, Codable, Sendable {
    case available
    case unavailable
    case warning
    case disabled
}

public enum AgentModelDiscoverySource: String, Codable, Sendable {
    case live
    case builtInFallback
}

public struct AgentProviderSnapshot: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let provider: AgentProvider
    public let driverKind: AgentProviderDriverKind
    public let displayName: String
    public let accentColor: String
    public let continuationGroup: String
    public let interactionModes: [AgentInteractionMode]
    public let permissionModes: [AgentPermissionMode]?
    public let enabled: Bool
    public let installed: Bool
    public let version: String?
    public let status: AgentProviderSnapshotStatus
    public let statusDetail: String?
    public let authenticated: Bool?
    public let accountLabel: String?
    public let accountAuthMethod: String?
    public let binaryPath: String?
    public let homePath: String?
    public let environmentKeys: [String]
    public let models: [AgentModelDescriptor]
    public let slashCommands: [String]
    public let skills: [String]
    public let advisory: String?
    public let updateState: String?
    public let capabilities: AgentProviderCapabilities?
    public let modelDiscoverySource: AgentModelDiscoverySource?
    /// Opaque cache identity. It contains no raw environment values or account data.
    public let modelDiscoveryCacheKey: String?

    public var effectiveCapabilities: AgentProviderCapabilities {
        capabilities ?? .conservative
    }

    public var effectivePermissionModes: [AgentPermissionMode] {
        permissionModes ?? [.supervised]
    }

    public var modelListIsFallback: Bool {
        modelDiscoverySource == .builtInFallback
    }

    public var accountSummary: String? {
        let label = accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let method = accountAuthMethod?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !label.isEmpty && !method.isEmpty { return "\(label) via \(method)" }
        if !label.isEmpty { return label }
        if !method.isEmpty { return "Authenticated via \(method)" }
        return nil
    }

    public var recoveryActionTitle: String? {
        if updateState == "update_available" || (advisory?.localizedCaseInsensitiveContains("update") == true) {
            return "Update \(displayName)"
        }
        if authenticated == false {
            return "Copy login command"
        }
        if !installed {
            return "Copy install command"
        }
        return nil
    }

    public init(
        id: String,
        provider: AgentProvider,
        driverKind: AgentProviderDriverKind,
        displayName: String,
        accentColor: String,
        continuationGroup: String,
        interactionModes: [AgentInteractionMode],
        permissionModes: [AgentPermissionMode]? = nil,
        enabled: Bool,
        installed: Bool,
        version: String? = nil,
        status: AgentProviderSnapshotStatus,
        statusDetail: String? = nil,
        authenticated: Bool? = nil,
        accountLabel: String? = nil,
        accountAuthMethod: String? = nil,
        binaryPath: String? = nil,
        homePath: String? = nil,
        environmentKeys: [String] = [],
        models: [AgentModelDescriptor],
        slashCommands: [String],
        skills: [String] = [],
        advisory: String? = nil,
        updateState: String? = nil,
        capabilities: AgentProviderCapabilities? = nil,
        modelDiscoverySource: AgentModelDiscoverySource? = nil,
        modelDiscoveryCacheKey: String? = nil
    ) {
        self.id = id
        self.provider = provider
        self.driverKind = driverKind
        self.displayName = displayName
        self.accentColor = accentColor
        self.continuationGroup = continuationGroup
        self.interactionModes = interactionModes
        self.permissionModes = permissionModes
        self.enabled = enabled
        self.installed = installed
        self.version = version
        self.status = status
        self.statusDetail = statusDetail
        self.authenticated = authenticated
        self.accountLabel = accountLabel
        self.accountAuthMethod = accountAuthMethod
        self.binaryPath = binaryPath
        self.homePath = homePath
        self.environmentKeys = environmentKeys
        self.models = models
        self.slashCommands = slashCommands
        self.skills = skills
        self.advisory = advisory
        self.updateState = updateState
        self.capabilities = capabilities
        self.modelDiscoverySource = modelDiscoverySource
        self.modelDiscoveryCacheKey = modelDiscoveryCacheKey
    }
}

public enum AgentProviderRunPreflightError: Error, CustomStringConvertible, Equatable {
    case missingSnapshot
    case disabled(String)
    case unavailable(String)
    case unauthenticated(String)
    case unsupportedInteractionMode(String, AgentInteractionMode)
    case unsupportedPermissionMode(String, AgentPermissionMode)
    case attachmentsUnsupported(String)
    case attachmentKindUnsupported(String, AgentAttachmentKind)
    case attachmentMediaTypeUnsupported(String, String)

    public var description: String {
        switch self {
        case .missingSnapshot:
            return "Provider capabilities are not loaded yet."
        case .disabled(let provider):
            return "\(provider) is disabled."
        case .unavailable(let provider):
            return "\(provider) is unavailable."
        case .unauthenticated(let provider):
            return "\(provider) is not authenticated. Sign in to continue."
        case .unsupportedInteractionMode(let provider, let mode):
            return "\(provider) does not support \(mode.rawValue) mode for this session."
        case .unsupportedPermissionMode(let provider, let mode):
            return "\(provider) does not support \(mode.rawValue) permission for this session."
        case .attachmentsUnsupported(let provider):
            return "\(provider) does not support attachments for this session."
        case .attachmentKindUnsupported(let provider, let kind):
            return "\(provider) does not support \(kind.rawValue) attachments for this session."
        case .attachmentMediaTypeUnsupported(let provider, let mediaType):
            return "\(provider) does not support attachment media type \(mediaType)."
        }
    }
}

/// Shared snapshot pick for host preflight and surface selection.
/// Prefer exact instance+provider, then same-provider fallback (covers
/// raw "grok" vs "grok-cli" and stale instance ids without cross-provider bleed).
public enum AgentProviderSnapshotSelection {
    public static func resolve(
        snapshots: [AgentProviderSnapshot],
        provider: AgentProvider,
        instanceId: String?
    ) -> AgentProviderSnapshot? {
        // Prefer exact instance id only when it belongs to the requested
        // provider. Cross-provider ids (e.g. stale "codex-cli" while selecting
        // Grok) must fall through so preflight never runs the wrong CLI.
        if let instanceId,
           let exact = snapshots.first(where: { $0.id == instanceId && $0.provider == provider }) {
            return exact
        }
        return snapshots.first(where: { $0.provider == provider })
    }
}

/// Model defaults for a new / rebound provider selection.
/// Prefer the last model the user explicitly used for that provider; otherwise
/// a built-in default (Codex → `gpt-5.6-sol`); otherwise the first listed id.
public enum AgentDefaultModelSelection {
    public static let codexBuiltInDefault = "gpt-5.6-sol"

    public static func builtInDefault(for provider: AgentProvider) -> String {
        switch provider {
        case .codex: return codexBuiltInDefault
        case .claude, .grok: return ""
        }
    }

    public static func resolve(
        provider: AgentProvider,
        lastUsed: String?,
        availableModelIds: [String],
        supportsCustomModel: Bool = true
    ) -> String {
        // 1) Last model the user chose for this provider always wins — even when
        // the current discovery list omits it (custom id / stale baked-in list).
        let last = lastUsed?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !last.isEmpty { return last }
        // 2) Provider built-in (Codex → gpt-5.6-sol) before first list row so a
        // stale list still open on the product default.
        let builtIn = builtInDefault(for: provider)
        if !builtIn.isEmpty { return builtIn }
        // 3) First named id from discovery (skip empty "account default" row).
        _ = supportsCustomModel // reserved for callers that already computed it
        if let firstNamed = availableModelIds.first(where: { !$0.isEmpty }) {
            return firstNamed
        }
        return availableModelIds.first ?? ""
    }
}

/// No provider is mandatory. When the preferred selection cannot run (missing
/// binary, disabled, unauthenticated), pick another installed provider so
/// Claude/Grok still work without Codex CLI (and vice versa).
public enum AgentProviderRunnableSelection {
    /// Basic runnability for account selection — same gates as send preflight
    /// for enabled / installed / authenticated, without mode or attachment checks.
    public static func isRunnable(_ snapshot: AgentProviderSnapshot) -> Bool {
        guard snapshot.enabled, snapshot.status != .disabled else { return false }
        guard snapshot.installed, snapshot.status != .unavailable else { return false }
        guard snapshot.authenticated != false else { return false }
        return true
    }

    /// Prefer the current selection when runnable; otherwise the first runnable
    /// snapshot in `AgentProvider.allCases` order. If nothing is runnable,
    /// keep the preferred row so recovery UI can still name the failure.
    public static func resolve(
        snapshots: [AgentProviderSnapshot],
        preferredProvider: AgentProvider,
        preferredInstanceId: String?
    ) -> AgentProviderSnapshot? {
        if let current = AgentProviderSnapshotSelection.resolve(
            snapshots: snapshots,
            provider: preferredProvider,
            instanceId: preferredInstanceId
        ), isRunnable(current) {
            return current
        }
        for provider in AgentProvider.allCases {
            if let snap = snapshots.first(where: { $0.provider == provider && isRunnable($0) }) {
                return snap
            }
        }
        return AgentProviderSnapshotSelection.resolve(
            snapshots: snapshots,
            provider: preferredProvider,
            instanceId: preferredInstanceId
        )
            ?? snapshots.first(where: \.enabled)
            ?? snapshots.first
    }
}

/// Single fail-closed provider gate shared by desktop and mirror execution.
/// This must run before a draft, queue, user message, thread, or run is mutated.
public enum AgentProviderRunPreflight {
    public static func validate(
        snapshot: AgentProviderSnapshot?,
        interactionMode: AgentInteractionMode,
        permissionMode: AgentPermissionMode,
        attachments: [AgentAttachment]
    ) throws {
        guard let snapshot else { throw AgentProviderRunPreflightError.missingSnapshot }
        let name = snapshot.displayName
        guard snapshot.enabled, snapshot.status != .disabled else {
            throw AgentProviderRunPreflightError.disabled(name)
        }
        guard snapshot.installed, snapshot.status != .unavailable else {
            throw AgentProviderRunPreflightError.unavailable(name)
        }
        guard snapshot.authenticated != false else {
            throw AgentProviderRunPreflightError.unauthenticated(name)
        }
        guard snapshot.interactionModes.contains(interactionMode) else {
            throw AgentProviderRunPreflightError.unsupportedInteractionMode(name, interactionMode)
        }
        guard snapshot.effectivePermissionModes.contains(permissionMode) else {
            throw AgentProviderRunPreflightError.unsupportedPermissionMode(name, permissionMode)
        }
        guard attachments.isEmpty || snapshot.effectiveCapabilities.supportsAttachments else {
            throw AgentProviderRunPreflightError.attachmentsUnsupported(name)
        }
        let capabilities = snapshot.effectiveCapabilities
        let supportedMediaTypes = Set(capabilities.supportedAttachmentMediaTypes.map(normalizedMediaType))
        for attachment in attachments {
            guard capabilities.supportedAttachmentKinds.contains(attachment.kind) else {
                throw AgentProviderRunPreflightError.attachmentKindUnsupported(name, attachment.kind)
            }
            let mediaType = normalizedMediaType(attachment.mimeType ?? "")
            guard !mediaType.isEmpty,
                  supportedMediaTypes.contains(mediaType) ||
                    (attachment.kind == .file && supportedMediaTypes.contains("*/*")) else {
                throw AgentProviderRunPreflightError.attachmentMediaTypeUnsupported(
                    name,
                    mediaType.isEmpty ? "unknown" : mediaType
                )
            }
        }
    }

    private static func normalizedMediaType(_ raw: String) -> String {
        raw.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }
}

public enum AgentProviderSnapshotFactory {
    public static func snapshot(provider: AgentProvider, models: [AgentModelDescriptor], binaryPath: String? = nil, version: String? = nil, authenticated: Bool? = nil, accountLabel: String? = nil, accountAuthMethod: String? = nil, updateState: String? = nil, advisory: String? = nil, slashCommands: [String] = [], skills: [String] = [], id: String? = nil, displayName: String? = nil, accentColor: String? = nil, enabled: Bool = true, homePath: String? = nil, environmentKeys: [String] = [], interactionModesOverride: [AgentInteractionMode]? = nil, permissionModesOverride: [AgentPermissionMode]? = nil, capabilitiesOverride: AgentProviderCapabilities? = nil, modelDiscoverySource: AgentModelDiscoverySource? = nil, modelDiscoveryCacheKey: String? = nil) -> AgentProviderSnapshot {
        let installed = binaryPath.map { !$0.isEmpty } ?? !models.isEmpty
        switch provider {
        case .codex:
            let codexCapabilities = capabilitiesOverride ?? AgentProviderCapabilities(
                supportsAttachments: true,
                supportedAttachmentKinds: [.file, .image],
                supportedAttachmentMediaTypes: ["*/*", "image/jpeg", "image/png", "image/gif", "image/webp"],
                supportsApprovals: true,
                supportsUserInput: true,
                supportsStreaming: true,
                // The current app-server `thread/fork` schema has no client
                // idempotency key. `thread/delete` cannot close the crash window
                // between provider creation and local persistence, so the
                // feature must remain hidden until the provider contract changes.
                supportsFork: false,
                supportsRollback: true,
                supportsPlanReview: true
            )
            let status: AgentProviderSnapshotStatus = enabled
                ? (!installed || models.isEmpty ? .unavailable : (authenticated == false || updateState == "update_available" ? .warning : .available))
                : .disabled
            let statusDetail = Self.statusDetail(
                providerName: "Codex",
                installed: installed,
                hasModels: !models.isEmpty,
                authenticated: authenticated,
                advisory: advisory,
                updateState: updateState,
                enabled: enabled
            )
            return AgentProviderSnapshot(
                id: id ?? "codex-cli",
                provider: .codex,
                driverKind: .codexCLI,
                displayName: displayName ?? "Codex",
                accentColor: accentColor ?? "#2F80ED",
                continuationGroup: "openai-codex",
                interactionModes: [.default, .plan],
                permissionModes: AgentPermissionMode.allCases,
                enabled: enabled,
                installed: installed,
                version: version,
                status: status,
                statusDetail: statusDetail,
                authenticated: authenticated,
                accountLabel: accountLabel,
                accountAuthMethod: accountAuthMethod,
                binaryPath: binaryPath?.isEmpty == false ? binaryPath : nil,
                homePath: homePath?.isEmpty == false ? homePath : nil,
                environmentKeys: environmentKeys,
                models: models,
                slashCommands: uniqueSlashCommands(defaults: ["/clear", "/default", "/model", "/plan", "/status", "/goal"], probed: slashCommands)
                    .filter { $0 != "/fork" || codexCapabilities.supportsFork },
                skills: unique(skills),
                advisory: advisory,
                updateState: updateState,
                capabilities: codexCapabilities,
                modelDiscoverySource: modelDiscoverySource,
                modelDiscoveryCacheKey: modelDiscoveryCacheKey
            )
        case .claude:
            let status: AgentProviderSnapshotStatus = enabled
                ? (!installed || models.isEmpty ? .unavailable : (authenticated == false || updateState == "update_available" || capabilitiesOverride != nil ? .warning : .available))
                : .disabled
            let statusDetail = Self.statusDetail(
                providerName: "Claude",
                installed: installed,
                hasModels: !models.isEmpty,
                authenticated: authenticated,
                advisory: advisory,
                updateState: updateState,
                enabled: enabled
            )
            return AgentProviderSnapshot(
                id: id ?? "claude-cli",
                provider: .claude,
                driverKind: .claudeCLI,
                displayName: displayName ?? "Claude",
                accentColor: accentColor ?? "#D97706",
                continuationGroup: "anthropic-claude",
                interactionModes: interactionModesOverride ?? [.default, .plan],
                permissionModes: permissionModesOverride ?? AgentPermissionMode.allCases,
                enabled: enabled,
                installed: installed,
                version: version,
                status: status,
                statusDetail: statusDetail,
                authenticated: authenticated,
                accountLabel: accountLabel,
                accountAuthMethod: accountAuthMethod,
                binaryPath: binaryPath?.isEmpty == false ? binaryPath : nil,
                homePath: homePath?.isEmpty == false ? homePath : nil,
                environmentKeys: environmentKeys,
                models: models,
                slashCommands: uniqueSlashCommands(
                    // `/goal` is a universal pass-through prompt command (Codex-native;
                    // Claude/Grok receive it as the first user token, same as `/goal` in composer).
                    defaults: (interactionModesOverride ?? [.default, .plan]).contains(.plan)
                        ? ["/clear", "/default", "/model", "/plan", "/status", "/fork", "/goal"]
                        : ["/clear", "/default", "/model", "/status", "/goal"],
                    probed: slashCommands
                ),
                skills: unique(skills),
                advisory: advisory,
                updateState: updateState,
                capabilities: capabilitiesOverride ?? AgentProviderCapabilities(
                    supportsAttachments: true,
                    supportedAttachmentKinds: [.image],
                    supportedAttachmentMediaTypes: ["image/jpeg", "image/png", "image/gif", "image/webp"],
                    supportsApprovals: true,
                    supportsUserInput: true,
                    supportsStreaming: true,
                    supportsPlanReview: true
                ),
                modelDiscoverySource: modelDiscoverySource,
                modelDiscoveryCacheKey: modelDiscoveryCacheKey
            )
        case .grok:
            let status: AgentProviderSnapshotStatus = enabled
                ? (!installed || models.isEmpty ? .unavailable : (authenticated == false || updateState == "update_available" ? .warning : .available))
                : .disabled
            let statusDetail = Self.statusDetail(
                providerName: "Grok",
                installed: installed,
                hasModels: !models.isEmpty,
                authenticated: authenticated,
                advisory: advisory,
                updateState: updateState,
                enabled: enabled
            )
            return AgentProviderSnapshot(
                id: id ?? "grok-cli",
                provider: .grok,
                driverKind: .grokCLI,
                displayName: displayName ?? "Grok",
                accentColor: accentColor ?? "#1DA1F2",
                continuationGroup: "xai-grok",
                interactionModes: interactionModesOverride ?? [.default],
                // Grok CLI accepts default / acceptEdits / bypassPermissions even when
                // ACP session/new omits modes.advertisement. Default open so Full access
                // is selectable before discovery; discovery may still narrow the set.
                permissionModes: permissionModesOverride ?? AgentPermissionMode.allCases,
                enabled: enabled,
                installed: installed,
                version: version,
                status: status,
                statusDetail: statusDetail,
                authenticated: authenticated,
                accountLabel: accountLabel,
                accountAuthMethod: accountAuthMethod,
                binaryPath: binaryPath?.isEmpty == false ? binaryPath : nil,
                homePath: homePath?.isEmpty == false ? homePath : nil,
                environmentKeys: environmentKeys,
                models: models,
                slashCommands: uniqueSlashCommands(
                    // `/goal` offered on every provider so composer autocomplete and
                    // `$goal` → `/goal` normalization work for Codex, Claude, and Grok.
                    defaults: (interactionModesOverride ?? [.default]).contains(.plan)
                        ? ["/clear", "/default", "/model", "/plan", "/status", "/goal"]
                        : ["/clear", "/default", "/model", "/status", "/goal"],
                    probed: slashCommands
                ),
                skills: unique(skills),
                advisory: advisory,
                updateState: updateState,
                capabilities: capabilitiesOverride ?? .conservative,
                modelDiscoverySource: modelDiscoverySource,
                modelDiscoveryCacheKey: modelDiscoveryCacheKey
            )
        }
    }

    private static func statusDetail(providerName: String, installed: Bool, hasModels: Bool, authenticated: Bool?, advisory: String?, updateState: String?, enabled: Bool) -> String? {
        guard enabled else { return "\(providerName) provider instance is disabled." }
        guard installed else { return "\(providerName) CLI binary is unavailable." }
        guard hasModels else { return "\(providerName) CLI models are unavailable." }
        if authenticated == false { return "\(providerName) CLI is not authenticated." }
        if updateState == "update_available" { return advisory ?? "\(providerName) CLI update is available." }
        if let advisory, !advisory.isEmpty { return advisory }
        return nil
    }

    private static func uniqueSlashCommands(defaults: [String], probed: [String]) -> [String] {
        var seen = Set<String>()
        return (defaults + probed)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("/") && $0.count > 1 && seen.insert($0).inserted }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

public struct AgentThread: Codable, Sendable, Equatable, Identifiable {
    public let id: AgentThreadID
    public var projectId: ProjectID?
    public var workspaceId: WorkspaceID?
    public var title: String
    public var provider: AgentProvider
    public var providerInstanceId: String?
    public var model: String
    public var permissionMode: AgentPermissionMode
    public var reasoningEffort: AgentReasoningEffort
    public var providerThreadId: String?
    public var status: AgentRunStatus
    public var createdAt: Date
    public var updatedAt: Date
    public var diffAdditions: Int
    public var diffDeletions: Int
    public var hasUnread: Bool
    public var color: String?
    public var pinned: Bool
    public var sortOrder: Int
    public var executionMode: AgentExecutionMode
    public var baseBranch: String?
    public var worktreePath: String?
    public var serviceTier: AgentServiceTier
    public var modelSelection: AgentModelSelection
    /// Nil is an intentional legacy representation. Its effective value is
    /// always Manual with the legacy provider/model/reasoning/tier precedence.
    public var routingConfiguration: AgentRoutingConfiguration?
    /// Optional only for backward-compatible decoding of pre-v34 wire snapshots.
    public var interactionMode: AgentInteractionMode?
    /// macOS account that executes provider processes for this thread (`sudo -u`).
    /// Nil means the current login user. Distinct from `providerInstanceId`.
    public var runAsUser: AgentRunAsUser?

    public var effectiveInteractionMode: AgentInteractionMode {
        interactionMode ?? .default
    }

    public var effectiveRoutingConfiguration: AgentRoutingConfiguration {
        routingConfiguration ?? .legacyManual(
            selection: modelSelection,
            providerInstanceId: providerInstanceId,
            updatedAt: updatedAt
        )
    }

    public init(
        id: AgentThreadID = AgentThreadID(),
        projectId: ProjectID? = nil,
        workspaceId: WorkspaceID? = nil,
        title: String,
        provider: AgentProvider,
        providerInstanceId: String? = nil,
        model: String,
        providerThreadId: String? = nil,
        status: AgentRunStatus = .pending,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        diffAdditions: Int = 0,
        diffDeletions: Int = 0,
        hasUnread: Bool = false,
        color: String? = nil,
        pinned: Bool = false,
        sortOrder: Int = 0,
        permissionMode: AgentPermissionMode = .supervised,
        reasoningEffort: AgentReasoningEffort = .medium,
        executionMode: AgentExecutionMode = .local,
        baseBranch: String? = nil,
        worktreePath: String? = nil,
        serviceTier: AgentServiceTier = .auto,
        modelSelection: AgentModelSelection? = nil,
        interactionMode: AgentInteractionMode = .default,
        runAsUser: AgentRunAsUser? = nil,
        routingConfiguration: AgentRoutingConfiguration? = nil
    ) {
        self.id = id
        self.projectId = projectId
        self.workspaceId = workspaceId
        self.title = title
        self.provider = provider
        self.providerInstanceId = providerInstanceId ?? provider.rawValue
        self.model = model
        self.permissionMode = permissionMode
        self.reasoningEffort = reasoningEffort
        self.providerThreadId = providerThreadId
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.diffAdditions = diffAdditions
        self.diffDeletions = diffDeletions
        self.hasUnread = hasUnread
        self.color = color
        self.pinned = pinned
        self.sortOrder = sortOrder
        self.executionMode = executionMode
        self.baseBranch = baseBranch
        self.worktreePath = worktreePath
        self.serviceTier = serviceTier
        self.modelSelection = modelSelection ?? AgentModelSelection(
            provider: provider,
            modelId: model,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier
        )
        self.routingConfiguration = routingConfiguration
        self.interactionMode = interactionMode
        self.runAsUser = runAsUser
    }
}

public enum AgentThreadTitle {
    public static let defaultTitle = "New thread"
    public static let legacyDefaultTitle = "Thread"
    public static let displayLimit = 28

    public static func isPlaceholder(_ title: String) -> Bool {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty || normalized == defaultTitle || normalized == legacyDefaultTitle
    }

    public static func titleFromFirstMessage(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: " \t.-:#*"))
        return stripped.isEmpty ? defaultTitle : stripped
    }

    public static func display(_ title: String, limit: Int = displayLimit) -> String {
        guard title.count > limit else { return title }
        return String(title.prefix(max(0, limit))) + "..."
    }
}

public enum AgentTurnCheckpointStatus: String, Codable, Sendable, Equatable {
    case ready
    case missing
    case error
}

public struct AgentTurnCheckpointFile: Codable, Sendable, Equatable {
    public let path: String
    public let kind: String
    public let additions: Int
    public let deletions: Int

    public init(path: String, kind: String, additions: Int, deletions: Int) {
        self.path = path
        self.kind = kind
        self.additions = additions
        self.deletions = deletions
    }
}

public struct AgentTurnCheckpointFileSnapshot: Codable, Sendable, Equatable {
    public let path: String
    public let kind: String
    public let contentsBase64: String?

    public init(path: String, kind: String, contentsBase64: String?) {
        self.path = path
        self.kind = kind
        self.contentsBase64 = contentsBase64
    }
}

public struct AgentTurnCheckpointFileDiff: Codable, Sendable, Equatable {
    public let path: String
    public let patch: String

    public init(path: String, patch: String) {
        self.path = path
        self.patch = patch
    }
}

public struct AgentTurnCheckpointSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(threadId.value.uuidString):\(turnId)" }
    public let threadId: AgentThreadID
    public let runId: AgentRunID
    public let turnId: String
    public let checkpointTurnCount: Int
    public let checkpointRef: String
    public let status: AgentTurnCheckpointStatus
    public let files: [AgentTurnCheckpointFile]
    public let fileSnapshots: [AgentTurnCheckpointFileSnapshot]
    public let diffPatch: String?
    public let fileDiffs: [AgentTurnCheckpointFileDiff]
    public let assistantMessageId: AgentMessageID?
    public let errorMessage: String?
    public let completedAt: Date

    public init(
        threadId: AgentThreadID,
        runId: AgentRunID,
        turnId: String,
        checkpointTurnCount: Int,
        checkpointRef: String,
        status: AgentTurnCheckpointStatus,
        files: [AgentTurnCheckpointFile],
        fileSnapshots: [AgentTurnCheckpointFileSnapshot] = [],
        diffPatch: String? = nil,
        fileDiffs: [AgentTurnCheckpointFileDiff] = [],
        assistantMessageId: AgentMessageID? = nil,
        errorMessage: String? = nil,
        completedAt: Date = Date()
    ) {
        self.threadId = threadId
        self.runId = runId
        self.turnId = turnId
        self.checkpointTurnCount = checkpointTurnCount
        self.checkpointRef = checkpointRef
        self.status = status
        self.files = files
        self.fileSnapshots = fileSnapshots
        self.diffPatch = diffPatch
        self.fileDiffs = fileDiffs
        self.assistantMessageId = assistantMessageId
        self.errorMessage = errorMessage
        self.completedAt = completedAt
    }
}

public enum AgentMessageRole: String, Codable, Sendable {
    case user
    case assistant
    case system
}

public struct AgentMessage: Codable, Sendable, Equatable, Identifiable {
    public let id: AgentMessageID
    public let threadId: AgentThreadID
    public let role: AgentMessageRole
    public var content: String
    public let createdAt: Date
    public let attachments: [AgentAttachment]

    public init(
        id: AgentMessageID = AgentMessageID(),
        threadId: AgentThreadID,
        role: AgentMessageRole,
        content: String,
        createdAt: Date = Date(),
        attachments: [AgentAttachment] = []
    ) {
        self.id = id
        self.threadId = threadId
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.attachments = attachments
    }

    private enum CodingKeys: String, CodingKey {
        case id, threadId, role, content, createdAt, attachments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(AgentMessageID.self, forKey: .id)
        threadId = try container.decode(AgentThreadID.self, forKey: .threadId)
        role = try container.decode(AgentMessageRole.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        attachments = try container.decodeIfPresent([AgentAttachment].self, forKey: .attachments) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(threadId, forKey: .threadId)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(attachments, forKey: .attachments)
    }
}

public struct AgentMessageCursor: Codable, Sendable, Equatable {
    public let createdAt: Date
    public let id: AgentMessageID

    public init(createdAt: Date, id: AgentMessageID) {
        self.createdAt = createdAt
        self.id = id
    }
}

public struct AgentMessagePage: Codable, Sendable, Equatable {
    public let messages: [AgentMessage]
    public let hasMoreOlder: Bool
    public let hasMoreNewer: Bool
    public let nextBefore: AgentMessageCursor?
    public let nextAfter: AgentMessageCursor?

    public init(
        messages: [AgentMessage],
        hasMoreOlder: Bool,
        nextBefore: AgentMessageCursor?,
        hasMoreNewer: Bool = false,
        nextAfter: AgentMessageCursor? = nil
    ) {
        self.messages = messages
        self.hasMoreOlder = hasMoreOlder
        self.hasMoreNewer = hasMoreNewer
        self.nextBefore = nextBefore
        self.nextAfter = nextAfter
    }
}

public struct AgentThreadDraft: Codable, Sendable, Equatable {
    public let threadId: AgentThreadID
    public var providerInstanceId: String
    public var text: String
    public var attachments: [AgentAttachment]
    public var interactionMode: AgentInteractionMode
    public var updatedAt: Date

    public init(
        threadId: AgentThreadID,
        providerInstanceId: String,
        text: String,
        attachments: [AgentAttachment] = [],
        interactionMode: AgentInteractionMode = .default,
        updatedAt: Date = Date()
    ) {
        self.threadId = threadId
        self.providerInstanceId = providerInstanceId
        self.text = text
        self.attachments = attachments
        self.interactionMode = interactionMode
        self.updatedAt = updatedAt
    }
}

public enum AgentQueuedMessageDurableState: String, Codable, Sendable, Equatable {
    case queued
    case prepared
    case dispatched
}

public struct AgentQueuedMessage: Codable, Sendable, Equatable, Identifiable {
    public let id: AgentQueuedMessageID
    public let threadId: AgentThreadID
    public var text: String
    public var attachments: [AgentAttachment]
    public var interactionMode: AgentInteractionMode
    public var position: Int
    public let createdAt: Date
    public var updatedAt: Date
    public var routingSnapshot: AgentQueuedMessageRoutingSnapshot?
    /// Persisted dispatch state when supplied by the host repository. Optional
    /// keeps older socket payloads decodable; locally-created rows start queued.
    public var durableState: AgentQueuedMessageDurableState?

    public init(
        id: AgentQueuedMessageID = AgentQueuedMessageID(),
        threadId: AgentThreadID,
        text: String,
        attachments: [AgentAttachment] = [],
        interactionMode: AgentInteractionMode = .default,
        position: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        routingSnapshot: AgentQueuedMessageRoutingSnapshot? = nil,
        durableState: AgentQueuedMessageDurableState? = .queued
    ) {
        self.id = id
        self.threadId = threadId
        self.text = text
        self.attachments = attachments
        self.interactionMode = interactionMode
        self.position = position
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.routingSnapshot = routingSnapshot
        self.durableState = durableState
    }
}

/// Admission values captured with queued work. These are immutable so a later
/// thread-routing edit cannot change the deadline or reservation used on replay.
public struct AgentQueuedMessageRoutingSnapshot: Codable, Sendable, Equatable {
    public let configuration: AgentRoutingConfiguration
    public let deadlineAt: Date?
    public let budgetTokens: Int?
    public let budgetCostMicros: Int?
    public let reservationId: String?
    public let reservedTokens: Int?
    public let reservedCostMicros: Int?
    public let admissionReceiptId: UUID?

    public init(
        configuration: AgentRoutingConfiguration,
        deadlineAt: Date? = nil,
        budgetTokens: Int? = nil,
        budgetCostMicros: Int? = nil,
        reservationId: String? = nil,
        reservedTokens: Int? = nil,
        reservedCostMicros: Int? = nil,
        admissionReceiptId: UUID? = nil
    ) {
        self.configuration = configuration
        self.deadlineAt = deadlineAt
        self.budgetTokens = budgetTokens
        self.budgetCostMicros = budgetCostMicros
        self.reservationId = reservationId
        self.reservedTokens = reservedTokens
        self.reservedCostMicros = reservedCostMicros
        self.admissionReceiptId = admissionReceiptId
    }
}

public enum AgentMessageSendStatus: String, Codable, Sendable, Equatable {
    case started
    case queued
}

public struct AgentMessageSendResult: Codable, Sendable, Equatable {
    public let status: AgentMessageSendStatus
    public let runId: AgentRunID?
    public let queuedMessage: AgentQueuedMessage?

    public init(status: AgentMessageSendStatus, runId: AgentRunID? = nil, queuedMessage: AgentQueuedMessage? = nil) {
        self.status = status
        self.runId = runId
        self.queuedMessage = queuedMessage
    }
}

public struct AgentRun: Codable, Sendable, Equatable, Identifiable {
    public let id: AgentRunID
    public let threadId: AgentThreadID
    public let provider: AgentProvider
    public let providerInstanceId: String?
    public let model: String
    public var status: AgentRunStatus
    public var startedAt: Date
    public var finishedAt: Date?
    public var errorMessage: String?

    public init(
        id: AgentRunID = AgentRunID(),
        threadId: AgentThreadID,
        provider: AgentProvider,
        providerInstanceId: String? = nil,
        model: String,
        status: AgentRunStatus = .running,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id; self.threadId = threadId; self.provider = provider; self.providerInstanceId = providerInstanceId ?? provider.rawValue; self.model = model
        self.status = status; self.startedAt = startedAt; self.finishedAt = finishedAt
        self.errorMessage = errorMessage
    }
}

public struct ProviderSessionRuntime: Codable, Sendable, Equatable {
    public let threadId: AgentThreadID
    public var provider: AgentProvider
    public var providerInstanceId: String?
    public var adapterKey: String?
    public var binaryIdentity: String?
    public var status: AgentRunStatus
    public var resumeCursor: String?
    public var cwd: String?
    public var model: String?
    public var serviceTier: AgentServiceTier
    public var runtimeMode: AgentPermissionMode
    public var lastRunId: AgentRunID?
    public var lastEventKind: String?
    public var lastErrorMessage: String?
    public var runtimePayloadJSON: String?
    public var updatedAt: Date

    public init(
        threadId: AgentThreadID,
        provider: AgentProvider,
        providerInstanceId: String? = nil,
        adapterKey: String? = nil,
        binaryIdentity: String? = nil,
        status: AgentRunStatus,
        resumeCursor: String? = nil,
        cwd: String? = nil,
        model: String? = nil,
        serviceTier: AgentServiceTier = .auto,
        runtimeMode: AgentPermissionMode = .supervised,
        lastRunId: AgentRunID? = nil,
        lastEventKind: String? = nil,
        lastErrorMessage: String? = nil,
        runtimePayloadJSON: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.threadId = threadId
        self.provider = provider
        self.providerInstanceId = providerInstanceId
        self.adapterKey = adapterKey
        self.binaryIdentity = binaryIdentity
        self.status = status
        self.resumeCursor = resumeCursor
        self.cwd = cwd
        self.model = model
        self.serviceTier = serviceTier
        self.runtimeMode = runtimeMode
        self.lastRunId = lastRunId
        self.lastEventKind = lastEventKind
        self.lastErrorMessage = lastErrorMessage
        self.runtimePayloadJSON = runtimePayloadJSON
        self.updatedAt = updatedAt
    }
}
