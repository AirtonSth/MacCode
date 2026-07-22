import CryptoKit
import Foundation
import CoreModel
import Persistence

public struct AgentOrchestrationRoute: Sendable, Equatable {
    public let provider: AgentProvider
    public let providerInstanceId: String
    public let capabilitySnapshotId: String
    public let selection: AgentModelSelection

    public init(
        provider: AgentProvider,
        providerInstanceId: String,
        capabilitySnapshotId: String,
        selection: AgentModelSelection
    ) {
        self.provider = provider
        self.providerInstanceId = providerInstanceId
        self.capabilitySnapshotId = capabilitySnapshotId
        self.selection = selection
    }
}

public struct AgentOrchestrationLaunchConfiguration: Sendable, Equatable {
    public let binary: String?
    public let environment: [String: String]

    public init(binary: String? = nil, environment: [String: String] = [:]) {
        self.binary = binary
        self.environment = environment
    }
}

/// Immutable input captured by the caller before a queued run crosses into the
/// coordinator. Admission and provider launch both consume this exact snapshot.
public struct AgentOrchestrationRoutingSnapshot: Sendable, Equatable {
    public let configuration: AgentRoutingConfiguration
    public let providerSnapshots: [AgentProviderSnapshot]
    public let launchConfigurations: [String: AgentOrchestrationLaunchConfiguration]
    public let admissionSnapshot: AgentQueuedMessageRoutingSnapshot?

    public init(
        configuration: AgentRoutingConfiguration,
        providerSnapshots: [AgentProviderSnapshot],
        launchConfigurations: [String: AgentOrchestrationLaunchConfiguration] = [:],
        admissionSnapshot: AgentQueuedMessageRoutingSnapshot? = nil
    ) {
        self.configuration = configuration
        self.providerSnapshots = providerSnapshots
        self.launchConfigurations = launchConfigurations
        self.admissionSnapshot = admissionSnapshot
    }
}

public enum AgentOrchestrationReceiptLifecycleStatus: String, Codable, Sendable, Equatable {
    case accepted
    case unknown
    case finalized
}

public enum AgentProviderCatalogProvenance {
    /// A missing provenance marker is promoted only when both the catalog and
    /// streaming capability were independently verified. Every uncertain or
    /// fallback path remains explicitly blocked from Auto admission.
    public static func resolvedSource(
        reportedSource: AgentModelDiscoverySource?,
        liveCatalogVerified: Bool,
        streamingCapabilityVerified: Bool
    ) -> AgentModelDiscoverySource {
        if reportedSource == .builtInFallback { return .builtInFallback }
        if reportedSource == .live {
            return streamingCapabilityVerified ? .live : .builtInFallback
        }
        return liveCatalogVerified && streamingCapabilityVerified ? .live : .builtInFallback
    }
}

public struct AgentOrchestrationAdmissionReceipt: Codable, Sendable, Equatable {
    public let id: UUID
    public let runId: AgentRunID?
    public let threadId: AgentThreadID
    public let nodeId: String
    public let attemptId: UUID?
    public let routingRevision: Int
    public let policyDigest: String
    public let policyVersion: String
    public let packageRevision: String
    public let provider: AgentProvider
    public let providerInstanceId: String
    public let model: String
    public let capabilitySnapshotId: String
    public let decisionReason: String
    public let admittedAt: Date
    public let lifecycleStatus: AgentOrchestrationReceiptLifecycleStatus
    public let lifecycleUpdatedAt: Date
    public let finalizedAt: Date?
    public let finalRunStatus: AgentRunStatus?
    public let deadlineAt: Date?
    public let budgetTokens: Int?
    public let budgetCostMicros: Int?
    public let reservationId: String?
    public let reservedTokens: Int?
    public let reservedCostMicros: Int?
    public let permissionMode: AgentPermissionMode
    public let actualTokens: Int?
    public let actualCostMicros: Int?
    public let latencyMilliseconds: Int64?
    public let qualityOutcome: String?

