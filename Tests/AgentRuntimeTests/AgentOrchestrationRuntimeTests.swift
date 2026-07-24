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

    func testDefaultRolloutEnablesAutoWithoutPreferenceButHonorsExplicitOptOut() {
        let defaults = UserDefaults.standard
        let previousValue = defaults.object(forKey: AgentOrchestrationRuntime.rolloutFlagKey)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: AgentOrchestrationRuntime.rolloutFlagKey)
            } else {
                defaults.removeObject(forKey: AgentOrchestrationRuntime.rolloutFlagKey)
            }
        }

        defaults.removeObject(forKey: AgentOrchestrationRuntime.rolloutFlagKey)
        XCTAssertTrue(
            AgentOrchestrationRuntime.defaultRolloutEnabled(),
            "A missing rollout preference must not leave the top Auto toggle inert."
        )

        defaults.set(false, forKey: AgentOrchestrationRuntime.rolloutFlagKey)
        XCTAssertFalse(
            AgentOrchestrationRuntime.defaultRolloutEnabled(),
            "An explicit rollout opt-out must remain authoritative."
        )
    }

    func testVerifierUsesCanonicalInstallerPackageAndFailsClosedOnTampering() throws {
        XCTAssertEqual(
            Array(AgentOrchestrationRuntime.defaultPackageURL().pathComponents.suffix(3)),
            ["RemoteCode", "AgentSkills", AgentOrchestrationRuntime.packageID]
        )

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-orchestration-package-\(UUID().uuidString)", isDirectory: true)
        defer {
            // Best-effort only: the package may already be gone if a prior step
            // deleted the temp tree; never fail the test on cleanup.
            if FileManager.default.fileExists(atPath: root.path) {
                try? FileManager.default.removeItem(at: root)
            }
        }
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

    func testOrderedEligibleProvidersPutsPreferredSourceFirst() {
        XCTAssertEqual(
            AgentOrchestrationRuntime.orderedEligibleProviders(
                eligible: AgentProvider.allCases,
                preferred: .claude
            ),
            [.claude, .codex, .grok],
            "Auto must try the Source picker host before allCases order (codex-first)."
        )
        XCTAssertEqual(
            AgentOrchestrationRuntime.orderedEligibleProviders(
                eligible: [.codex, .grok],
                preferred: .claude
            ),
            [.codex, .grok],
            "A preferred host not in eligibleProviders must not be injected."
        )
        XCTAssertEqual(
            AgentOrchestrationRuntime.orderedEligibleProviders(
                eligible: [.grok, .claude, .codex],
                preferred: .grok
            ),
            [.grok, .claude, .codex]
        )
    }

    func testRoutePrefersManualSourceProviderOverAllCasesOrder() throws {
        let runtime = AgentOrchestrationRuntime(
            packageVerification: { true },
            killSwitch: { false }
        )
        // allCases is codex → claude → grok. Manual Source is Claude; Auto must
        // not silently admit Codex just because it appears first in allCases.
        var config = configuration(runtime: runtime)
        config.eligibleProviders = AgentProvider.allCases
        config.manualSelection = AgentModelSelection(
            provider: .claude,
            modelId: "claude-live",
            reasoningEffort: .high,
            serviceTier: .auto
        )
        config.manualProviderInstanceId = "claude-cli"

        let route = try runtime.route(configuration: config, providerSnapshots: snapshots())
        XCTAssertEqual(route.provider, .claude)
        XCTAssertEqual(route.providerInstanceId, "claude-cli")
    }

    func testRoutePrefersRunnableClaudeEvenWithBuiltInCatalog() throws {
        let runtime = AgentOrchestrationRuntime(
            packageVerification: { true },
            killSwitch: { false }
        )
        var config = configuration(runtime: runtime)
        config.eligibleProviders = AgentProvider.allCases
        config.manualSelection = AgentModelSelection(
            provider: .claude,
            modelId: "opus",
            reasoningEffort: .high,
            serviceTier: .auto
        )
        config.manualProviderInstanceId = "claude-cli"
        // Claude Code OAuth: Anthropic REST discovery is fallback, but CLI is
        // installed + authenticated. Preferred Source must still admit Claude
        // (not silent Codex).
        let mixed = AgentProvider.allCases.map { provider -> AgentProviderSnapshot in
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
                modelDiscoverySource: provider == .claude ? .builtInFallback : .live
            )
        }
        let route = try runtime.route(configuration: config, providerSnapshots: mixed)
        XCTAssertEqual(route.provider, .claude,
                       "Preferred Claude Source must admit even when catalog provenance is built-in fallback.")
        XCTAssertEqual(route.providerInstanceId, "claude-cli")
    }

    func testRouteFailsClosedWhenPreferredSourceIsNotRunnable() throws {
        let runtime = AgentOrchestrationRuntime(
            packageVerification: { true },
            killSwitch: { false }
        )
        var config = configuration(runtime: runtime)
        config.eligibleProviders = AgentProvider.allCases
        config.manualSelection = AgentModelSelection(
            provider: .claude,
            modelId: "claude-live",
            reasoningEffort: .high,
            serviceTier: .auto
        )
        // Claude selected in UI but not runnable — must NOT silently start Codex.
        let mixed = AgentProvider.allCases.map { provider -> AgentProviderSnapshot in
            AgentProviderSnapshotFactory.snapshot(
                provider: provider,
                models: [AgentModelDescriptor(
                    id: "\(provider.rawValue)-live",
                    label: "Live",
                    provider: provider,
                    supportsReasoning: true,
                    supportsServiceTier: true
                )],
                binaryPath: provider == .claude ? "" : "/usr/bin/true",
                authenticated: provider == .claude ? false : true,
                capabilitiesOverride: AgentProviderCapabilities(supportsStreaming: true),
                modelDiscoverySource: .live
            )
        }
        XCTAssertThrowsError(try runtime.route(configuration: config, providerSnapshots: mixed)) {
            guard case .preferredSourceUnavailable(let provider, let detail)? =
                $0 as? AgentOrchestrationAdmissionError else {
                return XCTFail("expected preferredSourceUnavailable, got \($0)")
            }
            XCTAssertEqual(provider, .claude,
                           "Auto must fail closed on the Source picker host instead of silent Codex fallback.")
            XCTAssertEqual(
                detail,
                "Claude CLI binary is unavailable.",
                "Fail-closed error must name the concrete install failure, not a generic blob only."
            )
            XCTAssertTrue(
                ($0 as? AgentOrchestrationAdmissionError)?.description.contains("Claude CLI binary is unavailable") == true
            )
        }
    }

    /// WHY: Airton's Mac showed a generic Auto/install/auth/models banner while
    /// the Claude row already knew it was unauthenticated — recovery (Sign in)
    /// was not discoverable from the Auto error string.
    func testPreferredSourceUnavailabilityDetailSurfacesAuthAndMissingBinary() {
        let unauth = AgentProviderSnapshotFactory.snapshot(
            provider: .claude,
            models: [AgentModelDescriptor(id: "opus", label: "Opus", provider: .claude)],
            binaryPath: "/usr/bin/true",
            authenticated: false,
            id: "claude-cli"
        )
        XCTAssertEqual(
            AgentOrchestrationRuntime.preferredSourceUnavailabilityDetail(
                provider: .claude,
                preferredInstanceId: "claude-cli",
                providerSnapshots: [unauth]
            ),
            "Claude CLI is not authenticated."
        )
        let missing = AgentProviderSnapshotFactory.snapshot(
            provider: .claude,
            models: [AgentModelDescriptor(id: "opus", label: "Opus", provider: .claude)],
            binaryPath: "",
            authenticated: true,
            id: "claude-cli"
        )
        XCTAssertEqual(
            AgentOrchestrationRuntime.preferredSourceUnavailabilityDetail(
                provider: .claude,
                preferredInstanceId: "claude-cli",
                providerSnapshots: [missing]
            ),
            "Claude CLI binary is unavailable."
        )
    }

    /// WHY: Airton's machine has Claude at /Users/airtonjunior/.local/bin/claude
    /// but the Agent user capsule was set to airtonempat — Auto must name both.
    func testPreferredSourceUnavailabilityDetailNamesRunAsUserHomeMismatch() {
        let claude = AgentProviderSnapshotFactory.snapshot(
            provider: .claude,
            models: [AgentModelDescriptor(id: "opus", label: "Opus", provider: .claude)],
            binaryPath: "/Users/airtonjunior/.local/bin/claude",
            authenticated: false,
            id: "claude-cli"
        )
        let foreign = AgentRunAsUser(
            generatedUID: "g-empat",
            shortName: "airtonempat",
            uid: 1601,
            gid: 20,
            homePath: "/Users/airtonempat",
            fullName: "Airton Empath"
        )
        XCTAssertNotEqual(foreign.uid, getuid())
        let detail = AgentOrchestrationRuntime.preferredSourceUnavailabilityDetail(
            provider: .claude,
            preferredInstanceId: "claude-cli",
            providerSnapshots: [claude],
            runAsUser: foreign
        )
        XCTAssertEqual(
            detail,
            "Claude CLI is not authenticated — CLI is under airtonjunior but run-as-user is airtonempat — switch the user capsule to airtonjunior or install/sign in as airtonempat"
        )
        XCTAssertEqual(
            AgentOrchestrationRuntime.homeOwnerFromPath("/Users/airtonjunior/.local/bin/claude"),
            "airtonjunior"
        )
    }

    func test_autoOrchestrateProviderPromptInjectsHostReceipt() {
        let route = AgentOrchestrationRoute(
            provider: .claude,
            providerInstanceId: "claude-cli",
            capabilitySnapshotId: "cap",
            selection: AgentModelSelection(
                provider: .claude,
                modelId: "haiku",
                reasoningEffort: .high,
                serviceTier: .auto
            )
        )
        let wrapped = AgentOrchestrationRuntime.autoOrchestrateProviderPrompt(
            userPrompt: "Quem é você?",
            admittedRoute: route
        )
        XCTAssertTrue(wrapped.contains("active_host: claude-code"))
        XCTAssertTrue(wrapped.contains("provider: claude"))
        XCTAssertTrue(wrapped.contains("controller_model: haiku"))
        XCTAssertTrue(wrapped.contains("Quem é você?"))
        XCTAssertFalse(wrapped.contains("active_host: codex"),
                       "Host receipt must match the admitted route, not allCases default.")
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
        // Auto controller always binds LIGHT (Haiku), not the manual selection.
        XCTAssertEqual(admission.route.selection.modelId, "haiku")
        XCTAssertEqual(admission.route.selection.reasoningEffort, .high)
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

    func testFinalizationMarksTokenBudgetOverrunInLedger() throws {
        let (db, root) = try database()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repository = AgentOrchestrationRepository(db: db)
        let runtime = AgentOrchestrationRuntime(
            repository: repository,
            packageVerification: { true },
            rolloutGate: { true },
            killSwitch: { false }
        )
        let admission = try runtime.admit(
            runId: AgentRunID(),
            threadId: AgentThreadID(),
            configuration: configuration(runtime: runtime),
            providerSnapshots: snapshots(),
            interactionMode: .default,
            permissionMode: .supervised,
            attachments: [],
            budgetTokens: 10,
            reservedTokens: 8
        )
        try runtime.finalizeReceipt(
            runId: try XCTUnwrap(admission.receipt.runId),
            status: .completed,
            usage: AssistantTokenUsage(totalTokens: 11),
            qualityOutcome: "verified:output-present"
        )
        XCTAssertEqual(try repository.ledger().first?.outcome, "completed:budget-overrun")
    }

    func testReconciliationCarriesRecoveredUsageAndQualityIntoReceipt() throws {
        let (db, root) = try database()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repository = AgentOrchestrationRepository(db: db)
        let runtime = AgentOrchestrationRuntime(
            repository: repository,
            packageVerification: { true },
            rolloutGate: { true },
            killSwitch: { false }
        )
        let admission = try runtime.admit(
            runId: AgentRunID(),
            threadId: AgentThreadID(),
            configuration: configuration(runtime: runtime),
            providerSnapshots: snapshots(),
            interactionMode: .default,
            permissionMode: .supervised,
            attachments: []
        )
        let runId = try XCTUnwrap(admission.receipt.runId)
        let usage = AssistantTokenUsage(totalTokens: 17)
        try runtime.reconcileReceipts(
            statusForRun: { _ in .completed },
            usageForRun: { _ in usage },
            qualityOutcomeForRun: { _, _ in "verified:output-present" }
        )
        let receipt = try XCTUnwrap(repository.receipt(runId: runId))
        XCTAssertEqual(receipt.actualTokens, 17)
        XCTAssertEqual(receipt.qualityOutcome, "verified:output-present")
        XCTAssertEqual(try repository.ledger().first?.tokenUsage, 17)
    }

    func testCostBudgetFailsClosedWithoutVerifiedEstimator() throws {
        let runtime = AgentOrchestrationRuntime(
            packageVerification: { true },
            rolloutGate: { true },
            killSwitch: { false }
        )
        XCTAssertThrowsError(
            try runtime.admit(
                runId: AgentRunID(),
                threadId: AgentThreadID(),
                configuration: configuration(runtime: runtime),
                providerSnapshots: snapshots(),
                interactionMode: .default,
                permissionMode: .supervised,
                attachments: [],
                budgetCostMicros: 10
            )
        ) { XCTAssertEqual($0 as? AgentOrchestrationAdmissionError, .costBudgetUnavailable) }
    }

    func testCostEstimatorLiquidatesAndMarksCostBudgetOverrun() throws {
        let (db, root) = try database()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repository = AgentOrchestrationRepository(db: db)
        let runtime = AgentOrchestrationRuntime(
            repository: repository,
            packageVerification: { true },
            rolloutGate: { true },
            killSwitch: { false },
            costEstimator: { _, _ in 12 }
        )
        let admission = try runtime.admit(
            runId: AgentRunID(),
            threadId: AgentThreadID(),
            configuration: configuration(runtime: runtime),
            providerSnapshots: snapshots(),
            interactionMode: .default,
            permissionMode: .supervised,
            attachments: [],
            budgetCostMicros: 10,
            reservedCostMicros: 10
        )
        try runtime.finalizeReceipt(
            runId: try XCTUnwrap(admission.receipt.runId),
            status: .completed,
            usage: AssistantTokenUsage(totalTokens: 1),
            qualityOutcome: "verified:output-present"
        )
        XCTAssertEqual(try repository.receipt(runId: admission.receipt.runId!)?.actualCostMicros, 12)
        XCTAssertEqual(try repository.ledger().first?.outcome, "completed:budget-overrun")
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
        // Preferred Source may admit with a built-in catalog (Claude Code OAuth).
        let preferredFallback = try runtime.route(
            configuration: configuration(runtime: runtime),
            providerSnapshots: snapshots(source: .builtInFallback)
        )
        XCTAssertEqual(preferredFallback.provider, .claude)

        // Preferred host listed but unrunnable → fail closed (no silent Codex).
        var unrunnablePreferred = configuration(runtime: runtime)
        unrunnablePreferred.manualSelection = AgentModelSelection(
            provider: .claude,
            modelId: "claude-live",
            reasoningEffort: .high,
            serviceTier: .auto
        )
        let onlyFallbackNonPreferred = AgentProvider.allCases.map { provider -> AgentProviderSnapshot in
            AgentProviderSnapshotFactory.snapshot(
                provider: provider,
                models: provider == .claude ? [] : [
                    AgentModelDescriptor(
                        id: "\(provider.rawValue)-live",
                        label: "Live",
                        provider: provider,
                        supportsReasoning: true,
                        supportsServiceTier: true
                    )
                ],
                binaryPath: provider == .claude ? "" : "/usr/bin/true",
                authenticated: provider == .claude ? false : true,
                capabilitiesOverride: AgentProviderCapabilities(supportsStreaming: true),
                modelDiscoverySource: .builtInFallback
            )
        }
        XCTAssertThrowsError(try runtime.route(
            configuration: unrunnablePreferred,
            providerSnapshots: onlyFallbackNonPreferred
        )) {
            guard case .preferredSourceUnavailable(let provider, _)? =
                $0 as? AgentOrchestrationAdmissionError else {
                return XCTFail("expected preferredSourceUnavailable, got \($0)")
            }
            XCTAssertEqual(provider, .claude)
        }
    }

    func test_autoDeepControllerSelectionUsesHostMatrixDeepRow() {
        let claude = AgentOrchestrationRuntime.deepControllerSelection(
            provider: .claude,
            availableModels: [
                AgentModelDescriptor(id: "haiku", label: "Haiku", provider: .claude, supportsReasoning: true),
                AgentModelDescriptor(id: "opus", label: "Opus", provider: .claude, supportsReasoning: true,
                                     supportedReasoningEfforts: [.low, .medium, .high, .xhigh])
            ]
        )
        XCTAssertEqual(claude.modelId, "opus")
        XCTAssertEqual(claude.reasoningEffort, .high)

        let codex = AgentOrchestrationRuntime.deepControllerSelection(
            provider: .codex,
            availableModels: [
                AgentModelDescriptor(id: "gpt-5.6-luna", label: "Luna", provider: .codex, supportsReasoning: true),
                AgentModelDescriptor(id: "gpt-5.6-sol", label: "Sol", provider: .codex, supportsReasoning: true,
                                     supportedReasoningEfforts: [.medium, .high, .xhigh])
            ]
        )
        XCTAssertEqual(codex.modelId, "gpt-5.6-sol")
        XCTAssertEqual(codex.reasoningEffort, .high)

        let grok = AgentOrchestrationRuntime.deepControllerSelection(
            provider: .grok,
            availableModels: [
                AgentModelDescriptor(id: "grok-4.5", label: "Grok", provider: .grok, supportsReasoning: true,
                                     supportedReasoningEfforts: [.medium, .high])
            ]
        )
        XCTAssertEqual(grok.modelId, "grok-4.5")
        XCTAssertEqual(grok.reasoningEffort, .high)
    }

    func testRouteDeepFallbackStaysOnPreferredSource() throws {
        let runtime = AgentOrchestrationRuntime(
            packageVerification: { true },
            killSwitch: { false }
        )
        var config = configuration(runtime: runtime)
        config.eligibleProviders = AgentProvider.allCases
        config.manualSelection = AgentModelSelection(
            provider: .claude,
            modelId: "opus",
            reasoningEffort: .high,
            serviceTier: .auto
        )
        config.manualProviderInstanceId = "claude-cli"
        let route = try runtime.routeDeepFallback(
            configuration: config,
            providerSnapshots: snapshots()
        )
        XCTAssertEqual(route.provider, .claude)
        XCTAssertEqual(route.providerInstanceId, "claude-cli")
        // DEEP binding prefers opus alias when present in catalog; test snapshots
        // only ship "claude-live" so matrix falls back to forced preferred id.
        XCTAssertFalse(route.selection.modelId.isEmpty)
        XCTAssertEqual(route.selection.provider, .claude)
    }

    func test_autoLightControllerSelectionUsesHostMatrixNotManualSelection() {
        let claude = AgentOrchestrationRuntime.lightControllerSelection(
            provider: .claude,
            availableModels: [
                AgentModelDescriptor(id: "claude-live", label: "Live", provider: .claude, supportsReasoning: true),
                AgentModelDescriptor(id: "haiku", label: "Haiku", provider: .claude, supportsReasoning: true,
                                     supportedReasoningEfforts: [.low, .medium, .high])
            ]
        )
        XCTAssertEqual(claude.modelId, "haiku")
        XCTAssertEqual(claude.reasoningEffort, .high)

        let codex = AgentOrchestrationRuntime.lightControllerSelection(
            provider: .codex,
            availableModels: [
                AgentModelDescriptor(id: "gpt-5.6-sol", label: "Sol", provider: .codex, supportsReasoning: true)
            ]
        )
        XCTAssertEqual(codex.modelId, "gpt-5.6-luna",
                       "LIGHT matrix id is forced even when the live catalog only lists DEEP models")
        XCTAssertEqual(codex.reasoningEffort, .medium)

        let grok = AgentOrchestrationRuntime.lightControllerSelection(
            provider: .grok,
            availableModels: [
                AgentModelDescriptor(id: "grok-4.5", label: "Grok 4.5", provider: .grok, supportsReasoning: true,
                                     supportedReasoningEfforts: [.medium, .high])
            ]
        )
        XCTAssertEqual(grok.modelId, "grok-4.5")
        XCTAssertEqual(grok.reasoningEffort, .medium)
    }

    func test_autoOrchestrateProviderPromptAlwaysInvokesSkill() {
        let wrapped = AgentOrchestrationRuntime.autoOrchestrateProviderPrompt(userPrompt: "fix the bug")
        XCTAssertTrue(wrapped.hasPrefix("$remote-code-orchestrate"))
        XCTAssertTrue(wrapped.contains("fix the bug"))
        XCTAssertTrue(wrapped.contains("EVERY worker/reviewer prompt"))
        XCTAssertTrue(wrapped.contains("| distill"))
        XCTAssertTrue(AgentOrchestrationRuntime.promptAlreadyInvokesOrchestrateSkill(wrapped))

        let already = "$remote-code-orchestrate\n\ndo the thing"
        XCTAssertEqual(
            AgentOrchestrationRuntime.autoOrchestrateProviderPrompt(userPrompt: already),
            already,
            "wrapping must be idempotent"
        )
        XCTAssertTrue(
            AgentOrchestrationRuntime.promptAlreadyInvokesOrchestrateSkill("$remote-code-orchestrate please")
        )
        XCTAssertFalse(
            AgentOrchestrationRuntime.promptAlreadyInvokesOrchestrateSkill("$sam-orchestrate please"),
            "legacy sam-orchestrate is not the Auto skill name"
        )
    }
}
