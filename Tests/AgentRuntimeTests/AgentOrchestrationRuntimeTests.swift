import XCTest
import CoreModel
@testable import Persistence
@testable import AgentRuntime

private final class OrchestrationTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(_ interval: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(interval)
        lock.unlock()
    }
}

private func testDelegationCapability(for runID: AgentRunID) -> String {
    AgentDelegationCapability.sha256Hex("test-capability:\(runID.value.uuidString)")
}

private extension AgentOrchestrationRuntime {
    func recordExternalRoot(
        runId: AgentRunID,
        threadId: AgentThreadID,
        provider: AgentProvider,
        providerInstanceId: String,
        model: String,
        permissionMode: AgentPermissionMode,
        ownerProcessID: Int32? = nil
    ) throws -> AgentOrchestrationAdmissionReceipt {
        try recordExternalRoot(
            runId: runId,
            threadId: threadId,
            provider: provider,
            providerInstanceId: providerInstanceId,
            model: model,
            permissionMode: permissionMode,
            delegationCapabilitySHA256: AgentDelegationCapability.sha256Hex(
                testDelegationCapability(for: runId)
            ),
            ownerProcessID: ownerProcessID
        )
    }

    func recordExternalChild(
        runId: AgentRunID,
        threadId: AgentThreadID,
        provider: AgentProvider,
        providerInstanceId: String,
        model: String,
        nodeId: String,
        parentRunId: AgentRunID,
        parentThreadId: AgentThreadID? = nil,
        requestedPermissionMode: AgentPermissionMode? = nil,
        ownerProcessID: Int32? = nil
    ) throws -> AgentOrchestrationAdmissionReceipt {
        try recordAuthorizedExternalChild(
            runId: runId,
            threadId: threadId,
            provider: provider,
            providerInstanceId: providerInstanceId,
            model: model,
            nodeId: nodeId,
            parentRunId: parentRunId,
            parentThreadId: parentThreadId ?? threadId,
            parentCapability: testDelegationCapability(for: parentRunId),
            childCapability: testDelegationCapability(for: runId),
            requestedPermissionMode: requestedPermissionMode,
            ownerProcessID: ownerProcessID
        )
    }
}

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
        let skillURL = packageURL.appendingPathComponent("SKILL.md")

        XCTAssertTrue(AgentOrchestrationRuntime.verifyInstalledPackage(at: packageURL))

        let originalSkill = try Data(contentsOf: skillURL)
        XCTAssertFalse(originalSkill.isEmpty)
        let originalModificationDate = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: skillURL.path)[.modificationDate] as? Date
        )
        var sameSizeTamper = originalSkill
        sameSizeTamper[0] ^= 0x01
        try sameSizeTamper.write(to: skillURL)
        try FileManager.default.setAttributes(
            [.modificationDate: originalModificationDate],
            ofItemAtPath: skillURL.path
        )
        XCTAssertFalse(
            AgentOrchestrationRuntime.verifyInstalledPackage(at: packageURL),
            "package verification must hash content even when size and modification time are unchanged"
        )
        try originalSkill.write(to: skillURL, options: .atomic)
        XCTAssertTrue(AgentOrchestrationRuntime.verifyInstalledPackage(at: packageURL))

        let ownershipManifest = try Data(contentsOf: ownershipManifestURL)
        try FileManager.default.removeItem(at: ownershipManifestURL)
        XCTAssertFalse(
            AgentOrchestrationRuntime.verifyInstalledPackage(at: packageURL),
            "the secondary runtime manifest must not substitute for the installer-owned manifest"
        )
        try ownershipManifest.write(to: ownershipManifestURL, options: .atomic)

        try Data("tampered\n".utf8).write(to: skillURL)
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

    func testReceiptLockHeldByStuckPeerFailsOpenAfterAboutTwoSeconds() throws {
        // WHY (S-F7): the orchestration lock is shared with the Distill
        // sidecars and wrapped the SQLite transaction with an unbounded
        // F_SETLKW, so a stuck sidecar could hang admission forever. Database
        // storage fails open after 2 s because BEGIN IMMEDIATE still serializes
        // writers, so the receipt must persist exactly once anyway.
        let (db, root) = try database()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let databaseURL = URL(fileURLWithPath: db.path).standardizedFileURL
        let lockPath = databaseURL.deletingLastPathComponent()
            .appendingPathComponent(".\(databaseURL.lastPathComponent).orchestration.lock").path
        let repository = AgentOrchestrationRepository(db: db)
        let runtime = AgentOrchestrationRuntime(
            repository: repository,
            packageVerification: { true },
            killSwitch: { false },
            now: { Date(timeIntervalSince1970: 42) }
        )
        let holder = try CrossProcessFileLockHolder(path: lockPath)
        defer { holder.release() }

        let readStart = Date()
        XCTAssertTrue(try repository.receipts().isEmpty)
        let readTime = Date().timeIntervalSince(readStart)
        XCTAssertGreaterThanOrEqual(readTime, 1.9)
        XCTAssertLessThan(readTime, 3.0, "one call must not wait for the 30 s holder")

        let runId = AgentRunID()
        let admitStart = Date()
        let admission = try runtime.admit(
            runId: runId,
            threadId: AgentThreadID(),
            configuration: configuration(runtime: runtime),
            providerSnapshots: snapshots(),
            interactionMode: .default,
            permissionMode: .supervised,
            attachments: []
        )
        let admitTime = Date().timeIntervalSince(admitStart)
        print("orchestration admit under held lock: \(admitTime)s")
        XCTAssertLessThan(admitTime, 6,
                          "admission must finish well before the holder lets go")
        holder.release()
        XCTAssertEqual(try repository.receipts().map(\.id), [admission.receipt.id])
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
        // Auto controller binds the LIGHT reasoning-capable model, not either
        // the manual selection or Haiku (which has no effort control).
        XCTAssertEqual(admission.route.selection.modelId, "sonnet")
        XCTAssertEqual(admission.route.selection.reasoningEffort, .high)
        XCTAssertEqual(
            admission.receipt.reasoningEffort,
            .high,
            "Subagents reads effort from the admission receipt, not re-routing"
        )
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

    func testChildAdmissionPersistsDistinctProviderNeutralWorkerLifecycle() throws {
        // WHY: the Subagents surface must represent the actual controlled child,
        // not duplicate the root route as if it were a worker.
        let (db, root) = try database()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repository = AgentOrchestrationRepository(db: db)
        let runtime = AgentOrchestrationRuntime(
            repository: repository,
            packageVerification: { true },
            killSwitch: { false }
        )
        let parent = try runtime.admit(
            runId: AgentRunID(),
            threadId: AgentThreadID(),
            configuration: configuration(runtime: runtime),
            providerSnapshots: snapshots(),
            interactionMode: .default,
            permissionMode: .supervised,
            attachments: []
        ).receipt
        let childRun = AgentRunID()
        let child = try runtime.admitChild(
            parentReceipt: parent,
            runId: childRun,
            nodeId: "deep-worker-plan-writer"
        )

        XCTAssertEqual(child.parentReceiptId, parent.id)
        XCTAssertEqual(child.threadId, parent.threadId)
        XCTAssertEqual(child.provider, parent.provider)
        XCTAssertEqual(child.model, parent.model)
        XCTAssertEqual(
            child.reasoningEffort,
            parent.reasoningEffort,
            "controlled children inherit the parent's bound effort for Subagents meta"
        )
        XCTAssertEqual(child.nodeId, "deep-worker-plan-writer")
        XCTAssertEqual(child.lifecycleStatus, .accepted)
        XCTAssertEqual(Set(try repository.receipts().map(\.id)), Set([parent.id, child.id]))

        try runtime.finalizeReceipt(runId: childRun, status: .completed)
        let finalized = try XCTUnwrap(repository.receipt(runId: childRun))
        XCTAssertEqual(finalized.lifecycleStatus, .finalized)
        XCTAssertEqual(finalized.finalRunStatus, .completed)
        XCTAssertEqual(finalized.parentReceiptId, parent.id)
    }

    func testExternalChildBridgeRoundTripsIntoRecentReceipts() throws {
        // WHY: skill-launched Codex/Claude/Grok workers use the external bridge;
        // the Subagents surface must read the same durable receipt after the
        // worker process exits, without requiring the controller process.
        let (db, root) = try database()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repository = AgentOrchestrationRepository(db: db)
        let runtime = AgentOrchestrationRuntime(
            repository: repository,
            packageVerification: { true },
            killSwitch: { false }
        )
        let runId = AgentRunID()
        let threadId = AgentThreadID()
        let receipt = try runtime.recordExternalRoot(
            runId: runId,
            threadId: threadId,
            provider: .grok,
            providerInstanceId: "fixture-grok",
            model: "fixture-model",
            permissionMode: .supervised
        )

        XCTAssertNil(receipt.parentReceiptId)
        XCTAssertEqual(receipt.provider, .grok)
        XCTAssertEqual(receipt.threadId, threadId)
        XCTAssertEqual(receipt.lifecycleStatus, .accepted)
        XCTAssertEqual(try runtime.recentReceipts().map(\.id), [receipt.id])

        try runtime.finalizeReceipt(runId: runId, status: .completed)
        let finalized = try XCTUnwrap(runtime.recentReceipts().first)
        XCTAssertEqual(finalized.id, receipt.id)
        XCTAssertEqual(finalized.lifecycleStatus, .finalized)
        XCTAssertEqual(finalized.finalRunStatus, .completed)
    }

    func testDelegationCapabilityBindsEveryGenerationAndRejectsSwapReplayAndLegacyParents() throws {
        // WHY: run/thread UUIDs are identifiers, not authority. Every nested
        // provider hop must prove possession of its exact live parent bearer,
        // persist only the digest, and receive an unrelated fresh bearer.
        let (db, root) = try database()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repository = AgentOrchestrationRepository(db: db)
        let current = Date(timeIntervalSince1970: 60_000)
        let runtime = AgentOrchestrationRuntime(
            repository: repository,
            packageVerification: { true },
            killSwitch: { false },
            now: { current },
            processIsAlive: { _ in true }
        )
        let threadID = AgentThreadID()
        let parentRunA = AgentRunID()
        let parentRunB = AgentRunID()
        let parentCapabilityA = AgentDelegationCapability.issue()
        let parentCapabilityB = AgentDelegationCapability.issue()
        let childCapability = AgentDelegationCapability.issue()
        XCTAssertNotEqual(parentCapabilityA, parentCapabilityB)
        XCTAssertNotEqual(parentCapabilityA, childCapability)
        XCTAssertTrue(AgentDelegationCapabilityTransport.isWellFormed(parentCapabilityA))

        let parentA = try runtime.recordExternalRoot(
            runId: parentRunA,
            threadId: threadID,
            provider: .codex,
            providerInstanceId: "codex-cli",
            model: "gpt",
            permissionMode: .fullAccess,
            delegationCapabilitySHA256: AgentDelegationCapability.sha256Hex(
                parentCapabilityA
            )
        )
        _ = try runtime.recordExternalRoot(
            runId: parentRunB,
            threadId: threadID,
            provider: .grok,
            providerInstanceId: "grok-cli",
            model: "grok",
            permissionMode: .fullAccess,
            delegationCapabilitySHA256: AgentDelegationCapability.sha256Hex(
                parentCapabilityB
            )
        )

        let encodedParent = String(
            decoding: try JSONEncoder().encode(parentA),
            as: UTF8.self
        )
        XCTAssertFalse(encodedParent.contains(parentCapabilityA))
        XCTAssertTrue(encodedParent.contains(
            AgentDelegationCapability.sha256Hex(parentCapabilityA)
        ))

        let childRunID = AgentRunID()
        let child = try runtime.recordAuthorizedExternalChild(
            runId: childRunID,
            threadId: threadID,
            provider: .claude,
            providerInstanceId: "claude-cli",
            model: "claude",
            nodeId: "nested.claude.authorized",
            parentRunId: parentRunA,
            parentThreadId: threadID,
            parentCapability: parentCapabilityA,
            childCapability: childCapability,
            requestedPermissionMode: .supervised
        )
        XCTAssertEqual(child.parentReceiptId, parentA.id)
        XCTAssertEqual(
            child.delegationCapabilitySHA256,
            AgentDelegationCapability.sha256Hex(childCapability)
        )
        XCTAssertNotEqual(
            child.delegationCapabilitySHA256,
            parentA.delegationCapabilitySHA256
        )
        XCTAssertNotNil(try runtime.activeReceipt(
            runId: childRunID,
            threadId: threadID,
            delegationCapability: childCapability
        ))
        XCTAssertNil(try runtime.activeReceipt(
            runId: childRunID,
            threadId: threadID,
            delegationCapability: parentCapabilityA
        ))

        XCTAssertThrowsError(try runtime.recordAuthorizedExternalChild(
            runId: AgentRunID(),
            threadId: threadID,
            provider: .grok,
            providerInstanceId: "grok-cli",
            model: "grok",
            nodeId: "nested.grok.wrong-capability",
            parentRunId: parentRunA,
            parentThreadId: threadID,
            parentCapability: parentCapabilityB,
            childCapability: AgentDelegationCapability.issue()
        )) {
            XCTAssertEqual(
                $0 as? AgentOrchestrationAdmissionError,
                .invalidChildAdmission("parent delegation capability is invalid")
            )
        }
        XCTAssertThrowsError(try runtime.recordAuthorizedExternalChild(
            runId: AgentRunID(),
            threadId: threadID,
            provider: .claude,
            providerInstanceId: "claude-cli",
            model: "claude",
            nodeId: "nested.claude.swapped-parent",
            parentRunId: parentRunB,
            parentThreadId: threadID,
            parentCapability: parentCapabilityA,
            childCapability: AgentDelegationCapability.issue()
        )) {
            XCTAssertEqual(
                $0 as? AgentOrchestrationAdmissionError,
                .invalidChildAdmission("parent delegation capability is invalid")
            )
        }

        let legacyRunID = AgentRunID()
        let legacy = AgentOrchestrationAdmissionReceipt(
            runId: legacyRunID,
            threadId: threadID,
            routingRevision: 0,
            policyDigest: "external",
            packageRevision: "external",
            provider: .codex,
            providerInstanceId: "legacy",
            model: "legacy",
            capabilitySnapshotId: "external",
            decisionReason: "manual-agent-app-controller",
            admittedAt: current,
            lifecycleStatus: .accepted,
            deadlineAt: current.addingTimeInterval(60),
            permissionMode: .fullAccess,
            delegationCapabilitySHA256: nil,
            ownerProcessID: ProcessInfo.processInfo.processIdentifier
        )
        try repository.save(legacy)
        XCTAssertThrowsError(try runtime.recordAuthorizedExternalChild(
            runId: AgentRunID(),
            threadId: threadID,
            provider: .grok,
            providerInstanceId: "grok-cli",
            model: "grok",
            nodeId: "nested.grok.legacy-parent",
            parentRunId: legacyRunID,
            parentThreadId: threadID,
            parentCapability: AgentDelegationCapability.issue(),
            childCapability: AgentDelegationCapability.issue()
        )) {
            XCTAssertEqual(
                $0 as? AgentOrchestrationAdmissionError,
                .invalidChildAdmission("parent delegation capability is invalid")
            )
        }

        try runtime.finalizeReceipt(runId: parentRunA, status: .completed)
        XCTAssertThrowsError(try runtime.recordAuthorizedExternalChild(
            runId: AgentRunID(),
            threadId: threadID,
            provider: .grok,
            providerInstanceId: "grok-cli",
            model: "grok",
            nodeId: "nested.grok.replayed-parent",
            parentRunId: parentRunA,
            parentThreadId: threadID,
            parentCapability: parentCapabilityA,
            childCapability: AgentDelegationCapability.issue()
        )) {
            XCTAssertEqual(
                $0 as? AgentOrchestrationAdmissionError,
                .invalidChildAdmission("parent receipt is not active")
            )
        }
    }

    func testAuthenticatedExternalFinalizationRejectsRootSiblingWrongOwnerAndWrongContext() throws {
        // WHY: a run UUID is not authority. The external end bridge must prove
        // ownership of that exact telemetry child and its inherited parent
        // scope without turning the finalization bearer into delegation power.
        let (db, root) = try database()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repository = AgentOrchestrationRepository(db: db)
        let runtime = AgentOrchestrationRuntime(
            repository: repository,
            packageVerification: { true },
            killSwitch: { false },
            processIsAlive: { [111, 222, 333].contains($0) }
        )
        let threadID = AgentThreadID()
        let rootRunID = AgentRunID()
        let childRunID = AgentRunID()
        let siblingRunID = AgentRunID()
        let parentCapability = AgentDelegationCapability.issue()
        let childFinalizationCapability = AgentDelegationCapability.issue()
        let siblingFinalizationCapability = AgentDelegationCapability.issue()
        _ = try runtime.recordExternalRoot(
            runId: rootRunID,
            threadId: threadID,
            provider: .codex,
            providerInstanceId: "codex-cli",
            model: "gpt",
            permissionMode: .fullAccess,
            delegationCapabilitySHA256: AgentDelegationCapability.sha256Hex(
                parentCapability
            ),
            ownerProcessID: 111
        )
        let child = try runtime.recordAuthenticatedTelemetryChild(
            runId: childRunID,
            threadId: threadID,
            provider: .grok,
            providerInstanceId: "grok-cli",
            model: "grok",
            nodeId: "nested.grok.telemetry",
            parentRunId: rootRunID,
            parentThreadId: threadID,
            parentCapability: parentCapability,
            finalizationCapability: childFinalizationCapability,
            ownerProcessID: 222
        )
        _ = try runtime.recordAuthenticatedTelemetryChild(
            runId: siblingRunID,
            threadId: threadID,
            provider: .claude,
            providerInstanceId: "claude-cli",
            model: "claude",
            nodeId: "nested.claude.telemetry",
            parentRunId: rootRunID,
            parentThreadId: threadID,
            parentCapability: parentCapability,
            finalizationCapability: siblingFinalizationCapability,
            ownerProcessID: 222
        )

        let handle = try XCTUnwrap(AgentExternalReceiptHandle.encode(
            runId: childRunID,
            finalizationCapability: childFinalizationCapability
        ))
        let decoded = try XCTUnwrap(AgentExternalReceiptHandle.decode(handle))
        XCTAssertEqual(decoded.runId, childRunID)
        XCTAssertEqual(decoded.finalizationCapability, childFinalizationCapability)
        XCTAssertNil(child.delegationCapabilitySHA256)
        XCTAssertEqual(
            child.finalizationCapabilitySHA256,
            AgentDelegationCapability.sha256Hex(childFinalizationCapability)
        )
        XCTAssertFalse(
            String(decoding: try JSONEncoder().encode(child), as: UTF8.self)
                .contains(childFinalizationCapability)
        )

        XCTAssertThrowsError(try runtime.finalizeAuthenticatedExternalReceipt(
            runId: rootRunID,
            status: .completed,
            parentRunId: rootRunID,
            parentThreadId: threadID,
            parentCapability: parentCapability,
            finalizationCapability: childFinalizationCapability,
            ownerProcessID: 111
        ))
        XCTAssertThrowsError(try runtime.finalizeAuthenticatedExternalReceipt(
            runId: siblingRunID,
            status: .completed,
            parentRunId: rootRunID,
            parentThreadId: threadID,
            parentCapability: parentCapability,
            finalizationCapability: childFinalizationCapability,
            ownerProcessID: 222
        ))
        XCTAssertThrowsError(try runtime.finalizeAuthenticatedExternalReceipt(
            runId: childRunID,
            status: .completed,
            parentRunId: rootRunID,
            parentThreadId: threadID,
            parentCapability: parentCapability,
            finalizationCapability: childFinalizationCapability,
            ownerProcessID: 333
        ))
        XCTAssertThrowsError(try runtime.finalizeAuthenticatedExternalReceipt(
            runId: childRunID,
            status: .completed,
            parentRunId: AgentRunID(),
            parentThreadId: threadID,
            parentCapability: parentCapability,
            finalizationCapability: childFinalizationCapability,
            ownerProcessID: 222
        ))
        XCTAssertThrowsError(try runtime.finalizeAuthenticatedExternalReceipt(
            runId: childRunID,
            status: .completed,
            parentRunId: rootRunID,
            parentThreadId: threadID,
            parentCapability: AgentDelegationCapability.issue(),
            finalizationCapability: childFinalizationCapability,
            ownerProcessID: 222
        ))
        XCTAssertThrowsError(try runtime.finalizeAuthenticatedExternalReceipt(
            runId: childRunID,
            status: .running,
            parentRunId: rootRunID,
            parentThreadId: threadID,
            parentCapability: parentCapability,
            finalizationCapability: childFinalizationCapability,
            ownerProcessID: 222
        ))

        // A parent can finish before its child cleanup command. The stored
        // identity and bearer still authenticate that terminal close.
        try runtime.finalizeReceipt(runId: rootRunID, status: .completed)
        try runtime.finalizeAuthenticatedExternalReceipt(
            runId: childRunID,
            status: .completed,
            parentRunId: rootRunID,
            parentThreadId: threadID,
            parentCapability: parentCapability,
            finalizationCapability: childFinalizationCapability,
            ownerProcessID: 222
        )
        XCTAssertEqual(
            try repository.receipt(runId: childRunID)?.finalRunStatus,
            .completed
        )
        XCTAssertEqual(
            try repository.receipt(runId: siblingRunID)?.lifecycleStatus,
            .accepted
        )
    }

    func testFinalizedRootInvalidatesDescendantAdmissionRenewalAndActiveLookup() throws {
        // WHY: a live child PID cannot preserve authority inherited from a
        // finalized root. Every operation must validate the complete chain
        // without waiting for the Subagents UI reconciliation poll.
        let (db, root) = try database()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repository = AgentOrchestrationRepository(db: db)
        let runtime = AgentOrchestrationRuntime(
            repository: repository,
            packageVerification: { true },
            killSwitch: { false },
            processIsAlive: { _ in true }
        )
        let threadID = AgentThreadID()
        let rootRunID = AgentRunID()
        let childRunID = AgentRunID()
        let grandchildRunID = AgentRunID()
        _ = try runtime.recordExternalRoot(
            runId: rootRunID,
            threadId: threadID,
            provider: .codex,
            providerInstanceId: "codex-cli",
            model: "gpt",
            permissionMode: .fullAccess,
            ownerProcessID: 111
        )
        _ = try runtime.recordExternalChild(
            runId: childRunID,
            threadId: threadID,
            provider: .grok,
            providerInstanceId: "grok-cli",
            model: "grok",
            nodeId: "nested.grok.child",
            parentRunId: rootRunID,
            ownerProcessID: 222
        )
        _ = try runtime.recordExternalChild(
            runId: grandchildRunID,
            threadId: threadID,
            provider: .claude,
            providerInstanceId: "claude-cli",
            model: "claude",
            nodeId: "nested.claude.grandchild",
            parentRunId: childRunID,
            ownerProcessID: 333
        )
        try runtime.finalizeReceipt(runId: rootRunID, status: .completed)

        XCTAssertNil(try runtime.activeReceipt(
            runId: grandchildRunID,
            threadId: threadID,
            delegationCapability: testDelegationCapability(for: grandchildRunID)
        ))
        XCTAssertThrowsError(try runtime.recordExternalChild(
            runId: AgentRunID(),
            threadId: threadID,
            provider: .codex,
            providerInstanceId: "codex-cli",
            model: "gpt",
            nodeId: "nested.codex.blocked-grandchild",
            parentRunId: childRunID,
            ownerProcessID: 444
        )) {
            XCTAssertEqual(
                $0 as? AgentOrchestrationAdmissionError,
                .invalidChildAdmission("ancestor receipt is not active")
            )
        }
        XCTAssertThrowsError(try runtime.renewExternalReceiptLease(
            runId: grandchildRunID,
            ownerProcessID: 333
        )) {
            XCTAssertEqual(
                $0 as? AgentOrchestrationAdmissionError,
                .invalidChildAdmission("ancestor receipt is not active")
            )
        }
    }

    func testCyclicReceiptAncestryFailsClosedForAdmissionRenewalAndLookup() throws {
        // WHY: corrupted append-only ancestry must terminate deterministically
        // instead of looping or granting a child through a repeated ancestor.
        let (db, root) = try database()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repository = AgentOrchestrationRepository(db: db)
        let current = Date(timeIntervalSince1970: 70_000)
        let runtime = AgentOrchestrationRuntime(
            repository: repository,
            packageVerification: { true },
            killSwitch: { false },
            now: { current },
            processIsAlive: { _ in true }
        )
        let threadID = AgentThreadID()
        let firstID = UUID()
        let secondID = UUID()
        let firstRunID = AgentRunID()
        let secondRunID = AgentRunID()
        let firstCapability = AgentDelegationCapability.issue()
        let deadline = current.addingTimeInterval(60)
        try repository.save(AgentOrchestrationAdmissionReceipt(
            id: firstID,
            parentReceiptId: secondID,
            runId: firstRunID,
            threadId: threadID,
            nodeId: "nested.first",
            routingRevision: 0,
            policyDigest: "external",
            packageRevision: "external",
            provider: .codex,
            providerInstanceId: "codex-cli",
            model: "gpt",
            capabilitySnapshotId: "external",
            decisionReason: "external-controlled-child",
            admittedAt: current,
            lifecycleStatus: .accepted,
            deadlineAt: deadline,
            permissionMode: .fullAccess,
            delegationCapabilitySHA256: AgentDelegationCapability.sha256Hex(
                firstCapability
            ),
            ownerProcessID: 111
        ))
        try repository.save(AgentOrchestrationAdmissionReceipt(
            id: secondID,
            parentReceiptId: firstID,
            runId: secondRunID,
            threadId: threadID,
            nodeId: "nested.second",
            routingRevision: 0,
            policyDigest: "external",
            packageRevision: "external",
            provider: .grok,
            providerInstanceId: "grok-cli",
            model: "grok",
            capabilitySnapshotId: "external",
            decisionReason: "external-controlled-child",
            admittedAt: current,
            lifecycleStatus: .accepted,
            deadlineAt: deadline,
            permissionMode: .fullAccess,
            delegationCapabilitySHA256: AgentDelegationCapability.sha256Hex(
                AgentDelegationCapability.issue()
            ),
            ownerProcessID: 222
        ))

        XCTAssertNil(try runtime.activeReceipt(
            runId: firstRunID,
            threadId: threadID,
            delegationCapability: firstCapability
        ))
        XCTAssertThrowsError(try runtime.recordAuthorizedExternalChild(
            runId: AgentRunID(),
            threadId: threadID,
            provider: .claude,
            providerInstanceId: "claude-cli",
            model: "claude",
            nodeId: "nested.claude.cycle",
            parentRunId: firstRunID,
            parentThreadId: threadID,
            parentCapability: firstCapability,
            childCapability: AgentDelegationCapability.issue(),
            ownerProcessID: 333
        )) {
            XCTAssertEqual(
                $0 as? AgentOrchestrationAdmissionError,
                .invalidChildAdmission("receipt ancestry is cyclic")
            )
        }
        XCTAssertThrowsError(try runtime.renewExternalReceiptLease(
            runId: firstRunID,
            ownerProcessID: 111
        )) {
            XCTAssertEqual(
                $0 as? AgentOrchestrationAdmissionError,
                .invalidChildAdmission("receipt ancestry is cyclic")
            )
        }
    }

    func testBadgePollServesUnchangedReceiptsFromSignatureCache_becauseIdleTicksMustNotDecode() throws {
        // WHY (perf X-01): the 2s Subagents badge poll used to decode ~770
        // audit_log receipts per tick even when nothing changed, on the same
        // serial SQLite queue that persists stream events. With the
        // append-signature cache, an idle poll must decode nothing, a receipt
        // write must refresh the next poll, and receipt(runId:) repeats must
        // not re-scan the audit log.
        let (db, root) = try database()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repository = AgentOrchestrationRepository(db: db)
        let now = Date(timeIntervalSince1970: 70_000)
        let runtime = AgentOrchestrationRuntime(
            repository: repository,
            packageVerification: { true },
            killSwitch: { false },
            now: { now }
        )
        let threadID = AgentThreadID()
        let firstRunID = AgentRunID()

        try repository.save(AgentOrchestrationAdmissionReceipt(
            runId: firstRunID,
            threadId: threadID,
            routingRevision: 0,
            policyDigest: "external",
            packageRevision: "external",
            provider: .codex,
            providerInstanceId: "codex-cli",
            model: "gpt",
            capabilitySnapshotId: "external",
            decisionReason: "manual-agent-app-controller",
            admittedAt: now,
            lifecycleStatus: .accepted,
            deadlineAt: now.addingTimeInterval(600),
            permissionMode: .fullAccess,
            delegationCapabilitySHA256: nil,
            ownerProcessID: 111
        ))

        let firstPass = try runtime.activityReceipts(
            threadIds: [threadID],
            persistLifecycleReconciliation: false
        )
        XCTAssertEqual(firstPass.count, 1, "sanity: the first poll fetches the saved receipt")
        let decodesAfterFirstPoll = repository.receiptDetailDecodeCountForTesting
        XCTAssertGreaterThan(decodesAfterFirstPoll, 0, "sanity: the first poll decoded from SQLite")

        // Ten idle poll ticks with no receipt writes: zero JSON decodes.
        for _ in 0..<10 {
            let pass = try runtime.activityReceipts(
                threadIds: [threadID],
                persistLifecycleReconciliation: false
            )
            XCTAssertEqual(pass.count, 1, "the cached poll result must be identical to the fresh fetch")
        }
        XCTAssertEqual(
            repository.receiptDetailDecodeCountForTesting, decodesAfterFirstPoll,
            "idle poll ticks must be served from the signature cache (0 decodes per tick)"
        )

        // A receipt append changes the signature; the next poll refreshes and sees it.
        try repository.save(AgentOrchestrationAdmissionReceipt(
            runId: AgentRunID(),
            threadId: threadID,
            routingRevision: 0,
            policyDigest: "external",
            packageRevision: "external",
            provider: .codex,
            providerInstanceId: "codex-cli",
            model: "gpt",
            capabilitySnapshotId: "external",
            decisionReason: "manual-agent-app-controller",
            admittedAt: now.addingTimeInterval(1),
            lifecycleStatus: .accepted,
            deadlineAt: now.addingTimeInterval(600),
            permissionMode: .fullAccess,
            delegationCapabilitySHA256: nil,
            ownerProcessID: 111
        ))
        let refreshed = try runtime.activityReceipts(
            threadIds: [threadID],
            persistLifecycleReconciliation: false
        )
        XCTAssertEqual(refreshed.count, 2, "a receipt write must refresh the cached poll result")
        XCTAssertGreaterThan(
            repository.receiptDetailDecodeCountForTesting, decodesAfterFirstPoll,
            "the refresh after a write decodes from SQLite again"
        )

        // receipt(runId:) — used by isNestedAgentWorker after terminal events —
        // must not re-scan the audit log for a repeated unchanged lookup.
        let firstLookup = try runtime.receipt(runId: firstRunID)
        XCTAssertEqual(firstLookup?.runId, firstRunID, "sanity: the keyed lookup resolves the run")
        let decodesAfterRunLookup = repository.receiptDetailDecodeCountForTesting
        _ = try runtime.receipt(runId: firstRunID)
        _ = try runtime.receipt(runId: firstRunID)
        XCTAssertEqual(
            repository.receiptDetailDecodeCountForTesting, decodesAfterRunLookup,
            "repeated receipt(runId:) lookups with no writes must not re-decode the audit log"
        )
    }

    func testManualControllerRootLinksActualCrossProviderChildRun() throws {
        // WHY: explicit `remote-code agent-app` delegation must not invent a
        // second synthetic run id. The parent and child receipts need the real
        // persisted Agent App run ids so lifecycle and token usage are joinable.
        let (db, root) = try database()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repository = AgentOrchestrationRepository(db: db)
        let runtime = AgentOrchestrationRuntime(
            repository: repository,
            packageVerification: { true },
            killSwitch: { false }
        )
        let parentRunID = AgentRunID()
        let parentThreadID = AgentThreadID()
        let childRunID = AgentRunID()

        let parent = try runtime.recordExternalRoot(
            runId: parentRunID,
            threadId: parentThreadID,
            provider: .codex,
            providerInstanceId: "codex-cli",
            model: "gpt",
            permissionMode: .supervised
        )
        let idempotentParent = try runtime.recordExternalRoot(
            runId: parentRunID,
            threadId: parentThreadID,
            provider: .codex,
            providerInstanceId: "codex-cli",
            model: "gpt",
            permissionMode: .supervised
        )
        let child = try runtime.recordExternalChild(
            runId: childRunID,
            threadId: parentThreadID,
            provider: .grok,
            providerInstanceId: "grok-cli",
            model: "grok",
            nodeId: "nested.grok.42.abc",
            parentRunId: parentRunID,
            requestedPermissionMode: .supervised
        )
        let coordinatorEnsure = try runtime.recordExternalRoot(
            runId: childRunID,
            threadId: parentThreadID,
            provider: .grok,
            providerInstanceId: "grok-cli",
            model: "grok",
            permissionMode: .supervised
        )

        XCTAssertEqual(idempotentParent.id, parent.id)
        XCTAssertEqual(coordinatorEnsure.id, child.id)
        XCTAssertEqual(parent.nodeId, "root")
        XCTAssertEqual(child.runId, childRunID)
        XCTAssertEqual(child.parentReceiptId, parent.id)
        XCTAssertEqual(child.provider, .grok)
        XCTAssertEqual(child.permissionMode, .supervised)
    }

    func testExternalChildCannotEscalateParentPermission() throws {
        // WHY: a cross-provider hop must never turn a supervised controller
        // into a full-access worker merely because the child CLI requested it.
        let (db, root) = try database()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repository = AgentOrchestrationRepository(db: db)
        let runtime = AgentOrchestrationRuntime(
            repository: repository,
            packageVerification: { true },
            killSwitch: { false }
        )
        let threadID = AgentThreadID()
        let parentRunID = AgentRunID()
        _ = try runtime.recordExternalRoot(
            runId: parentRunID,
            threadId: threadID,
            provider: .codex,
            providerInstanceId: "codex-cli",
            model: "gpt",
            permissionMode: .supervised
        )

        XCTAssertThrowsError(
            try runtime.recordExternalChild(
                runId: AgentRunID(),
                threadId: threadID,
                provider: .grok,
                providerInstanceId: "grok-cli",
                model: "grok",
                nodeId: "nested.grok.escalation",
                parentRunId: parentRunID,
                requestedPermissionMode: .fullAccess
            )
        ) { error in
            XCTAssertEqual(
                error as? AgentOrchestrationAdmissionError,
                .invalidChildAdmission("child permission mode exceeds the parent")
            )
        }
        XCTAssertEqual(try repository.receipts().count, 1)
    }

    func testExternalChildMayNarrowParentPermission() throws {
        // WHY: a full-access controller may deliberately delegate a safer,
        // supervised child without losing cross-provider parent linkage.
        let (db, root) = try database()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repository = AgentOrchestrationRepository(db: db)
        let runtime = AgentOrchestrationRuntime(
            repository: repository,
            packageVerification: { true },
            killSwitch: { false }
        )
        let threadID = AgentThreadID()
        let parentRunID = AgentRunID()
        let parent = try runtime.recordExternalRoot(
            runId: parentRunID,
            threadId: threadID,
            provider: .grok,
            providerInstanceId: "grok-cli",
            model: "grok",
            permissionMode: .fullAccess
        )
        let child = try runtime.recordExternalChild(
            runId: AgentRunID(),
            threadId: threadID,
            provider: .claude,
            providerInstanceId: "claude-cli",
            model: "claude",
            nodeId: "nested.claude.supervised",
            parentRunId: parentRunID,
            requestedPermissionMode: .supervised
        )

        XCTAssertEqual(child.parentReceiptId, parent.id)
        XCTAssertEqual(child.permissionMode, .supervised)
    }

    func testExternalGrandchildKeepsEachAgentAppsRealThread() throws {
        // WHY: a nested Agent App owns a new thread. Its receipt must retain
        // that real thread so the child can itself become the validated parent
        // of a cross-provider grandchild.
        let (db, root) = try database()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repository = AgentOrchestrationRepository(db: db)
        let runtime = AgentOrchestrationRuntime(
            repository: repository,
            packageVerification: { true },
            killSwitch: { false }
        )
        let rootThreadID = AgentThreadID()
        let childThreadID = AgentThreadID()
        let grandchildThreadID = AgentThreadID()
        let rootRunID = AgentRunID()
        let childRunID = AgentRunID()
        let rootReceipt = try runtime.recordExternalRoot(
            runId: rootRunID,
            threadId: rootThreadID,
            provider: .codex,
            providerInstanceId: "codex-cli",
            model: "gpt",
            permissionMode: .fullAccess
        )
        let childReceipt = try runtime.recordExternalChild(
            runId: childRunID,
            threadId: childThreadID,
            provider: .grok,
            providerInstanceId: "grok-cli",
            model: "grok",
            nodeId: "nested.grok.child",
            parentRunId: rootRunID,
            parentThreadId: rootThreadID,
            requestedPermissionMode: .autoAcceptEdits
        )
        let grandchildReceipt = try runtime.recordExternalChild(
            runId: AgentRunID(),
            threadId: grandchildThreadID,
            provider: .claude,
            providerInstanceId: "claude-cli",
            model: "claude",
            nodeId: "nested.claude.grandchild",
            parentRunId: childRunID,
            parentThreadId: childThreadID,
            requestedPermissionMode: .supervised
        )

        XCTAssertEqual(childReceipt.threadId, childThreadID)
        XCTAssertEqual(childReceipt.parentReceiptId, rootReceipt.id)
        XCTAssertEqual(grandchildReceipt.threadId, grandchildThreadID)
        XCTAssertEqual(grandchildReceipt.parentReceiptId, childReceipt.id)
        XCTAssertEqual(grandchildReceipt.permissionMode, .supervised)
    }

    func testExternalChildRejectsFinalizedParent() throws {
        // WHY: a stale provider process must not append new work underneath a
        // controller that has already completed.
        let (db, root) = try database()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repository = AgentOrchestrationRepository(db: db)
        let runtime = AgentOrchestrationRuntime(
            repository: repository,
            packageVerification: { true },
            killSwitch: { false }
        )
        let threadID = AgentThreadID()
        let parentRunID = AgentRunID()
        _ = try runtime.recordExternalRoot(
            runId: parentRunID,
            threadId: threadID,
            provider: .claude,
            providerInstanceId: "claude-cli",
            model: "claude",
            permissionMode: .fullAccess
        )
        try runtime.finalizeReceipt(runId: parentRunID, status: .completed)

        XCTAssertThrowsError(
            try runtime.recordExternalChild(
                runId: AgentRunID(),
                threadId: threadID,
                provider: .codex,
                providerInstanceId: "codex-cli",
                model: "gpt",
                nodeId: "nested.codex.stale",
                parentRunId: parentRunID,
                requestedPermissionMode: .supervised
            )
        ) { error in
            XCTAssertEqual(
                error as? AgentOrchestrationAdmissionError,
                .invalidChildAdmission("parent receipt is not active")
            )
        }
    }

    func testDirectRunLookupFindsParentOlderThanRecentReceiptWindow() throws {
        // WHY: a long-lived controller can have more than 500 newer receipts.
        // Parent validation must query its run directly instead of disappearing
        // from an arbitrary recent-activity window.
        let (db, root) = try database()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repository = AgentOrchestrationRepository(db: db)
        let base = Date(timeIntervalSince1970: 10_000)
        let runtime = AgentOrchestrationRuntime(
            repository: repository,
            packageVerification: { true },
            killSwitch: { false },
            now: { base },
            externalLeaseDuration: 10_000,
            processIsAlive: { _ in true }
        )
        let parentRunID = AgentRunID()
        let parentThreadID = AgentThreadID()
        let parent = try runtime.recordExternalRoot(
            runId: parentRunID,
            threadId: parentThreadID,
            provider: .codex,
            providerInstanceId: "codex-cli",
            model: "gpt",
            permissionMode: .supervised,
            ownerProcessID: 111
        )

        for offset in 1...501 {
            try repository.save(AgentOrchestrationAdmissionReceipt(
                runId: AgentRunID(),
                threadId: AgentThreadID(),
                routingRevision: 0,
                policyDigest: "fixture",
                packageRevision: "fixture",
                provider: .grok,
                providerInstanceId: "fixture",
                model: "fixture",
                capabilitySnapshotId: "fixture",
                decisionReason: "fixture",
                admittedAt: base.addingTimeInterval(TimeInterval(offset)),
                lifecycleStatus: .accepted
            ))
        }

        XCTAssertFalse(try repository.receipts(limit: 500).contains { $0.id == parent.id })
        XCTAssertEqual(try repository.receipt(runId: parentRunID)?.id, parent.id)
        XCTAssertEqual(
            try runtime.activeReceipt(runId: parentRunID, threadId: parentThreadID)?.id,
            parent.id
        )
        let child = try runtime.recordExternalChild(
            runId: AgentRunID(),
            threadId: parentThreadID,
            provider: .grok,
            providerInstanceId: "grok-cli",
            model: "grok",
            nodeId: "nested.grok.after-many-receipts",
            parentRunId: parentRunID,
            requestedPermissionMode: .supervised,
            ownerProcessID: 222
        )
        XCTAssertEqual(child.parentReceiptId, parent.id)
    }

    func testConcurrentRepositoriesAdmitOneChildAndFinalizeOnce() throws {
        // WHY: the app and provider proxy are separate writers. Two begin calls
        // for one run must compare-and-append one child, and competing terminal
        // statuses must append exactly one lifecycle/ledger outcome.
        let (db, root) = try database()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let secondDB = try SQLiteDB(path: db.path)
        let firstRepository = AgentOrchestrationRepository(db: db)
        let secondRepository = AgentOrchestrationRepository(db: secondDB)
        let firstRuntime = AgentOrchestrationRuntime(
            repository: firstRepository,
            packageVerification: { true },
            killSwitch: { false },
            processIsAlive: { _ in true }
        )
        let secondRuntime = AgentOrchestrationRuntime(
            repository: secondRepository,
            packageVerification: { true },
            killSwitch: { false },
            processIsAlive: { _ in true }
        )
        let parentRunID = AgentRunID()
        let threadID = AgentThreadID()
        let parent = try firstRuntime.recordExternalRoot(
            runId: parentRunID,
            threadId: threadID,
            provider: .codex,
            providerInstanceId: "codex-cli",
            model: "gpt",
            permissionMode: .supervised,
            ownerProcessID: 111
        )
        let childRunID = AgentRunID()
        let start = DispatchSemaphore(value: 0)
        let done = DispatchGroup()
        let resultsLock = NSLock()
        var results: [Result<AgentOrchestrationAdmissionReceipt, Error>] = []

        for runtime in [firstRuntime, secondRuntime] {
            done.enter()
            DispatchQueue.global().async {
                start.wait()
                let result = Result {
                    try runtime.recordExternalChild(
                        runId: childRunID,
                        threadId: threadID,
                        provider: .grok,
                        providerInstanceId: "grok-cli",
                        model: "grok",
                        nodeId: "nested.grok.race",
                        parentRunId: parentRunID,
                        requestedPermissionMode: .supervised,
                        ownerProcessID: 222
                    )
                }
                resultsLock.lock()
                results.append(result)
                resultsLock.unlock()
                done.leave()
            }
        }
        start.signal()
        start.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success)
        let children = try results.map { try $0.get() }
        XCTAssertEqual(Set(children.map(\.id)).count, 1)
        XCTAssertEqual(
            try firstRepository.receipts(limit: 20).filter { $0.runId == childRunID }.count,
            1
        )

        let finalizeStart = DispatchSemaphore(value: 0)
        let finalizeDone = DispatchGroup()
        let finalizeErrorsLock = NSLock()
        var finalizeErrors: [Error] = []
        for (runtime, status) in [(firstRuntime, AgentRunStatus.completed), (secondRuntime, .failed)] {
            finalizeDone.enter()
            DispatchQueue.global().async {
                finalizeStart.wait()
                do {
                    try runtime.finalizeReceipt(runId: parentRunID, status: status)
                } catch {
                    finalizeErrorsLock.lock()
                    finalizeErrors.append(error)
                    finalizeErrorsLock.unlock()
                }
                finalizeDone.leave()
            }
        }
        finalizeStart.signal()
        finalizeStart.signal()
        XCTAssertEqual(finalizeDone.wait(timeout: .now() + 10), .success)
        XCTAssertTrue(finalizeErrors.isEmpty)
        XCTAssertEqual(try firstRepository.receipt(runId: parentRunID)?.id, parent.id)
        XCTAssertEqual(
            try firstRepository.ledger(limit: 20).filter { $0.runId == parentRunID }.count,
            1
        )
    }

    func testExternalLeaseHeartbeatAndOwnerLivenessBoundParentAdmission() throws {
        // WHY: a crashed external controller must not remain an accepted parent
        // forever, while a healthy long-running worker can explicitly renew.
        let (db, root) = try database()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repository = AgentOrchestrationRepository(db: db)
        let clock = OrchestrationTestClock(Date(timeIntervalSince1970: 20_000))
        let runtime = AgentOrchestrationRuntime(
            repository: repository,
            packageVerification: { true },
            killSwitch: { false },
            now: { clock.now() },
            externalLeaseDuration: 60,
            processIsAlive: { $0 == 111 || $0 == 222 }
        )
        let threadID = AgentThreadID()
        let expiringRunID = AgentRunID()
        _ = try runtime.recordExternalRoot(
            runId: expiringRunID,
            threadId: threadID,
            provider: .codex,
            providerInstanceId: "codex-cli",
            model: "gpt",
            permissionMode: .supervised,
            ownerProcessID: 111
        )
        clock.advance(61)
        XCTAssertNil(try runtime.activeReceipt(runId: expiringRunID, threadId: threadID))
        XCTAssertThrowsError(
            try runtime.recordExternalChild(
                runId: AgentRunID(),
                threadId: threadID,
                provider: .grok,
                providerInstanceId: "grok-cli",
                model: "grok",
                nodeId: "nested.grok.expired",
                parentRunId: expiringRunID,
                ownerProcessID: 222
            )
        ) {
            XCTAssertEqual(
                $0 as? AgentOrchestrationAdmissionError,
                .invalidChildAdmission("parent external lease expired")
            )
        }

        let liveRunID = AgentRunID()
        _ = try runtime.recordExternalRoot(
            runId: liveRunID,
            threadId: threadID,
            provider: .claude,
            providerInstanceId: "claude-cli",
            model: "claude",
            permissionMode: .supervised,
            ownerProcessID: 111
        )
        clock.advance(30)
        let renewed = try runtime.renewExternalReceiptLease(
            runId: liveRunID,
            ownerProcessID: 111,
            leaseDuration: 60
        )
        clock.advance(40)
        XCTAssertNotNil(try runtime.activeReceipt(runId: liveRunID, threadId: threadID))
        let child = try runtime.recordExternalChild(
            runId: AgentRunID(),
            threadId: threadID,
            provider: .grok,
            providerInstanceId: "grok-cli",
            model: "grok",
            nodeId: "nested.grok.after-heartbeat",
            parentRunId: liveRunID,
            ownerProcessID: 222
        )
        XCTAssertLessThanOrEqual(try XCTUnwrap(child.deadlineAt), try XCTUnwrap(renewed.deadlineAt))

        let deadOwnerRunID = AgentRunID()
        _ = try runtime.recordExternalRoot(
            runId: deadOwnerRunID,
            threadId: threadID,
            provider: .codex,
            providerInstanceId: "codex-cli",
            model: "gpt",
            permissionMode: .supervised,
            ownerProcessID: 999
        )
        XCTAssertNil(try runtime.activeReceipt(runId: deadOwnerRunID, threadId: threadID))
        XCTAssertThrowsError(
            try runtime.recordExternalChild(
                runId: AgentRunID(),
                threadId: threadID,
                provider: .grok,
                providerInstanceId: "grok-cli",
                model: "grok",
                nodeId: "nested.grok.dead-owner",
                parentRunId: deadOwnerRunID,
                ownerProcessID: 222
            )
        ) {
            XCTAssertEqual(
                $0 as? AgentOrchestrationAdmissionError,
                .invalidChildAdmission("parent owner process is not alive")
            )
        }
    }

    func testActivityReceiptsPersistDeadExternalOwnerAsUnknown() throws {
        // WHY: the Subagents UI polls durable receipts independently of the
        // provider process. A crashed worker must stop presenting as Active on
        // the next poll, and that uncertainty must survive app relaunch.
        let (db, root) = try database()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repository = AgentOrchestrationRepository(db: db)
        let runtime = AgentOrchestrationRuntime(
            repository: repository,
            packageVerification: { true },
            killSwitch: { false },
            processIsAlive: { $0 == 111 }
        )
        let deadRunID = AgentRunID()
        let deadThreadID = AgentThreadID()
        let receipt = try runtime.recordExternalRoot(
            runId: deadRunID,
            threadId: deadThreadID,
            provider: .grok,
            providerInstanceId: "grok-cli",
            model: "grok",
            permissionMode: .supervised,
            ownerProcessID: 999
        )

        _ = try runtime.activityReceipts()
        let activity = try runtime.activityReceipts()

        XCTAssertEqual(activity.first(where: { $0.id == receipt.id })?.lifecycleStatus, .unknown)
        XCTAssertEqual(try repository.receipt(runId: deadRunID)?.lifecycleStatus, .unknown)
        XCTAssertEqual(
            try repository.ledger(limit: 10).filter { $0.runId == deadRunID }.count,
            1,
            "repeated UI polls must not append duplicate unknown lifecycle outcomes"
        )
    }

    func testActivityReceiptsThreadScopedIncludesParentChainAndExcludesSiblings() throws {
        // WHY: the badge poll must decode only the selected thread + nested
        // workers, still attribute middleware children on other thread ids, and
        // never surface an unrelated sibling thread's receipts.
        let (db, root) = try database()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repository = AgentOrchestrationRepository(db: db)
        let runtime = AgentOrchestrationRuntime(
            repository: repository,
            packageVerification: { true },
            killSwitch: { false },
            processIsAlive: { _ in true }
        )
        let threadA = AgentThreadID()
        let threadB = AgentThreadID()
        let threadC = AgentThreadID()
        let parentRunID = AgentRunID()
        let parent = try runtime.recordExternalRoot(
            runId: parentRunID,
            threadId: threadA,
            provider: .claude,
            providerInstanceId: "claude-cli",
            model: "opus",
            permissionMode: .supervised,
            ownerProcessID: 111
        )
        let sibling = try runtime.recordExternalRoot(
            runId: AgentRunID(),
            threadId: threadB,
            provider: .codex,
            providerInstanceId: "codex-cli",
            model: "gpt",
            permissionMode: .supervised,
            ownerProcessID: 222
        )
        let nested = try runtime.recordExternalChild(
            runId: AgentRunID(),
            threadId: threadC,
            provider: .grok,
            providerInstanceId: "grok-cli",
            model: "grok",
            nodeId: "middleware-nested",
            parentRunId: parentRunID,
            parentThreadId: threadA,
            ownerProcessID: 333
        )

        let activity = try runtime.activityReceipts(threadIds: [threadA])
        let ids = Set(activity.map(\.id))

        XCTAssertTrue(ids.contains(parent.id), "selected-thread root must be returned for parent-chain walks")
        XCTAssertTrue(ids.contains(nested.id), "middleware child on another thread must attribute via parent chain")
        XCTAssertFalse(ids.contains(sibling.id), "unrelated sibling-thread receipts must stay out of the scoped fetch")
    }

    func testActivityReceiptsReadOnlyPollProjectsUnknownWithoutPersisting() throws {
        // WHY: the 2s UI badge poll must demote dead workers for chrome without
        // taking a write lock / appending ledger rows every tick under multi-thread load.
        let (db, root) = try database()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repository = AgentOrchestrationRepository(db: db)
        let runtime = AgentOrchestrationRuntime(
            repository: repository,
            packageVerification: { true },
            killSwitch: { false },
            processIsAlive: { $0 == 111 }
        )
        let threadA = AgentThreadID()
        let dead = try runtime.recordExternalRoot(
            runId: AgentRunID(),
            threadId: threadA,
            provider: .grok,
            providerInstanceId: "grok-cli",
            model: "grok",
            permissionMode: .supervised,
            ownerProcessID: 999
        )

        let projected = try runtime.activityReceipts(
            threadIds: [threadA],
            persistLifecycleReconciliation: false
        )
        XCTAssertEqual(
            projected.first(where: { $0.id == dead.id })?.lifecycleStatus,
            .unknown,
            "read-only poll still projects demotion for the badge"
        )
        XCTAssertEqual(
            try repository.receipt(runId: dead.runId!)?.lifecycleStatus,
            .accepted,
            "read-only poll must not persist lifecycle demotion"
        )
        XCTAssertEqual(
            try repository.ledger(limit: 10).filter { $0.runId == dead.runId }.count,
            0,
            "read-only poll must not append unknown ledger rows"
        )
    }

    func testActivityReceiptsThreadScopedReconcilesOnlyScopedDeadWorkers() throws {
        // WHY: scoped polls must still demote dead workers on the selected
        // thread, but must not mutate dead accepted rows on other threads
        // (incomplete parent view would also risk wrong demotions of live nested workers).
        let (db, root) = try database()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repository = AgentOrchestrationRepository(db: db)
        let runtime = AgentOrchestrationRuntime(
            repository: repository,
            packageVerification: { true },
            killSwitch: { false },
            processIsAlive: { $0 == 111 }
        )
        let threadA = AgentThreadID()
        let threadB = AgentThreadID()
        let deadOnA = try runtime.recordExternalRoot(
            runId: AgentRunID(),
            threadId: threadA,
            provider: .grok,
            providerInstanceId: "grok-cli",
            model: "grok",
            permissionMode: .supervised,
            ownerProcessID: 999
        )
        let deadOnB = try runtime.recordExternalRoot(
            runId: AgentRunID(),
            threadId: threadB,
            provider: .claude,
            providerInstanceId: "claude-cli",
            model: "claude",
            permissionMode: .supervised,
            ownerProcessID: 888
        )

        let activity = try runtime.activityReceipts(threadIds: [threadA])

        XCTAssertEqual(
            activity.first(where: { $0.id == deadOnA.id })?.lifecycleStatus,
            .unknown,
            "selected-thread dead external must reconcile to unknown on the scoped poll"
        )
        XCTAssertEqual(try repository.receipt(runId: deadOnA.runId!)?.lifecycleStatus, .unknown)
        XCTAssertEqual(
            try repository.receipt(runId: deadOnB.runId!)?.lifecycleStatus,
            .accepted,
            "non-selected dead external must remain accepted until that thread is selected / global reconcile"
        )
        XCTAssertFalse(
            activity.contains(where: { $0.id == deadOnB.id }),
            "scoped result must not include the other thread's receipt"
        )
    }

    func testAdmissionReceiptJSONOmitsNilParentReceiptId() throws {
        // WHY: the scoped child prefilter uses LIKE '%"parentReceiptId"%' and
        // assumes Codable omits the key when nil. Emitting null would match every root.
        let root = AgentOrchestrationAdmissionReceipt(
            runId: AgentRunID(),
            threadId: AgentThreadID(),
            routingRevision: 1,
            policyDigest: String(repeating: "a", count: 64),
            packageRevision: "test",
            provider: .codex,
            providerInstanceId: "codex",
            model: "gpt",
            capabilitySnapshotId: "cap",
            decisionReason: "test",
            lifecycleStatus: .accepted
        )
        let child = AgentOrchestrationAdmissionReceipt(
            parentReceiptId: root.id,
            runId: AgentRunID(),
            threadId: AgentThreadID(),
            nodeId: "worker",
            routingRevision: 1,
            policyDigest: String(repeating: "a", count: 64),
            packageRevision: "test",
            provider: .grok,
            providerInstanceId: "grok",
            model: "grok",
            capabilitySnapshotId: "cap",
            decisionReason: "test",
            lifecycleStatus: .accepted
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let rootJSON = String(data: try encoder.encode(root), encoding: .utf8) ?? ""
        let childJSON = String(data: try encoder.encode(child), encoding: .utf8) ?? ""
        XCTAssertFalse(
            rootJSON.contains("parentReceiptId"),
            "root receipts must omit parentReceiptId so the child LIKE prefilter stays selective"
        )
        XCTAssertTrue(
            childJSON.contains("\"parentReceiptId\""),
            "nested workers must encode parentReceiptId for the scoped child prefilter"
        )
    }

    func testActivityReceiptsPersistExpiredExternalLeaseAsUnknown() throws {
        // WHY: a still-existing PID is insufficient after its bounded lease
        // expires; otherwise PID reuse or a wedged wrapper can pin Active.
        let (db, root) = try database()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repository = AgentOrchestrationRepository(db: db)
        let clock = OrchestrationTestClock(Date(timeIntervalSince1970: 40_000))
        let runtime = AgentOrchestrationRuntime(
            repository: repository,
            packageVerification: { true },
            killSwitch: { false },
            now: { clock.now() },
            externalLeaseDuration: 60,
            processIsAlive: { $0 == 111 }
        )
        let expiredRunID = AgentRunID()
        let expiredThreadID = AgentThreadID()
        let receipt = try runtime.recordExternalRoot(
            runId: expiredRunID,
            threadId: expiredThreadID,
            provider: .claude,
            providerInstanceId: "claude-cli",
            model: "claude",
            permissionMode: .supervised,
            ownerProcessID: 111
        )
        clock.advance(61)

        let activity = try runtime.activityReceipts()

        XCTAssertEqual(activity.first(where: { $0.id == receipt.id })?.lifecycleStatus, .unknown)
        XCTAssertEqual(try repository.receipt(runId: expiredRunID)?.lifecycleStatus, .unknown)
    }

    func testActivityReceiptsKeepLiveExternalWorkerAccepted() throws {
        // WHY: liveness reconciliation must not demote a healthy child whose
        // parent and own process remain live merely because another app process
        // refreshed the activity surface.
        let (db, root) = try database()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repository = AgentOrchestrationRepository(db: db)
        let clock = OrchestrationTestClock(Date(timeIntervalSince1970: 45_000))
        let runtime = AgentOrchestrationRuntime(
            repository: repository,
            packageVerification: { true },
            killSwitch: { false },
            now: { clock.now() },
            externalLeaseDuration: 60,
            processIsAlive: { $0 == 111 || $0 == 222 }
        )
        let threadID = AgentThreadID()
        let parentRunID = AgentRunID()
        _ = try runtime.recordExternalRoot(
            runId: parentRunID,
            threadId: threadID,
            provider: .claude,
            providerInstanceId: "claude-cli",
            model: "claude",
            permissionMode: .supervised,
            ownerProcessID: 111
        )
        clock.advance(1)
        let liveRunID = AgentRunID()
        let receipt = try runtime.recordExternalChild(
            runId: liveRunID,
            threadId: threadID,
            provider: .codex,
            providerInstanceId: "codex-cli",
            model: "gpt",
            nodeId: "nested.codex.live",
            parentRunId: parentRunID,
            ownerProcessID: 222
        )

        let activity = try runtime.activityReceipts(limit: 1)

        XCTAssertEqual(activity.first(where: { $0.id == receipt.id })?.lifecycleStatus, .accepted)
        XCTAssertEqual(try repository.receipt(runId: liveRunID)?.lifecycleStatus, .accepted)
        XCTAssertTrue(try repository.ledger(limit: 10).filter { $0.runId == liveRunID }.isEmpty)
    }

    func testActivityReceiptsCascadeFinalizedParentToChildAndGrandchildUnknown() throws {
        // WHY: provider-native children can share the long-lived app PID. Once
        // their parent finalizes, that PID alone must not leave descendants
        // Working for the remainder of a 24-hour external lease.
        let (db, root) = try database()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repository = AgentOrchestrationRepository(db: db)
        let runtime = AgentOrchestrationRuntime(
            repository: repository,
            packageVerification: { true },
            killSwitch: { false },
            processIsAlive: { _ in true }
        )
        let threadID = AgentThreadID()
        let rootRunID = AgentRunID()
        let childRunID = AgentRunID()
        let grandchildRunID = AgentRunID()
        _ = try runtime.recordExternalRoot(
            runId: rootRunID,
            threadId: threadID,
            provider: .codex,
            providerInstanceId: "codex-cli",
            model: "gpt",
            permissionMode: .supervised,
            ownerProcessID: 111
        )
        let child = try runtime.recordExternalChild(
            runId: childRunID,
            threadId: threadID,
            provider: .grok,
            providerInstanceId: "grok-cli",
            model: "grok",
            nodeId: "nested.grok.child",
            parentRunId: rootRunID,
            ownerProcessID: 222
        )
        let grandchild = try runtime.recordExternalChild(
            runId: grandchildRunID,
            threadId: threadID,
            provider: .claude,
            providerInstanceId: "claude-cli",
            model: "claude",
            nodeId: "nested.claude.grandchild",
            parentRunId: childRunID,
            ownerProcessID: 333
        )
        try runtime.finalizeReceipt(runId: rootRunID, status: .completed)

        let activity = try runtime.activityReceipts()

        XCTAssertEqual(activity.first(where: { $0.id == child.id })?.lifecycleStatus, .unknown)
        XCTAssertEqual(activity.first(where: { $0.id == grandchild.id })?.lifecycleStatus, .unknown)
        XCTAssertEqual(try repository.receipt(runId: childRunID)?.lifecycleStatus, .unknown)
        XCTAssertEqual(try repository.receipt(runId: grandchildRunID)?.lifecycleStatus, .unknown)
    }

    func testActivityReceiptsReconcileExternalReceiptOlderThanFiveHundredRows() throws {
        // WHY: a global audit log can receive hundreds of newer entries while a
        // child runs. Reconciliation must not preserve that older crashed child
        // solely because an arbitrary activity window omitted it.
        let (db, root) = try database()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repository = AgentOrchestrationRepository(db: db)
        let base = Date(timeIntervalSince1970: 50_000)
        let runtime = AgentOrchestrationRuntime(
            repository: repository,
            packageVerification: { true },
            killSwitch: { false },
            now: { base },
            processIsAlive: { _ in false }
        )
        let oldRunID = AgentRunID()
        let oldThreadID = AgentThreadID()
        let old = try runtime.recordExternalRoot(
            runId: oldRunID,
            threadId: oldThreadID,
            provider: .grok,
            providerInstanceId: "grok-cli",
            model: "grok",
            permissionMode: .supervised,
            ownerProcessID: 999
        )
        for offset in 1...501 {
            try repository.save(AgentOrchestrationAdmissionReceipt(
                runId: AgentRunID(),
                threadId: AgentThreadID(),
                routingRevision: 0,
                policyDigest: "fixture",
                packageRevision: "fixture",
                provider: .codex,
                providerInstanceId: "fixture",
                model: "fixture",
                capabilitySnapshotId: "fixture",
                decisionReason: "fixture",
                admittedAt: base.addingTimeInterval(TimeInterval(offset)),
                lifecycleStatus: .finalized,
                finalRunStatus: .completed
            ))
        }

        XCTAssertFalse(try repository.receipts(limit: 500).contains { $0.id == old.id })
        let activity = try runtime.activityReceipts()

        XCTAssertEqual(activity.first(where: { $0.id == old.id })?.lifecycleStatus, .unknown)
        XCTAssertEqual(try repository.receipt(runId: oldRunID)?.lifecycleStatus, .unknown)
    }

    func testLegacyExternalReceiptWithoutOwnerCannotActAsParent() throws {
        // WHY: accepted is not enough for a process-owned external controller.
        // A legacy row without an owner PID must fail closed after the bounded
        // lease migration instead of becoming a permanent orphan parent.
        let (db, root) = try database()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repository = AgentOrchestrationRepository(db: db)
        let current = Date(timeIntervalSince1970: 30_000)
        let runtime = AgentOrchestrationRuntime(
            repository: repository,
            packageVerification: { true },
            killSwitch: { false },
            now: { current },
            processIsAlive: { _ in true }
        )
        let threadID = AgentThreadID()
        let parentRunID = AgentRunID()
        try repository.save(AgentOrchestrationAdmissionReceipt(
            runId: parentRunID,
            threadId: threadID,
            routingRevision: 0,
            policyDigest: "external",
            packageRevision: "external",
            provider: .codex,
            providerInstanceId: "codex-cli",
            model: "gpt",
            capabilitySnapshotId: "external",
            decisionReason: "manual-agent-app-controller",
            admittedAt: current,
            lifecycleStatus: .accepted,
            deadlineAt: current.addingTimeInterval(60),
            permissionMode: .supervised
        ))

        XCTAssertNil(try runtime.activeReceipt(runId: parentRunID, threadId: threadID))
        XCTAssertThrowsError(
            try runtime.recordExternalChild(
                runId: AgentRunID(),
                threadId: threadID,
                provider: .grok,
                providerInstanceId: "grok-cli",
                model: "grok",
                nodeId: "nested.grok.ownerless-parent",
                parentRunId: parentRunID,
                ownerProcessID: 222
            )
        ) {
            XCTAssertEqual(
                $0 as? AgentOrchestrationAdmissionError,
                .invalidChildAdmission("parent owner process is unavailable")
            )
        }
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
                AgentModelDescriptor(id: "grok-4.7", label: "Grok 4.7", provider: .grok, supportsReasoning: true,
                                     supportedReasoningEfforts: [.low, .medium, .high, .xhigh]),
                AgentModelDescriptor(id: "grok-4.6", label: "Grok 4.6", provider: .grok, supportsReasoning: true,
                                     supportedReasoningEfforts: [.medium, .high, .xhigh]),
                AgentModelDescriptor(id: "grok-4.5", label: "Grok", provider: .grok, supportsReasoning: true,
                                     supportedReasoningEfforts: [.medium, .high])
            ]
        )
        XCTAssertEqual(grok.modelId, "grok-4.7")
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
                AgentModelDescriptor(id: "haiku", label: "Haiku", provider: .claude, supportsReasoning: false),
                AgentModelDescriptor(id: "sonnet", label: "Sonnet", provider: .claude, supportsReasoning: true,
                                     supportedReasoningEfforts: [.low, .medium, .high, .xhigh])
            ]
        )
        XCTAssertEqual(claude.modelId, "sonnet",
                       "Auto LIGHT must choose a reasoning-capable Claude model, never Haiku")
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
                AgentModelDescriptor(id: "grok-4.7", label: "Grok 4.7", provider: .grok, supportsReasoning: true,
                                     supportedReasoningEfforts: [.low, .medium, .high, .xhigh]),
                AgentModelDescriptor(id: "grok-4.6", label: "Grok 4.6", provider: .grok, supportsReasoning: true,
                                     supportedReasoningEfforts: [.medium, .high, .xhigh]),
                AgentModelDescriptor(id: "grok-4.5", label: "Grok 4.5", provider: .grok, supportsReasoning: true,
                                     supportedReasoningEfforts: [.medium, .high])
            ]
        )
        XCTAssertEqual(grok.modelId, "grok-4.7")
        XCTAssertEqual(grok.reasoningEffort, .medium)
    }

    func test_autoLightClaudeSkipsLegacySonnetWithoutEffortControl() {
        let mixedCatalog = AgentOrchestrationRuntime.lightControllerSelection(
            provider: .claude,
            availableModels: [
                AgentModelDescriptor(
                    id: "claude-sonnet-4-5",
                    label: "Sonnet 4.5",
                    provider: .claude,
                    supportsReasoning: false,
                    supportedReasoningEfforts: []
                ),
                AgentModelDescriptor(
                    id: "claude-sonnet-4-6-20260801",
                    label: "Sonnet 4.6",
                    provider: .claude,
                    supportsReasoning: true,
                    supportedReasoningEfforts: [.low, .medium, .high, .max]
                )
            ]
        )
        XCTAssertEqual(
            mixedCatalog.modelId,
            "claude-sonnet-4-6-20260801",
            "LIGHT must not bind a legacy Sonnet whose effort control would be normalized away"
        )
        XCTAssertEqual(mixedCatalog.reasoningEffort, .high)

        let legacyOnlyCatalog = AgentOrchestrationRuntime.lightControllerSelection(
            provider: .claude,
            availableModels: [
                AgentModelDescriptor(
                    id: "claude-sonnet-4-5",
                    label: "Sonnet 4.5",
                    provider: .claude,
                    supportsReasoning: false,
                    supportedReasoningEfforts: []
                )
            ]
        )
        XCTAssertEqual(
            legacyOnlyCatalog.modelId,
            "sonnet",
            "when no catalog entry exposes effort, use the current reasoning-capable alias instead of a legacy model"
        )
        XCTAssertEqual(legacyOnlyCatalog.reasoningEffort, .high)
    }

    func test_manualClaudeEffortNormalizationMatchesProviderModelContract() {
        func normalized(_ model: String, _ effort: AgentReasoningEffort?) -> AgentReasoningEffort? {
            AgentRunCoordinator.normalizedProviderReasoningEffort(
                provider: .claude,
                model: model,
                requested: effort
            )
        }

        XCTAssertEqual(normalized("claude-opus-4-7", .xhigh), .xhigh)
        XCTAssertEqual(normalized("claude-opus-5", .max), .max)
        XCTAssertEqual(normalized("claude-mythos-5", .xhigh), .xhigh)
        XCTAssertEqual(normalized("sonnet", .xhigh), .xhigh)
        XCTAssertEqual(normalized("opus[1m]", .max), .max)
        XCTAssertEqual(normalized("sonnet[1m]", .xhigh), .xhigh)
        XCTAssertEqual(normalized("best", .ultracode), .ultracode)
        XCTAssertEqual(normalized("claude-opus-4-6", .xhigh), .high)
        XCTAssertEqual(normalized("claude-sonnet-4-6", nil), .high)
        XCTAssertEqual(normalized("claude-opus-4-7", nil), .xhigh)
        XCTAssertEqual(normalized("claude-opus-5-5", nil), .medium,
                       "Opus 5.5 omitted effort must match live Claude Code default_effort medium")
        XCTAssertEqual(normalized("opus", nil), .medium,
                       "2.1.282 opus alias resolves to Opus 5.5")
        XCTAssertEqual(normalized("default", nil), .medium,
                       "2.1.282 catalog default alias resolves to Opus 5.5")
        XCTAssertEqual(normalized("claude-mythos-preview", .xhigh), .high)
        XCTAssertEqual(normalized("claude-opus-4-5", .max), .high)
        XCTAssertNil(normalized("claude-haiku-4-5", .high),
                     "manual Haiku receipts must not claim an unsupported effort")
        XCTAssertNil(normalized("claude-opus-4-1", .high),
                     "legacy Claude models without an effort control must not claim one")
        XCTAssertNil(normalized("claude-custom-future", .high),
                     "custom Claude models must fail closed until their effort contract is observable")
    }

    func test_autoOrchestrateProviderPromptAlwaysInvokesSkill() {
        let wrapped = AgentOrchestrationRuntime.autoOrchestrateProviderPrompt(userPrompt: "fix the bug")
        XCTAssertTrue(wrapped.hasPrefix("$remote-code-orchestrate"))
        XCTAssertTrue(wrapped.contains("fix the bug"))
        XCTAssertTrue(wrapped.contains("skill content must stay complete")
                      || wrapped.contains("never Distill skill"),
                      "Auto wrap must protect complete skill content")
        XCTAssertTrue(wrapped.contains("Distill applies only to eligible ordinary")
                      || wrapped.contains("do not require every worker prompt to restate Distill"),
                      "Auto wrap must not force Distill restatement in every worker")
        XCTAssertFalse(wrapped.contains("EVERY worker/reviewer prompt must require explicit `| distill`"),
                       "removed: requiring Distill restatement in every worker prompt")
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