    public init(
        id: UUID = UUID(),
        runId: AgentRunID? = nil,
        threadId: AgentThreadID,
        nodeId: String = "root",
        attemptId: UUID? = nil,
        routingRevision: Int,
        policyDigest: String,
        policyVersion: String = AgentOrchestrationRuntime.policyContractVersion,
        packageRevision: String,
        provider: AgentProvider,
        providerInstanceId: String,
        model: String,
        capabilitySnapshotId: String,
        decisionReason: String,
        admittedAt: Date = Date(),
        lifecycleStatus: AgentOrchestrationReceiptLifecycleStatus = .unknown,
        lifecycleUpdatedAt: Date? = nil,
        finalizedAt: Date? = nil,
        finalRunStatus: AgentRunStatus? = nil,
        deadlineAt: Date? = nil,
        budgetTokens: Int? = nil,
        budgetCostMicros: Int? = nil,
        reservationId: String? = nil,
        reservedTokens: Int? = nil,
        reservedCostMicros: Int? = nil,
        permissionMode: AgentPermissionMode = .supervised,
        actualTokens: Int? = nil,
        actualCostMicros: Int? = nil,
        latencyMilliseconds: Int64? = nil,
        qualityOutcome: String? = nil
    ) {
        self.id = id
        self.runId = runId
        self.threadId = threadId
        self.nodeId = nodeId
        self.attemptId = attemptId
        self.routingRevision = routingRevision
        self.policyDigest = policyDigest
        self.policyVersion = policyVersion
        self.packageRevision = packageRevision
        self.provider = provider
        self.providerInstanceId = providerInstanceId
        self.model = model
        self.capabilitySnapshotId = capabilitySnapshotId
        self.decisionReason = decisionReason
        self.admittedAt = admittedAt
        self.lifecycleStatus = lifecycleStatus
        self.lifecycleUpdatedAt = lifecycleUpdatedAt ?? admittedAt
        self.finalizedAt = finalizedAt
        self.finalRunStatus = finalRunStatus
        self.deadlineAt = deadlineAt
        self.budgetTokens = budgetTokens
        self.budgetCostMicros = budgetCostMicros
        self.reservationId = reservationId
        self.reservedTokens = reservedTokens
        self.reservedCostMicros = reservedCostMicros
        self.permissionMode = permissionMode
        self.actualTokens = actualTokens
        self.actualCostMicros = actualCostMicros
        self.latencyMilliseconds = latencyMilliseconds
        self.qualityOutcome = qualityOutcome
    }

    private enum CodingKeys: String, CodingKey {
        case id, runId, threadId, nodeId, attemptId, routingRevision, policyDigest
        case policyVersion, packageRevision, provider, providerInstanceId, model
        case capabilitySnapshotId, decisionReason, admittedAt, lifecycleStatus
        case lifecycleUpdatedAt, finalizedAt, finalRunStatus, deadlineAt
        case budgetTokens, budgetCostMicros, reservationId, reservedTokens
        case reservedCostMicros, permissionMode, actualTokens, actualCostMicros
        case latencyMilliseconds, qualityOutcome
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let admittedAt = try values.decode(Date.self, forKey: .admittedAt)
        id = try values.decode(UUID.self, forKey: .id)
        runId = try values.decodeIfPresent(AgentRunID.self, forKey: .runId)
        threadId = try values.decode(AgentThreadID.self, forKey: .threadId)
        nodeId = try values.decodeIfPresent(String.self, forKey: .nodeId) ?? "unknown"
        attemptId = try values.decodeIfPresent(UUID.self, forKey: .attemptId)
        routingRevision = try values.decode(Int.self, forKey: .routingRevision)
        policyDigest = try values.decode(String.self, forKey: .policyDigest)
        policyVersion = try values.decodeIfPresent(String.self, forKey: .policyVersion) ?? "unknown"
        packageRevision = try values.decode(String.self, forKey: .packageRevision)
        provider = try values.decode(AgentProvider.self, forKey: .provider)
        providerInstanceId = try values.decode(String.self, forKey: .providerInstanceId)
        model = try values.decode(String.self, forKey: .model)
        capabilitySnapshotId = try values.decode(String.self, forKey: .capabilitySnapshotId)
        decisionReason = try values.decode(String.self, forKey: .decisionReason)
        self.admittedAt = admittedAt
        lifecycleStatus = try values.decodeIfPresent(
            AgentOrchestrationReceiptLifecycleStatus.self,
            forKey: .lifecycleStatus
        ) ?? .unknown
        lifecycleUpdatedAt = try values.decodeIfPresent(Date.self, forKey: .lifecycleUpdatedAt) ?? admittedAt
        finalizedAt = try values.decodeIfPresent(Date.self, forKey: .finalizedAt)
        finalRunStatus = try values.decodeIfPresent(AgentRunStatus.self, forKey: .finalRunStatus)
        deadlineAt = try values.decodeIfPresent(Date.self, forKey: .deadlineAt)
        budgetTokens = try values.decodeIfPresent(Int.self, forKey: .budgetTokens)
        budgetCostMicros = try values.decodeIfPresent(Int.self, forKey: .budgetCostMicros)
        reservationId = try values.decodeIfPresent(String.self, forKey: .reservationId)
        reservedTokens = try values.decodeIfPresent(Int.self, forKey: .reservedTokens)
        reservedCostMicros = try values.decodeIfPresent(Int.self, forKey: .reservedCostMicros)
        permissionMode = try values.decodeIfPresent(AgentPermissionMode.self, forKey: .permissionMode) ?? .supervised
        actualTokens = try values.decodeIfPresent(Int.self, forKey: .actualTokens)
        actualCostMicros = try values.decodeIfPresent(Int.self, forKey: .actualCostMicros)
        latencyMilliseconds = try values.decodeIfPresent(Int64.self, forKey: .latencyMilliseconds)
        qualityOutcome = try values.decodeIfPresent(String.self, forKey: .qualityOutcome)
    }

