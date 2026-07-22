import XCTest
import CoreModel
@testable import Persistence
@testable import AgentRuntime

final class AgentOrchestrationRuntimeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(true, forKey: AgentOrchestrationRuntime.rolloutFlagKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AgentOrchestrationRuntime.rolloutFlagKey)
        super.tearDown()
    }

    func testVerifierUsesCanonicalInstallerPackageAndFailsClosedOnTampering() throws {
        XCTAssertEqual(
            Array(AgentOrchestrationRuntime.defaultPackageURL().pathComponents.suffix(3)),
            ["RemoteCode", "AgentSkills", AgentOrchestrationRuntime.packageID]
        )

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-orchestration-package-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let skillsRoot = root.appendingPathComponent("AgentSkills", isDirectory: true)
        let installer = AgentSkillInstaller(appPrivateSkillsRoot: skillsRoot)
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AgentRuntime/Resources/remote-code-orchestrate", isDirectory: true)
        _ = try installer.installRemoteCodeOrchestrate(from: source)
        let packageURL = installer.remoteCodeOrchestrateDirectory()
        let ownershipManifestURL = packageURL.appendingPathComponent(
            AgentSkillInstaller.remoteCodeOrchestrateManifestName
        )

        XCTAssertTrue(AgentOrchestrationRuntime.verifyInstalledPackage(at: packageURL))

        let ownershipManifest = try Data(contentsOf: ownershipManifestURL)
        try FileManager.default.removeItem(at: ownershipManifestURL)
        XCTAssertFalse(
            AgentOrchestrationRuntime.verifyInstalledPackage(at: packageURL),
            "the secondary runtime manifest must not substitute for the installer-owned manifest"
        )
        try ownershipManifest.write(to: ownershipManifestURL, options: .atomic)

        try Data("tampered\n".utf8).write(to: packageURL.appendingPathComponent("SKILL.md"))
        XCTAssertFalse(AgentOrchestrationRuntime.verifyInstalledPackage(at: packageURL))
    }

    private func database() throws -> (SQLiteDB, String) {
        let root = NSTemporaryDirectory() + "rc-orchestration-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: root).run()
        return (db, root)
    }

    private func snapshots(source: AgentModelDiscoverySource = .live) -> [AgentProviderSnapshot] {
        AgentProvider.allCases.map { provider in
            AgentProviderSnapshotFactory.snapshot(
                provider: provider,
                models: [AgentModelDescriptor(
                    id: "\(provider.rawValue)-live",
                    label: "Live",
                    provider: provider,
                    supportsReasoning: true,
                    supportsServiceTier: true
                )],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                capabilitiesOverride: AgentProviderCapabilities(supportsStreaming: true),
                modelDiscoverySource: source
            )
        }
    }

    private func configuration(runtime: AgentOrchestrationRuntime) -> AgentRoutingConfiguration {
        AgentRoutingConfiguration(
            mode: .auto,
            manualSelection: AgentModelSelection(provider: .claude, modelId: "claude-live", reasoningEffort: .high, serviceTier: .fast),
            manualProviderInstanceId: "claude",
            eligibleProviders: [.claude, .codex, .grok],
            policyDigest: runtime.policyDigest,
            revision: 3
        )
    }

    func testAdmissionSelectsLiveEligibleProviderAndPersistsAuditableReceipt() throws {
        let (db, root) = try database()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repository = AgentOrchestrationRepository(db: db)
        let admittedAt = Date(timeIntervalSince1970: 42)
        let runtime = AgentOrchestrationRuntime(
            repository: repository,
            packageVerification: { true },
            killSwitch: { false },
            now: { admittedAt }
        )

        let runId = AgentRunID()
        let admission = try runtime.admit(
            runId: runId,
            threadId: AgentThreadID(),
            configuration: configuration(runtime: runtime),
            providerSnapshots: snapshots(),
            interactionMode: .default,
            permissionMode: .supervised,
            attachments: []
        )

        XCTAssertEqual(admission.route.provider, .claude)
        XCTAssertEqual(admission.route.selection.modelId, "claude-live")
        XCTAssertEqual(admission.receipt.routingRevision, 3)
        XCTAssertEqual(admission.receipt.runId, runId)
        XCTAssertEqual(admission.receipt.nodeId, "root")
        XCTAssertEqual(admission.receipt.attemptId, runId.value)
        XCTAssertEqual(admission.receipt.lifecycleStatus, .accepted)
        XCTAssertNil(admission.receipt.deadlineAt)
        XCTAssertNil(admission.receipt.budgetTokens)
        XCTAssertNil(admission.receipt.reservationId)
        XCTAssertEqual(admission.receipt.permissionMode, .supervised)
        XCTAssertEqual(admission.receipt.policyVersion, AgentOrchestrationRuntime.policyContractVersion)
        XCTAssertEqual(admission.receipt.policyDigest, runtime.policyDigest)
        XCTAssertEqual(admission.receipt.admittedAt, admittedAt)
        XCTAssertEqual(try repository.receipts().map(\.id), [admission.receipt.id])

        try runtime.finalizeReceipt(runId: runId, status: .completed)
        let finalized = try XCTUnwrap(repository.receipt(runId: runId))
        XCTAssertEqual(finalized.id, admission.receipt.id)
        XCTAssertEqual(finalized.lifecycleStatus, .finalized)
        XCTAssertEqual(finalized.finalRunStatus, .completed)
        XCTAssertEqual(try repository.receipts().count, 1,
                       "Lifecycle updates must reconcile to one logical receipt per run.")
    }

    func testCatalogProvenanceRequiresVerifiedLiveCatalogAndStreamingCapability() {
        XCTAssertEqual(
            AgentProviderCatalogProvenance.resolvedSource(
                reportedSource: nil,
                liveCatalogVerified: true,
                streamingCapabilityVerified: true
            ),
            .live
        )
        XCTAssertEqual(
            AgentProviderCatalogProvenance.resolvedSource(
                reportedSource: nil,
                liveCatalogVerified: false,
                streamingCapabilityVerified: true
            ),
            .builtInFallback
        )
        XCTAssertEqual(
            AgentProviderCatalogProvenance.resolvedSource(
                reportedSource: .builtInFallback,
                liveCatalogVerified: true,
                streamingCapabilityVerified: true
            ),
            .builtInFallback
        )
        XCTAssertEqual(
            AgentProviderCatalogProvenance.resolvedSource(
                reportedSource: .live,
                liveCatalogVerified: true,
                streamingCapabilityVerified: false
            ),
            .builtInFallback
        )
    }

    func testCapabilitySnapshotIDChangesWhenCapabilitiesChange() throws {
        let runtime = AgentOrchestrationRuntime(packageVerification: { true }, killSwitch: { false })
        let live = try runtime.route(
            configuration: configuration(runtime: runtime),
            providerSnapshots: snapshots(source: .live)
        )
        let selectedIndex = try XCTUnwrap(snapshots(source: .live).firstIndex { $0.provider == live.provider })
        var changedCatalog = snapshots(source: .live)
        changedCatalog[selectedIndex] = AgentProviderSnapshotFactory.snapshot(
            provider: live.provider,
            models: [AgentModelDescriptor(id: "\(live.provider.rawValue)-live", label: "Live", provider: live.provider)],
            binaryPath: "/usr/bin/true",
            authenticated: true,
            capabilitiesOverride: AgentProviderCapabilities(
                supportsAttachments: true,
                supportedAttachmentKinds: [.file],
                supportsStreaming: true
            ),
            modelDiscoverySource: .live
        )
        let changed = try runtime.route(
            configuration: configuration(runtime: runtime),
            providerSnapshots: changedCatalog
        )
        XCTAssertNotEqual(
            live.capabilitySnapshotId,
            changed.capabilitySnapshotId,
            "receipt provenance must change when provider capabilities change"
        )

        let noStreaming = AgentProviderSnapshotFactory.snapshot(
            provider: live.provider,
            models: [AgentModelDescriptor(id: "\(live.provider.rawValue)-live", label: "Live", provider: live.provider)],
            binaryPath: "/usr/bin/true",
            authenticated: true,
            capabilitiesOverride: AgentProviderCapabilities(supportsStreaming: false),
            modelDiscoverySource: .live
        )
        var nonStreamingCatalog = snapshots(source: .live)
        nonStreamingCatalog[selectedIndex] = noStreaming
        var onlySelectedProvider = configuration(runtime: runtime)
        onlySelectedProvider.eligibleProviders = [live.provider]
        XCTAssertThrowsError(
            try runtime.route(configuration: onlySelectedProvider, providerSnapshots: nonStreamingCatalog),
            "a non-streaming live catalog must remain ineligible for Auto"
        )
    }

    func testAdmissionFailsClosedBeforeReceiptWhenPackageOrKillSwitchIsInvalid() throws {
        let (db, root) = try database()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repository = AgentOrchestrationRepository(db: db)
        let missingPackage = AgentOrchestrationRuntime(
            repository: repository,
            packageVerification: { false },
            killSwitch: { false }
        )
        XCTAssertThrowsError(try missingPackage.route(
            configuration: configuration(runtime: missingPackage),
            providerSnapshots: snapshots()
        )) { XCTAssertEqual($0 as? AgentOrchestrationAdmissionError, .packageUnavailable) }

        let killed = AgentOrchestrationRuntime(
            repository: repository,
            packageVerification: { true },
            killSwitch: { true }
        )
        XCTAssertThrowsError(try killed.route(
            configuration: configuration(runtime: killed),
            providerSnapshots: snapshots()
        )) { XCTAssertEqual($0 as? AgentOrchestrationAdmissionError, .killSwitchEnabled) }
        XCTAssertTrue(try repository.receipts().isEmpty)
    }

    func testAdmissionHonorsRolloutFlagAndResourceConstraints() throws {
        let (db, root) = try database()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repository = AgentOrchestrationRepository(db: db)
        let disabled = AgentOrchestrationRuntime(
            repository: repository,
            packageVerification: { true },
            rolloutGate: { false },
            killSwitch: { false }
        )
        XCTAssertThrowsError(try disabled.route(configuration: configuration(runtime: disabled), providerSnapshots: snapshots())) {
            XCTAssertEqual($0 as? AgentOrchestrationAdmissionError, .rolloutDisabled)
        }

        let now = Date(timeIntervalSince1970: 100)
        let runtime = AgentOrchestrationRuntime(
            repository: repository,
            packageVerification: { true },
            rolloutGate: { true },
            killSwitch: { false },
            now: { now }
        )
        XCTAssertThrowsError(try runtime.admit(
            runId: AgentRunID(), threadId: AgentThreadID(), configuration: configuration(runtime: runtime),
            providerSnapshots: snapshots(), interactionMode: .default, permissionMode: .supervised,
            attachments: [], deadlineAt: now.addingTimeInterval(-1)
        )) { XCTAssertEqual($0 as? AgentOrchestrationAdmissionError, .deadlineExpired) }

        let admission = try runtime.admit(
            runId: AgentRunID(), threadId: AgentThreadID(), configuration: configuration(runtime: runtime),
            providerSnapshots: snapshots(), interactionMode: .default, permissionMode: .supervised,
            attachments: [], deadlineAt: now.addingTimeInterval(60), budgetTokens: 100,
            reservedTokens: 50
        )
        XCTAssertEqual(admission.receipt.reservedTokens, 50)
        XCTAssertNotNil(admission.receipt.reservationId)
        try runtime.finalizeReceipt(runId: try XCTUnwrap(admission.receipt.runId), status: .completed)
        let ledger = try repository.ledger()
        XCTAssertEqual(ledger.count, 1)
        XCTAssertEqual(ledger[0].tokenUsage, nil)
        XCTAssertEqual(ledger[0].outcome, AgentRunStatus.completed.rawValue)
    }

    func testUnknownReconciliationReleasesReservationAndWritesHashedUsageFreeLedger() throws {
        let (db, root) = try database()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repository = AgentOrchestrationRepository(db: db)
        let runtime = AgentOrchestrationRuntime(
            repository: repository,
            packageVerification: { true },
            rolloutGate: { true },
            killSwitch: { false },
            now: { Date(timeIntervalSince1970: 200) }
        )
        let threadId = AgentThreadID()
        let first = try runtime.admit(
            runId: AgentRunID(), threadId: threadId, configuration: configuration(runtime: runtime),
            providerSnapshots: snapshots(), interactionMode: .default, permissionMode: .supervised,
            attachments: [], budgetTokens: 100, reservationId: "reconcile-once", reservedTokens: 90
        )
        try runtime.markReceiptUnknown(runId: try XCTUnwrap(first.receipt.runId))
        let unknown = try XCTUnwrap(repository.ledger().first)
        XCTAssertEqual(unknown.outcome, "unknown")
        XCTAssertEqual(unknown.threadIdHash.count, 64)
        XCTAssertFalse(unknown.threadIdHash.contains(threadId.value.uuidString))

        let second = try runtime.admit(
            runId: AgentRunID(), threadId: threadId, configuration: configuration(runtime: runtime),
            providerSnapshots: snapshots(), interactionMode: .default, permissionMode: .supervised,
            attachments: [], budgetTokens: 100, reservationId: "reconcile-once", reservedTokens: 90
        )
        let usage = AssistantTokenUsage(inputTokens: 40, outputTokens: 3, totalTokens: 43)
        try runtime.finalizeReceipt(
            runId: try XCTUnwrap(second.receipt.runId),
            status: .completed,
            usage: usage,
            qualityOutcome: "verified:rubric-pass"
        )
        let finalized = try XCTUnwrap(repository.receipt(runId: second.receipt.runId!))
        XCTAssertEqual(finalized.actualTokens, 43)
        XCTAssertNotNil(finalized.latencyMilliseconds)
        XCTAssertEqual(finalized.qualityOutcome, "verified:rubric-pass")
        XCTAssertEqual(try repository.ledger().first?.tokenUsage, 43)
    }

    func testAdmissionRejectsStalePolicyAndFallbackCatalogs() throws {
        let runtime = AgentOrchestrationRuntime(
            packageVerification: { true },
            killSwitch: { false }
        )
        var stale = configuration(runtime: runtime)
        stale.policyDigest = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try runtime.route(configuration: stale, providerSnapshots: snapshots())) {
            XCTAssertEqual($0 as? AgentOrchestrationAdmissionError, .invalidPolicy)
        }
        XCTAssertThrowsError(try runtime.route(
            configuration: configuration(runtime: runtime),
            providerSnapshots: snapshots(source: .builtInFallback)
        )) { XCTAssertEqual($0 as? AgentOrchestrationAdmissionError, .noEligibleProvider) }
    }
}
