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

    public init(
        configuration: AgentRoutingConfiguration,
        providerSnapshots: [AgentProviderSnapshot],
        launchConfigurations: [String: AgentOrchestrationLaunchConfiguration] = [:]
    ) {
        self.configuration = configuration
        self.providerSnapshots = providerSnapshots
        self.launchConfigurations = launchConfigurations
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
        permissionMode: AgentPermissionMode = .supervised
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
    }

    private enum CodingKeys: String, CodingKey {
        case id, runId, threadId, nodeId, attemptId, routingRevision, policyDigest
        case policyVersion, packageRevision, provider, providerInstanceId, model
        case capabilitySnapshotId, decisionReason, admittedAt, lifecycleStatus
        case lifecycleUpdatedAt, finalizedAt, finalRunStatus, deadlineAt
        case budgetTokens, budgetCostMicros, reservationId, reservedTokens
        case reservedCostMicros, permissionMode
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
            permissionMode: permissionMode
        )
    }
}

public enum AgentOrchestrationAdmissionError: Error, Sendable, Equatable, CustomStringConvertible {
    case packageUnavailable
    case killSwitchEnabled
    case invalidPolicy
    case invalidRoutingMode
    case noEligibleProvider
    case receiptPersistenceFailed(String)

    public var description: String {
        switch self {
        case .packageUnavailable:
            return "The pinned remote-code-orchestrate package is unavailable or invalid."
        case .killSwitchEnabled:
            return "Auto model routing is disabled by the orchestration kill switch."
        case .invalidPolicy:
            return "The Auto routing policy is invalid or no longer current."
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

    public let policyDigest: String
    private let repository: AgentOrchestrationRepository
    private let packageVerification: @Sendable () -> Bool
    private let killSwitch: @Sendable () -> Bool
    private let now: @Sendable () -> Date

    public init(
        repository: AgentOrchestrationRepository = AgentOrchestrationRepository(),
        packageVerification: @escaping @Sendable () -> Bool = AgentOrchestrationRuntime.verifyInstalledPackage,
        killSwitch: @escaping @Sendable () -> Bool = AgentOrchestrationRuntime.defaultKillSwitch,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.repository = repository
        self.packageVerification = packageVerification
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
        do {
            try repository.save(receipt)
        } catch let error as AgentOrchestrationAdmissionError {
            throw error
        } catch {
            throw AgentOrchestrationAdmissionError.receiptPersistenceFailed(String(describing: error))
        }
        return (resolved, receipt)
    }

    public func finalizeReceipt(runId: AgentRunID, status: AgentRunStatus) throws {
        guard let receipt = try repository.receipt(runId: runId),
              receipt.lifecycleStatus != .finalized else { return }
        try repository.update(receipt.updatingLifecycle(.finalized, finalRunStatus: status, at: now()))
    }

    public func markReceiptUnknown(runId: AgentRunID) throws {
        guard let receipt = try repository.receipt(runId: runId),
              receipt.lifecycleStatus == .accepted else { return }
        try repository.update(receipt.updatingLifecycle(.unknown, at: now()))
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

    private static func capabilitySnapshotID(_ snapshot: AgentProviderSnapshot) -> String {
        let modelIDs = snapshot.models.map(\.id).joined(separator: ",")
        return sha256Hex("\(snapshot.id)|\(snapshot.version ?? "")|\(modelIDs)|\(snapshot.modelDiscoveryCacheKey ?? "")")
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