    func updatingLifecycle(
        _ status: AgentOrchestrationReceiptLifecycleStatus,
        finalRunStatus: AgentRunStatus? = nil,
        at: Date
    ) -> AgentOrchestrationAdmissionReceipt {
        AgentOrchestrationAdmissionReceipt(
            id: id,
            runId: runId,
            threadId: threadId,
            nodeId: nodeId,
            attemptId: attemptId,
            routingRevision: routingRevision,
            policyDigest: policyDigest,
            policyVersion: policyVersion,
            packageRevision: packageRevision,
            provider: provider,
            providerInstanceId: providerInstanceId,
            model: model,
            capabilitySnapshotId: capabilitySnapshotId,
            decisionReason: decisionReason,
            admittedAt: admittedAt,
            lifecycleStatus: status,
            lifecycleUpdatedAt: at,
            finalizedAt: status == .finalized ? at : finalizedAt,
            finalRunStatus: status == .finalized ? finalRunStatus : self.finalRunStatus,
            deadlineAt: deadlineAt,
            budgetTokens: budgetTokens,
            budgetCostMicros: budgetCostMicros,
            reservationId: reservationId,
            reservedTokens: reservedTokens,
            reservedCostMicros: reservedCostMicros,
            permissionMode: permissionMode,
            actualTokens: actualTokens,
            actualCostMicros: actualCostMicros,
            latencyMilliseconds: latencyMilliseconds,
            qualityOutcome: qualityOutcome
        )
    }

    func updatingUsage(_ usage: AssistantTokenUsage?, latencyMilliseconds: Int64) -> AgentOrchestrationAdmissionReceipt {
        AgentOrchestrationAdmissionReceipt(
            id: id,
            runId: runId,
            threadId: threadId,
            nodeId: nodeId,
            attemptId: attemptId,
            routingRevision: routingRevision,
            policyDigest: policyDigest,
            policyVersion: policyVersion,
            packageRevision: packageRevision,
            provider: provider,
            providerInstanceId: providerInstanceId,
            model: model,
            capabilitySnapshotId: capabilitySnapshotId,
            decisionReason: decisionReason,
            admittedAt: admittedAt,
            lifecycleStatus: lifecycleStatus,
            lifecycleUpdatedAt: lifecycleUpdatedAt,
            finalizedAt: finalizedAt,
            finalRunStatus: finalRunStatus,
            deadlineAt: deadlineAt,
            budgetTokens: budgetTokens,
            budgetCostMicros: budgetCostMicros,
            reservationId: reservationId,
            reservedTokens: reservedTokens,
            reservedCostMicros: reservedCostMicros,
            permissionMode: permissionMode,
            actualTokens: usage?.totalTokens,
            latencyMilliseconds: latencyMilliseconds
        )
    }
}

/// Content-free ledger row used for reconciliation and rollout decisions.
/// Prompt and provider output are intentionally absent.
public struct AgentOrchestrationLedgerEntry: Codable, Sendable, Equatable {
    public let runId: AgentRunID?
    public let threadIdHash: String
    public let nodeId: String
    public let attemptId: UUID?
    public let provider: AgentProvider
    public let providerInstanceId: String
    public let model: String
    public let capabilitySnapshotId: String
    public let policyDigest: String
    public let routingRevision: Int
    public let reservationId: String?
    public let admittedAt: Date
    public let finalizedAt: Date?
    public let tokenUsage: Int?
    public let costMicros: Int?
    public let latencyMilliseconds: Int64?
    public let outcome: String

    public init(receipt: AgentOrchestrationAdmissionReceipt, outcome: String, finalizedAt: Date? = nil) {
        runId = receipt.runId
        threadIdHash = SHA256.hash(data: Data(receipt.threadId.value.uuidString.utf8))
            .map { String(format: "%02x", $0) }.joined()
        nodeId = receipt.nodeId
        attemptId = receipt.attemptId
        provider = receipt.provider
        providerInstanceId = receipt.providerInstanceId
        model = receipt.model
        capabilitySnapshotId = receipt.capabilitySnapshotId
        policyDigest = receipt.policyDigest
        routingRevision = receipt.routingRevision
        reservationId = receipt.reservationId
        admittedAt = receipt.admittedAt
        self.finalizedAt = finalizedAt
        tokenUsage = receipt.actualTokens
        costMicros = receipt.actualCostMicros
        latencyMilliseconds = receipt.latencyMilliseconds
        self.outcome = outcome
    }
}

public enum AgentOrchestrationAdmissionError: Error, Sendable, Equatable, CustomStringConvertible {
    case packageUnavailable
    case rolloutDisabled
    case killSwitchEnabled
    case invalidPolicy
    case deadlineExpired
    case invalidBudget
    case quotaExceeded
    case invalidRoutingMode
    case noEligibleProvider
    case receiptPersistenceFailed(String)

    public var description: String {
        switch self {
        case .packageUnavailable:
            return "The pinned remote-code-orchestrate package is unavailable or invalid."
        case .rolloutDisabled:
            return "Auto model routing is disabled by the orchestration rollout flag."
        case .killSwitchEnabled:
            return "Auto model routing is disabled by the orchestration kill switch."
        case .invalidPolicy:
            return "The Auto routing policy is invalid or no longer current."
        case .deadlineExpired:
            return "The Auto routing deadline has already expired."
        case .invalidBudget:
            return "The Auto routing budget or reservation is invalid."
        case .quotaExceeded:
            return "The Auto routing quota is unavailable for this run."
        case .invalidRoutingMode:
            return "Orchestration admission requires an Auto routing configuration."
        case .noEligibleProvider:
            return "No eligible provider has a live model catalog and confirmed streaming capability."
        case .receiptPersistenceFailed(let message):
            return "Could not persist the orchestration admission receipt: \(message)"
        }
    }
}

/// Durable, content-free audit storage for orchestration admission decisions.
/// It deliberately reuses the app's existing audit table instead of creating a
/// second schema owner inside AgentRuntime.
public final class AgentOrchestrationRepository: @unchecked Sendable {
    private static let admissionAction = "agent.orchestration.admitted"
    private static let lifecycleAction = "agent.orchestration.lifecycle"
    private static let ledgerAction = "agent.orchestration.ledger"
    private enum Storage {
        case database(DeviceTrustRepository)
        case file(URL)
    }

    private let storage: Storage
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(db: SQLiteDB) {
        storage = .database(DeviceTrustRepository(db: db))
        encoder = JSONEncoder()
        decoder = JSONDecoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public init(auditLogURL: URL = AgentOrchestrationRepository.defaultAuditLogURL()) {
        storage = .file(auditLogURL)
        encoder = JSONEncoder()
        decoder = JSONDecoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func save(_ receipt: AgentOrchestrationAdmissionReceipt) throws {
        try persist(receipt, action: Self.admissionAction)
    }

    public func update(_ receipt: AgentOrchestrationAdmissionReceipt) throws {
        try persist(receipt, action: Self.lifecycleAction)
    }

    public func saveLedger(_ entry: AgentOrchestrationLedgerEntry) throws {
        let data = try encoder.encode(entry)
        guard let detail = String(data: data, encoding: .utf8) else {
            throw AgentOrchestrationAdmissionError.receiptPersistenceFailed("invalid UTF-8")
        }
        switch storage {
        case .database(let repository):
            try repository.audit(actor: "RemoteCode", action: Self.ledgerAction, detail: detail, at: entry.finalizedAt ?? entry.admittedAt)
        case .file(let url):
            lock.lock()
            defer { lock.unlock() }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url, options: .atomic) }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data + Data([0x0A]))
            try handle.synchronize()
        }
    }

    public func ledger(limit: Int = 50) throws -> [AgentOrchestrationLedgerEntry] {
        let details: [String]
        switch storage {
        case .database(let repository):
            details = try repository.listAuditLog(limit: max(1, limit) * 4)
                .filter { $0.action == Self.ledgerAction }
                .compactMap(\.detail)
        case .file(let url):
            lock.lock()
            defer { lock.unlock() }
            guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return [] }
            details = text.split(separator: "\n").map(String.init)
        }
        return details.compactMap { try? decoder.decode(AgentOrchestrationLedgerEntry.self, from: Data($0.utf8)) }
            .prefix(max(1, limit)).map { $0 }
    }

    private func persist(_ receipt: AgentOrchestrationAdmissionReceipt, action: String) throws {
        let data = try encoder.encode(receipt)
        guard let detail = String(data: data, encoding: .utf8) else {
            throw AgentOrchestrationAdmissionError.receiptPersistenceFailed("invalid UTF-8")
        }
        switch storage {
        case .database(let repository):
            try repository.audit(
                actor: "RemoteCode",
                action: action,
                detail: detail,
                at: receipt.lifecycleUpdatedAt
            )
        case .file(let url):
            lock.lock()
            defer { lock.unlock() }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: url.path) {
                try Data().write(to: url, options: .atomic)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data + Data([0x0A]))
            try handle.synchronize()
        }
    }

    public func receipts(limit: Int = 50) throws -> [AgentOrchestrationAdmissionReceipt] {
        let records: [AgentOrchestrationAdmissionReceipt]
        switch storage {
        case .database(let repository):
            records = try repository.listAuditLog(limit: max(1, limit) * 4)
                .filter { $0.action == Self.admissionAction || $0.action == Self.lifecycleAction }
                .compactMap { entry in
                    guard let detail = entry.detail, let data = detail.data(using: .utf8) else { return nil }
                    return try? decoder.decode(AgentOrchestrationAdmissionReceipt.self, from: data)
                }
        case .file(let url):
            lock.lock()
            defer { lock.unlock() }
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else { return [] }
            records = text.split(separator: "\n")
                .compactMap { try? decoder.decode(AgentOrchestrationAdmissionReceipt.self, from: Data($0.utf8)) }
        }
        var latestByID: [UUID: AgentOrchestrationAdmissionReceipt] = [:]
        for receipt in records {
            if let current = latestByID[receipt.id],
               current.lifecycleUpdatedAt >= receipt.lifecycleUpdatedAt {
                continue
            }
            latestByID[receipt.id] = receipt
        }
        return latestByID.values
            .sorted { $0.lifecycleUpdatedAt > $1.lifecycleUpdatedAt }
            .prefix(max(1, limit))
            .map { $0 }
    }

    public func receipt(runId: AgentRunID) throws -> AgentOrchestrationAdmissionReceipt? {
        try receipts(limit: 500).first { $0.runId == runId }
    }

    public static func defaultAuditLogURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RemoteCode/Orchestration", isDirectory: true)
            .appendingPathComponent("admission-receipts.jsonl")
    }
}

/// Native single-route admission. Provider execution remains owned by
/// AgentRunCoordinator, which dispatches the returned route through its existing
/// Claude, Codex, or Grok adapter.
public final class AgentOrchestrationRuntime: @unchecked Sendable {
    public static let packageID = AgentSkillInstaller.remoteCodeOrchestratePinnedPackage.skillID
    public static let requiredPackageRevision = AgentSkillInstaller.remoteCodeOrchestratePinnedPackage.sourceRevision
    public static let policyContractVersion = "1"
    public static let rolloutFlagKey = "agent.orchestration.rollout-enabled"
    private static let maxConcurrentReservations = 32

    public let policyDigest: String
    private let repository: AgentOrchestrationRepository
    private let packageVerification: @Sendable () -> Bool
    private let rolloutGate: @Sendable () -> Bool
    private let killSwitch: @Sendable () -> Bool
    private let now: @Sendable () -> Date
    private let reservationLock = NSLock()
    private var reservations: [String: (tokens: Int?, costMicros: Int?, deadlineAt: Date?)] = [:]

    public init(
        repository: AgentOrchestrationRepository = AgentOrchestrationRepository(),
        packageVerification: @escaping @Sendable () -> Bool = AgentOrchestrationRuntime.verifyInstalledPackage,
        rolloutGate: @escaping @Sendable () -> Bool = AgentOrchestrationRuntime.defaultRolloutEnabled,
        killSwitch: @escaping @Sendable () -> Bool = AgentOrchestrationRuntime.defaultKillSwitch,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.repository = repository
        self.packageVerification = packageVerification
        self.rolloutGate = rolloutGate
        self.killSwitch = killSwitch
        self.now = now
        policyDigest = Self.sha256Hex(
            "\(Self.packageID)|\(Self.requiredPackageRevision)|\(Self.policyContractVersion)"
        )
    }

    public func autoConfiguration(
        replacing configuration: AgentRoutingConfiguration,
        expectedRevision: Int,
        manualSelection: AgentModelSelection,
        manualProviderInstanceId: String?,
        providerSnapshots: [AgentProviderSnapshot]
    ) throws -> AgentRoutingConfiguration {
        let candidate = try configuration.replacing(
            expectedRevision: expectedRevision,
            mode: .auto,
            manualSelection: manualSelection,
            manualProviderInstanceId: manualProviderInstanceId,
            eligibleProviders: configuration.eligibleProviders.isEmpty
                ? AgentProvider.allCases
                : configuration.eligibleProviders,
            policyDigest: policyDigest,
            updatedAt: now()
        )
        _ = try route(configuration: candidate, providerSnapshots: providerSnapshots)
        return candidate
    }

    public func manualConfiguration(
        replacing configuration: AgentRoutingConfiguration,
        expectedRevision: Int
    ) throws -> AgentRoutingConfiguration {
        try configuration.replacing(
            expectedRevision: expectedRevision,
            mode: .manual,
            manualSelection: configuration.manualSelection,
            manualProviderInstanceId: configuration.manualProviderInstanceId,
            eligibleProviders: configuration.eligibleProviders,
            policyDigest: configuration.policyDigest,
            updatedAt: now()
        )
    }

    public func admit(
        runId: AgentRunID,
        threadId: AgentThreadID,
        configuration: AgentRoutingConfiguration,
        providerSnapshots: [AgentProviderSnapshot],
        interactionMode: AgentInteractionMode,
        permissionMode: AgentPermissionMode,
        attachments: [AgentAttachment],
        nodeId: String = "root",
        attemptId: UUID? = nil,
        receiptId: UUID? = nil,
        deadlineAt: Date? = nil,
        budgetTokens: Int? = nil,
        budgetCostMicros: Int? = nil,
        reservationId: String? = nil,
        reservedTokens: Int? = nil,
        reservedCostMicros: Int? = nil
    ) throws -> (route: AgentOrchestrationRoute, receipt: AgentOrchestrationAdmissionReceipt) {
        let resolved = try route(configuration: configuration, providerSnapshots: providerSnapshots)
        let snapshot = providerSnapshots.first { $0.id == resolved.providerInstanceId }
        try AgentProviderRunPreflight.validate(
            snapshot: snapshot,
            interactionMode: interactionMode,
            permissionMode: permissionMode,
            attachments: attachments
        )
        let receipt = AgentOrchestrationAdmissionReceipt(
            id: receiptId ?? UUID(),
            runId: runId,
            threadId: threadId,
            nodeId: nodeId,
            attemptId: attemptId ?? runId.value,
            routingRevision: configuration.revision,
            policyDigest: configuration.policyDigest,
            packageRevision: Self.requiredPackageRevision,
            provider: resolved.provider,
            providerInstanceId: resolved.providerInstanceId,
            model: resolved.selection.effectiveModel,
            capabilitySnapshotId: resolved.capabilitySnapshotId,
            decisionReason: "deterministic-first-live-eligible-provider",
            admittedAt: now(),
            lifecycleStatus: .accepted,
            deadlineAt: deadlineAt,
            budgetTokens: budgetTokens,
            budgetCostMicros: budgetCostMicros,
            reservationId: reservationId,
            reservedTokens: reservedTokens,
            reservedCostMicros: reservedCostMicros,
            permissionMode: permissionMode
        )
        let reservation = try reserveResources(
            receiptId: receipt.id,
            deadlineAt: deadlineAt,
            budgetTokens: budgetTokens,
            budgetCostMicros: budgetCostMicros,
            reservationId: reservationId,
            reservedTokens: reservedTokens,
            reservedCostMicros: reservedCostMicros
        )
        let admittedReceipt = AgentOrchestrationAdmissionReceipt(
            id: receipt.id,
            runId: receipt.runId,
            threadId: receipt.threadId,
            nodeId: receipt.nodeId,
            attemptId: receipt.attemptId,
            routingRevision: receipt.routingRevision,
            policyDigest: receipt.policyDigest,
            policyVersion: receipt.policyVersion,
            packageRevision: receipt.packageRevision,
            provider: receipt.provider,
            providerInstanceId: receipt.providerInstanceId,
            model: receipt.model,
            capabilitySnapshotId: receipt.capabilitySnapshotId,
            decisionReason: receipt.decisionReason,
            admittedAt: receipt.admittedAt,
            lifecycleStatus: receipt.lifecycleStatus,
            lifecycleUpdatedAt: receipt.lifecycleUpdatedAt,
            finalizedAt: receipt.finalizedAt,
            finalRunStatus: receipt.finalRunStatus,
            deadlineAt: receipt.deadlineAt,
            budgetTokens: receipt.budgetTokens,
            budgetCostMicros: receipt.budgetCostMicros,
            reservationId: reservation.id,
            reservedTokens: reservation.tokens,
            reservedCostMicros: reservation.costMicros,
            permissionMode: receipt.permissionMode
        )
        do {
            try repository.save(admittedReceipt)
        } catch let error as AgentOrchestrationAdmissionError {
            if let reservationId = reservation.id { releaseReservation(reservationId) }
            throw error
        } catch {
            if let reservationId = reservation.id { releaseReservation(reservationId) }
            throw AgentOrchestrationAdmissionError.receiptPersistenceFailed(String(describing: error))
        }
        return (resolved, admittedReceipt)
    }

    public func finalizeReceipt(runId: AgentRunID, status: AgentRunStatus, usage: AssistantTokenUsage? = nil) throws {
        guard let receipt = try repository.receipt(runId: runId),
              receipt.lifecycleStatus != .finalized else { return }
        let finalizedAt = now()
        let finalized = receipt
            .updatingLifecycle(.finalized, finalRunStatus: status, at: finalizedAt)
            .updatingUsage(usage, latencyMilliseconds: Int64(max(0, finalizedAt.timeIntervalSince(receipt.admittedAt) * 1_000)))
        try repository.update(finalized)
        try repository.saveLedger(
            AgentOrchestrationLedgerEntry(receipt: finalized, outcome: status.rawValue, finalizedAt: finalizedAt)
        )
        if let reservationId = receipt.reservationId { releaseReservation(reservationId) }
    }

    public func markReceiptUnknown(runId: AgentRunID) throws {
        guard let receipt = try repository.receipt(runId: runId),
              receipt.lifecycleStatus == .accepted else { return }
        let updatedAt = now()
        let unknown = receipt.updatingLifecycle(.unknown, at: updatedAt)
        try repository.update(unknown)
        try repository.saveLedger(
            AgentOrchestrationLedgerEntry(receipt: unknown, outcome: "unknown", finalizedAt: updatedAt)
        )
        if let reservationId = receipt.reservationId { releaseReservation(reservationId) }
    }

    public func reconcileReceipts(
        statusForRun: (AgentRunID) throws -> AgentRunStatus?
    ) throws {
        for receipt in try repository.receipts(limit: 500) where receipt.lifecycleStatus == .accepted {
            guard let runId = receipt.runId else { continue }
            switch try statusForRun(runId) {
            case .completed?: try finalizeReceipt(runId: runId, status: .completed)
            case .failed?: try finalizeReceipt(runId: runId, status: .failed)
            case .cancelled?: try finalizeReceipt(runId: runId, status: .cancelled)
            default: try markReceiptUnknown(runId: runId)
            }
        }
    }

    public func route(
        configuration: AgentRoutingConfiguration,
        providerSnapshots: [AgentProviderSnapshot]
    ) throws -> AgentOrchestrationRoute {
        guard rolloutGate() else { throw AgentOrchestrationAdmissionError.rolloutDisabled }
        guard !killSwitch() else { throw AgentOrchestrationAdmissionError.killSwitchEnabled }
        guard packageVerification() else { throw AgentOrchestrationAdmissionError.packageUnavailable }
        guard configuration.mode == .auto else { throw AgentOrchestrationAdmissionError.invalidRoutingMode }
        guard configuration.schemaVersion == AgentRoutingConfiguration.currentSchemaVersion,
              configuration.revision > 0,
              configuration.policyDigest == policyDigest,
              Self.isSHA256(configuration.policyDigest),
              !configuration.eligibleProviders.isEmpty else {
            throw AgentOrchestrationAdmissionError.invalidPolicy
        }

        for provider in configuration.eligibleProviders {
            guard let snapshot = providerSnapshots.first(where: {
                $0.provider == provider &&
                AgentProviderRunnableSelection.isRunnable($0) &&
                $0.modelDiscoverySource == .live &&
                $0.capabilities?.supportsStreaming == true &&
                !$0.models.isEmpty
            }), let model = snapshot.models.first(where: {
                $0.provider == provider && !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) else { continue }

            let manual = configuration.manualSelection
            let selectedModel = snapshot.models.first(where: {
                $0.provider == provider && $0.id == manual.effectiveModel
            }) ?? model
            let effort: AgentReasoningEffort
            if selectedModel.supportedReasoningEfforts.contains(manual.reasoningEffort) {
                effort = manual.reasoningEffort
            } else if selectedModel.supportedReasoningEfforts.contains(.high) {
                effort = .high
            } else {
                effort = selectedModel.supportedReasoningEfforts.first ?? .medium
            }
            let tier = selectedModel.supportsServiceTier ? manual.serviceTier : .auto
            return AgentOrchestrationRoute(
                provider: provider,
                providerInstanceId: snapshot.id,
                capabilitySnapshotId: Self.capabilitySnapshotID(snapshot),
                selection: AgentModelSelection(
                    provider: provider,
                    modelId: selectedModel.id,
                    reasoningEffort: effort,
                    serviceTier: tier
                )
            )
        }
        throw AgentOrchestrationAdmissionError.noEligibleProvider
    }

    public static func defaultPackageURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RemoteCode/AgentSkills", isDirectory: true)
            .appendingPathComponent(packageID, isDirectory: true)
    }

    public static func verifyInstalledPackage() -> Bool {
        verifyInstalledPackage(at: defaultPackageURL())
    }

    public static func verifyInstalledPackage(at packageURL: URL) -> Bool {
        let pinned = AgentSkillInstaller.remoteCodeOrchestratePinnedPackage
        let canonicalPackageURL = packageURL.standardizedFileURL
        let manifestURL = canonicalPackageURL.appendingPathComponent(
            AgentSkillInstaller.remoteCodeOrchestrateManifestName
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard isRegularFileWithoutSymlink(manifestURL),
              isDirectoryWithoutSymlink(canonicalPackageURL),
              let data = try? Data(contentsOf: manifestURL),
              let manifest = try? decoder.decode(RemoteCodeOrchestrateManifest.self, from: data),
              manifest.schemaVersion == 1,
              manifest.managedBy == "RemoteCode",
              manifest.skillID == pinned.skillID,
              manifest.sourceURL == pinned.sourceURL,
              manifest.sourceRevision == pinned.sourceRevision,
              manifest.sourceTreeSHA256 == pinned.sourceTreeSHA256,
              manifest.localVersion == pinned.localVersion,
              URL(fileURLWithPath: manifest.installPath, isDirectory: true).standardizedFileURL == canonicalPackageURL,
              manifest.files.map(\.relativePath).sorted() == pinned.allowedPaths,
              Set(manifest.files.map(\.relativePath)).count == manifest.files.count,
              AgentSkillInstaller.remoteCodeOrchestrateTreeDigest(manifest.files) == manifest.sourceTreeSHA256 else {
            return false
        }

        let root = canonicalPackageURL.path + "/"
        for file in manifest.files {
            guard isSafeRelativePath(file.relativePath),
                  file.byteCount >= 0,
                  isSHA256(file.sha256) else { return false }
            let fileURL = canonicalPackageURL.appendingPathComponent(file.relativePath).standardizedFileURL
            guard fileURL.path.hasPrefix(root),
                  isRegularFileWithoutSymlink(fileURL),
                  let fileData = try? Data(contentsOf: fileURL),
                  fileData.count == file.byteCount,
                  sha256Hex(fileData) == file.sha256.lowercased() else { return false }
        }
        return containsOnlyInstallerOwnedEntries(
            packageURL: canonicalPackageURL,
            filePaths: Set(manifest.files.map(\.relativePath))
        )
    }

    public static func defaultKillSwitch() -> Bool {
        UserDefaults.standard.bool(forKey: "agent.orchestration.kill-switch")
    }

    public static func defaultRolloutEnabled() -> Bool {
        guard let value = UserDefaults.standard.object(forKey: rolloutFlagKey) as? Bool else { return false }
        return value
    }

    private func reserveResources(
        receiptId: UUID,
        deadlineAt: Date?,
        budgetTokens: Int?,
        budgetCostMicros: Int?,
        reservationId requestedReservationId: String?,
        reservedTokens: Int?,
        reservedCostMicros: Int?
    ) throws -> (id: String?, tokens: Int?, costMicros: Int?) {
        let current = now()
        if let deadlineAt, deadlineAt <= current { throw AgentOrchestrationAdmissionError.deadlineExpired }
        guard budgetTokens == nil || budgetTokens! > 0,
              budgetCostMicros == nil || budgetCostMicros! > 0,
              reservedTokens == nil || reservedTokens! > 0,
              reservedCostMicros == nil || reservedCostMicros! > 0,
              reservedTokens == nil || budgetTokens == nil || reservedTokens! <= budgetTokens!,
              reservedCostMicros == nil || budgetCostMicros == nil || reservedCostMicros! <= budgetCostMicros! else {
            throw AgentOrchestrationAdmissionError.invalidBudget
        }
        guard budgetTokens != nil || budgetCostMicros != nil || requestedReservationId == nil else {
            throw AgentOrchestrationAdmissionError.invalidBudget
        }
        guard budgetTokens != nil || budgetCostMicros != nil else {
            return (requestedReservationId, reservedTokens, reservedCostMicros)
        }
        let id = requestedReservationId ?? "orchestration-\(receiptId.uuidString)"
        reservationLock.lock()
        defer { reservationLock.unlock() }
        if let existing = reservations[id] {
            guard existing.tokens == reservedTokens, existing.costMicros == reservedCostMicros, existing.deadlineAt == deadlineAt else {
                throw AgentOrchestrationAdmissionError.quotaExceeded
            }
            return (id, existing.tokens, existing.costMicros)
        }
        guard reservations.count < Self.maxConcurrentReservations else {
            throw AgentOrchestrationAdmissionError.quotaExceeded
        }
        let tokens = reservedTokens ?? budgetTokens
        let costMicros = reservedCostMicros ?? budgetCostMicros
        reservations[id] = (tokens, costMicros, deadlineAt)
        return (id, tokens, costMicros)
    }

    private func releaseReservation(_ id: String) {
        reservationLock.lock()
        reservations.removeValue(forKey: id)
        reservationLock.unlock()
    }

    private static func capabilitySnapshotID(_ snapshot: AgentProviderSnapshot) -> String {
        let modelIDs = snapshot.models.map(\.id).joined(separator: ",")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let capabilityFingerprint = (try? encoder.encode(snapshot.effectiveCapabilities))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "unavailable"
        let discoverySource = snapshot.modelDiscoverySource?.rawValue ?? "unknown"
        return sha256Hex(
            "\(snapshot.id)|\(snapshot.driverKind.rawValue)|\(snapshot.version ?? "")|\(modelIDs)|\(snapshot.modelDiscoveryCacheKey ?? "")|\(discoverySource)|\(capabilityFingerprint)"
        )
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit }
    }

    private static func isSafeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("/"), !value.hasSuffix("/") else { return false }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func isDirectoryWithoutSymlink(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func isRegularFileWithoutSymlink(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static func containsOnlyInstallerOwnedEntries(
        packageURL: URL,
        filePaths: Set<String>
    ) -> Bool {
        let optionalRuntimeManifest = AgentSkillInstaller.remoteCodeOrchestrateRuntimeManifestName
        let allowedFiles = filePaths.union([
            AgentSkillInstaller.remoteCodeOrchestrateManifestName,
            optionalRuntimeManifest
        ])
        let allowedDirectories = Set(filePaths.flatMap { path in
            let components = path.split(separator: "/").dropLast()
            return components.indices.map { index in
                components.prefix(index + 1).joined(separator: "/")
            }
        })
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: packageURL,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in false }
        ) else { return false }
        let root = packageURL.path + "/"
        for case let item as URL in enumerator {
            let standardized = item.standardizedFileURL
            guard standardized.path.hasPrefix(root) else { return false }
            let relativePath = String(standardized.path.dropFirst(root.count))
            guard let values = try? item.resourceValues(forKeys: Set(keys)),
                  values.isSymbolicLink != true else { return false }
            if values.isDirectory == true {
                guard allowedDirectories.contains(relativePath) else { return false }
            } else {
                guard values.isRegularFile == true, allowedFiles.contains(relativePath) else { return false }
            }
        }
        return true
    }

    private static func sha256Hex(_ value: String) -> String {
        sha256Hex(Data(value.utf8))
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
