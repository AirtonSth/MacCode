import XCTest
import CoreModel
@testable import Persistence
@testable import AgentRuntime
@testable import Surfaces

@MainActor
final class AgentAutoRoutingViewModelTests: XCTestCase {
    private func fixture(defaults suppliedDefaults: UserDefaults? = nil) throws -> (AgentAppViewModel, AgentThreadRepository, String) {
        let suiteName = "rc-auto-vm-" + UUID().uuidString
        let root = NSTemporaryDirectory() + suiteName
        let defaults = suppliedDefaults ?? UserDefaults(suiteName: suiteName)!
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: root).run()
        let threads = AgentThreadRepository(db: db)
        let messages = AgentMessageRepository(db: db)
        let runs = AgentRunRepository(db: db)
        let coordinator = AgentRunCoordinator(
            runRepo: runs,
            messageRepo: messages,
            threadRepo: threads,
            providers: [
                .codex: FakeProviderRunner(provider: .codex),
                .claude: FakeProviderRunner(provider: .claude),
                .grok: FakeProviderRunner(provider: .grok)
            ]
        )
        let runtime = AgentOrchestrationRuntime(
            repository: AgentOrchestrationRepository(db: db),
            packageVerification: { true },
            rolloutGate: { true },
            killSwitch: { false }
        )
        let vm = AgentAppViewModel(
            workspaceID: WorkspaceID(), cwd: root, coordinator: coordinator,
            threadRepo: threads, messageRepo: messages,
            lastModelStore: AgentLastModelStore(defaults: defaults),
            initialRoutingMode: .auto,
            newThreadDefaultsStore: AgentNewThreadDefaultsStore(defaults: defaults),
            orchestrationRuntime: runtime
        )
        let lastModelStore = AgentLastModelStore(defaults: defaults)
        lastModelStore.remember(model: "claude-live", for: .claude)
        vm.providerSnapshots = AgentProvider.allCases.map { provider in
            AgentProviderSnapshotFactory.snapshot(
                provider: provider,
                models: [AgentModelDescriptor(
                    id: "\(provider.rawValue)-live",
                    label: "Live",
                    provider: provider,
                    supportsReasoning: true,
                    supportedReasoningEfforts: provider == .claude
                        ? AgentReasoningEffort.claudeSupportedCases
                        : AgentReasoningEffort.supportedCases,
                    supportsServiceTier: true
                )],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                capabilitiesOverride: AgentProviderCapabilities(supportsStreaming: true, supportsPlanReview: true),
                modelDiscoverySource: .live
            )
        }
        return (vm, threads, root)
    }

    func testAutoIsTheDefaultAndCreatesAutoThreadsForEveryProvider() throws {
        let (vm, threads, root) = try fixture()
        defer { try? FileManager.default.removeItem(atPath: root) }

        XCTAssertEqual(vm.routingMode, .auto,
                       "A user without saved choices must start with Auto enabled.")

        for provider in AgentProvider.allCases {
            vm.setProvider(provider)
            vm.createThread(title: "auto-\(provider.rawValue)")
            let thread = try XCTUnwrap(try threads.get(id: try XCTUnwrap(vm.selectedThreadId)))
            XCTAssertEqual(thread.effectiveRoutingConfiguration.mode, .auto,
                           "Auto must be available and selected for \(provider.rawValue).")
            XCTAssertEqual(thread.effectiveRoutingConfiguration.eligibleProviders, AgentProvider.allCases)
            XCTAssertGreaterThan(thread.effectiveRoutingConfiguration.revision, 0,
                                 "Auto threads must be admit-ready (revision > 0); revision 0 fails with invalidPolicy.")
            let expectedDigest = AgentOrchestrationRuntime(
                packageVerification: { true },
                rolloutGate: { true },
                killSwitch: { false }
            ).policyDigest
            XCTAssertEqual(
                thread.effectiveRoutingConfiguration.policyDigest,
                expectedDigest,
                "Auto threads must store the current orchestration policy digest."
            )
        }
    }

    func testCreateThreadAutoConfigurationIsAdmitReady() throws {
        let (vm, threads, root) = try fixture()
        defer { try? FileManager.default.removeItem(atPath: root) }

        vm.createThread(title: "admit-ready auto")
        let thread = try XCTUnwrap(try threads.get(id: try XCTUnwrap(vm.selectedThreadId)))
        let configuration = thread.effectiveRoutingConfiguration
        let runtime = AgentOrchestrationRuntime(
            packageVerification: { true },
            rolloutGate: { true },
            killSwitch: { false }
        )

        XCTAssertNoThrow(
            try runtime.route(configuration: configuration, providerSnapshots: vm.providerSnapshots),
            "A freshly created Auto thread must pass orchestration route admission."
        )
    }

    func testSubagentRefreshDemotesDeadExternalReceiptFromActive() async throws {
        // WHY: the Agent App refresh is the user-visible boundary. It must use
        // the runtime's lease/PID reconciliation rather than project a stale
        // accepted receipt as an indefinitely active subagent.
        let root = NSTemporaryDirectory() + "rc-subagent-liveness-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: root) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: root).run()
        let threads = AgentThreadRepository(db: db)
        let messages = AgentMessageRepository(db: db)
        let runs = AgentRunRepository(db: db)
        let coordinator = AgentRunCoordinator(
            runRepo: runs,
            messageRepo: messages,
            threadRepo: threads,
            providers: [
                .codex: FakeProviderRunner(provider: .codex),
                .claude: FakeProviderRunner(provider: .claude),
                .grok: FakeProviderRunner(provider: .grok)
            ]
        )
        let repository = AgentOrchestrationRepository(db: db)
        let runtime = AgentOrchestrationRuntime(
            repository: repository,
            packageVerification: { true },
            rolloutGate: { true },
            killSwitch: { false },
            processIsAlive: { _ in false }
        )
        let vm = AgentAppViewModel(
            workspaceID: WorkspaceID(),
            cwd: root,
            coordinator: coordinator,
            threadRepo: threads,
            messageRepo: messages,
            orchestrationRuntime: runtime
        )
        vm.createThread(title: "dead external child")
        let threadID = try XCTUnwrap(vm.selectedThreadId)
        let seedRuntime = AgentOrchestrationRuntime(
            repository: repository,
            packageVerification: { true },
            rolloutGate: { true },
            killSwitch: { false },
            processIsAlive: { _ in true }
        )
        let parentRunID = AgentRunID()
        let parentCapability = AgentDelegationCapability.issue()
        _ = try seedRuntime.recordExternalRoot(
            runId: parentRunID,
            threadId: threadID,
            provider: .codex,
            providerInstanceId: "codex-cli",
            model: "gpt",
            permissionMode: .supervised,
            delegationCapabilitySHA256: AgentDelegationCapability.sha256Hex(
                parentCapability
            ),
            ownerProcessID: 998
        )
        let runID = AgentRunID()
        _ = try seedRuntime.recordAuthorizedExternalChild(
            runId: runID,
            threadId: threadID,
            provider: .grok,
            providerInstanceId: "grok-cli",
            model: "grok",
            nodeId: "nested.grok.dead",
            parentRunId: parentRunID,
            parentThreadId: threadID,
            parentCapability: parentCapability,
            childCapability: AgentDelegationCapability.issue(),
            requestedPermissionMode: .supervised,
            ownerProcessID: 999
        )

        vm.refreshSubagentActivity()
        await vm.awaitSubagentActivityRefreshForTesting()

        XCTAssertEqual(vm.subagentActivity.activeCount, 0)
        XCTAssertEqual(vm.subagentActivity.unknownCount, 1)
        XCTAssertEqual(try repository.receipt(runId: runID)?.lifecycleStatus, .unknown)
    }

    func testSubagentActivityIsScopedToSelectedThreadOnly() async throws {
        // WHY: the chrome badge was aggregating every workspace thread's done
        // workers onto empty/new threads. Subagents must be per-thread UI.
        let root = NSTemporaryDirectory() + "rc-subagent-thread-scope-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: root) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: root).run()
        let threads = AgentThreadRepository(db: db)
        let messages = AgentMessageRepository(db: db)
        let runs = AgentRunRepository(db: db)
        let coordinator = AgentRunCoordinator(
            runRepo: runs,
            messageRepo: messages,
            threadRepo: threads,
            providers: [
                .codex: FakeProviderRunner(provider: .codex),
                .claude: FakeProviderRunner(provider: .claude),
                .grok: FakeProviderRunner(provider: .grok)
            ]
        )
        let repository = AgentOrchestrationRepository(db: db)
        let runtime = AgentOrchestrationRuntime(
            repository: repository,
            packageVerification: { true },
            rolloutGate: { true },
            killSwitch: { false },
            processIsAlive: { _ in true }
        )
        let vm = AgentAppViewModel(
            workspaceID: WorkspaceID(),
            cwd: root,
            coordinator: coordinator,
            threadRepo: threads,
            messageRepo: messages,
            orchestrationRuntime: runtime
        )

        vm.createThread(title: "thread-with-subagents")
        let busyThreadID = try XCTUnwrap(vm.selectedThreadId)
        let parentCapability = AgentDelegationCapability.issue()
        let parentRunID = AgentRunID()
        _ = try runtime.recordExternalRoot(
            runId: parentRunID,
            threadId: busyThreadID,
            provider: .claude,
            providerInstanceId: "claude-cli",
            model: "opus",
            permissionMode: .supervised,
            delegationCapabilitySHA256: AgentDelegationCapability.sha256Hex(parentCapability),
            ownerProcessID: 1001
        )
        let childRunID = AgentRunID()
        _ = try runtime.recordAuthorizedExternalChild(
            runId: childRunID,
            threadId: busyThreadID,
            provider: .codex,
            providerInstanceId: "codex-cli",
            model: "gpt",
            nodeId: "busy-worker",
            parentRunId: parentRunID,
            parentThreadId: busyThreadID,
            parentCapability: parentCapability,
            childCapability: AgentDelegationCapability.issue(),
            requestedPermissionMode: .supervised,
            ownerProcessID: 1002
        )
        try runtime.finalizeReceipt(runId: childRunID, status: .completed)

        vm.refreshSubagentActivity()
        await vm.awaitSubagentActivityRefreshForTesting()
        XCTAssertEqual(vm.subagentActivity.doneCount, 1,
                       "selected busy thread must show its own finalized subagent")
        XCTAssertEqual(vm.subagentActivity.done.first?.nodeId, "busy-worker")

        vm.createThread(title: "empty-thread")
        let emptyThreadID = try XCTUnwrap(vm.selectedThreadId)
        XCTAssertNotEqual(emptyThreadID, busyThreadID)
        // createThread/selectThread must rebuild immediately — not wait for the 2s poll.
        XCTAssertTrue(
            vm.subagentActivity.isEmpty,
            "a different/empty selected thread must not inherit sibling subagents"
        )

        vm.selectThread(busyThreadID)
        await vm.awaitSubagentActivityRefreshForTesting()
        XCTAssertEqual(vm.subagentActivity.doneCount, 1,
                       "returning to the busy thread must restore its own subagents only")
        XCTAssertEqual(vm.subagentActivity.done.first?.threadId, busyThreadID)

        // Middleware nested Agent App path: child receipt lands on its own thread
        // but parent-chain attribution must still surface it on the spawner.
        vm.createThread(title: "middleware-child-thread")
        let childThreadID = try XCTUnwrap(vm.selectedThreadId)
        let nestedRunID = AgentRunID()
        _ = try runtime.recordAuthorizedExternalChild(
            runId: nestedRunID,
            threadId: childThreadID,
            provider: .grok,
            providerInstanceId: "grok-cli",
            model: "grok",
            nodeId: "middleware-child",
            parentRunId: parentRunID,
            parentThreadId: busyThreadID,
            parentCapability: parentCapability,
            childCapability: AgentDelegationCapability.issue(),
            requestedPermissionMode: .supervised,
            ownerProcessID: 1003
        )
        try runtime.finalizeReceipt(runId: nestedRunID, status: .completed)

        vm.selectThread(busyThreadID)
        await vm.awaitSubagentActivityRefreshForTesting()
        XCTAssertEqual(
            Set(vm.subagentActivity.done.map(\.nodeId)),
            Set(["busy-worker", "middleware-child"]),
            "spawning thread badge must include parent-chain nested workers on other threads"
        )
        vm.selectThread(emptyThreadID)
        XCTAssertTrue(
            vm.subagentActivity.isEmpty,
            "unrelated empty thread still must not inherit the spawner's nested workers"
        )
    }

    func testSubagentRefreshClearsAfterDeletedSelectionRecovery() async throws {
        // WHY: reloadThreads used to refresh before nil-ing a deleted selection,
        // leaving the badge stuck on the dead thread until the 2s poll.
        let root = NSTemporaryDirectory() + "rc-subagent-deleted-sel-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: root) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: root).run()
        let threads = AgentThreadRepository(db: db)
        let messages = AgentMessageRepository(db: db)
        let runs = AgentRunRepository(db: db)
        let coordinator = AgentRunCoordinator(
            runRepo: runs,
            messageRepo: messages,
            threadRepo: threads,
            providers: [
                .codex: FakeProviderRunner(provider: .codex),
                .claude: FakeProviderRunner(provider: .claude),
                .grok: FakeProviderRunner(provider: .grok)
            ]
        )
        let repository = AgentOrchestrationRepository(db: db)
        let runtime = AgentOrchestrationRuntime(
            repository: repository,
            packageVerification: { true },
            rolloutGate: { true },
            killSwitch: { false },
            processIsAlive: { _ in true }
        )
        let vm = AgentAppViewModel(
            workspaceID: WorkspaceID(),
            cwd: root,
            coordinator: coordinator,
            threadRepo: threads,
            messageRepo: messages,
            orchestrationRuntime: runtime
        )

        vm.createThread(title: "doomed")
        let threadID = try XCTUnwrap(vm.selectedThreadId)
        let parentCapability = AgentDelegationCapability.issue()
        let parentRunID = AgentRunID()
        _ = try runtime.recordExternalRoot(
            runId: parentRunID,
            threadId: threadID,
            provider: .claude,
            providerInstanceId: "claude-cli",
            model: "opus",
            permissionMode: .supervised,
            delegationCapabilitySHA256: AgentDelegationCapability.sha256Hex(parentCapability),
            ownerProcessID: 2001
        )
        let childRunID = AgentRunID()
        _ = try runtime.recordAuthorizedExternalChild(
            runId: childRunID,
            threadId: threadID,
            provider: .codex,
            providerInstanceId: "codex-cli",
            model: "gpt",
            nodeId: "doomed-worker",
            parentRunId: parentRunID,
            parentThreadId: threadID,
            parentCapability: parentCapability,
            childCapability: AgentDelegationCapability.issue(),
            requestedPermissionMode: .supervised,
            ownerProcessID: 2002
        )
        try runtime.finalizeReceipt(runId: childRunID, status: .completed)
        vm.refreshSubagentActivity()
        await vm.awaitSubagentActivityRefreshForTesting()
        XCTAssertEqual(vm.subagentActivity.doneCount, 1)

        try threads.delete(ids: [threadID])
        vm.reloadThreads()
        XCTAssertNil(vm.selectedThreadId)
        XCTAssertTrue(
            vm.subagentActivity.isEmpty,
            "deletion recovery must clear Subagents immediately, not leave the deleted thread's rows"
        )
    }

    func testOffMainSubagentLoadDoesNotOverwriteNewerThreadSelection() async throws {
        // WHY: the new off-main poll may finish after the user switches threads;
        // its old-thread snapshot must not replace the newly selected thread's badge.
        let root = NSTemporaryDirectory() + "rc-subagent-stale-load-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: root) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: root).run()
        let threads = AgentThreadRepository(db: db)
        let messages = AgentMessageRepository(db: db)
        let runs = AgentRunRepository(db: db)
        let coordinator = AgentRunCoordinator(
            runRepo: runs,
            messageRepo: messages,
            threadRepo: threads,
            providers: [
                .codex: FakeProviderRunner(provider: .codex),
                .claude: FakeProviderRunner(provider: .claude),
                .grok: FakeProviderRunner(provider: .grok)
            ]
        )
        let repository = AgentOrchestrationRepository(db: db)
        let runtime = AgentOrchestrationRuntime(
            repository: repository,
            packageVerification: { true },
            rolloutGate: { true },
            killSwitch: { false },
            processIsAlive: { _ in true }
        )
        let vm = AgentAppViewModel(
            workspaceID: WorkspaceID(),
            cwd: root,
            coordinator: coordinator,
            threadRepo: threads,
            messageRepo: messages,
            orchestrationRuntime: runtime
        )

        vm.createThread(title: "old selected thread")
        let oldThreadID = try XCTUnwrap(vm.selectedThreadId)
        let parentRunID = AgentRunID()
        let parentCapability = AgentDelegationCapability.issue()
        _ = try runtime.recordExternalRoot(
            runId: parentRunID,
            threadId: oldThreadID,
            provider: .codex,
            providerInstanceId: "codex-cli",
            model: "gpt",
            permissionMode: .supervised,
            delegationCapabilitySHA256: AgentDelegationCapability.sha256Hex(parentCapability),
            ownerProcessID: getpid()
        )
        let childRunID = AgentRunID()
        _ = try runtime.recordAuthorizedExternalChild(
            runId: childRunID,
            threadId: oldThreadID,
            provider: .grok,
            providerInstanceId: "grok-cli",
            model: "grok",
            nodeId: "late-old-thread-worker",
            parentRunId: parentRunID,
            parentThreadId: oldThreadID,
            parentCapability: parentCapability,
            childCapability: AgentDelegationCapability.issue(),
            requestedPermissionMode: .supervised,
            ownerProcessID: getpid()
        )
        try runtime.finalizeReceipt(runId: childRunID, status: .completed)
        vm.refreshSubagentActivity()
        await vm.awaitSubagentActivityRefreshForTesting()
        XCTAssertEqual(vm.subagentActivity.doneCount, 1)

        let clock = OneShotBlockingClock()
        vm.setClockForTests { clock.now() }
        let load = Task {
            await vm.loadSubagentActivitySnapshotOffMainActor(for: oldThreadID)
        }
        await fulfillment(of: [clock.blocked], timeout: 2)

        vm.createThread(title: "new selected thread")
        let newThreadID = try XCTUnwrap(vm.selectedThreadId)
        XCTAssertNotEqual(newThreadID, oldThreadID)
        XCTAssertTrue(vm.subagentActivity.isEmpty)

        clock.release.signal()
        let lateSnapshot = await load.value
        vm.applySubagentActivity(lateSnapshot, loadedFor: oldThreadID)

        XCTAssertEqual(vm.selectedThreadId, newThreadID)
        XCTAssertTrue(
            vm.subagentActivity.isEmpty,
            "a completed poll for the old thread must not overwrite the newer selection"
        )
    }

    func testNextThreadRestoresLastUserProviderModelAndReasoningChoice() throws {
        let suiteName = "rc-auto-last-selection-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let (first, _, firstRoot) = try fixture(defaults: defaults)
        defer { try? FileManager.default.removeItem(atPath: firstRoot) }
        let chosenUser = AgentRunAsUser(
            generatedUID: "test-agent-user",
            shortName: "agent-user",
            uid: 501,
            gid: 20,
            homePath: "/Users/agent-user",
            fullName: "Agent User"
        )

        XCTAssertTrue(first.setAutoModelRoutingEnabled(false))
        first.setRunAsUser(chosenUser)
        first.setProvider(.claude)
        first.setModel("claude-live")
        first.setReasoningEffort(.max)

        let (next, threads, nextRoot) = try fixture(defaults: defaults)
        defer { try? FileManager.default.removeItem(atPath: nextRoot) }
        next.createThread(title: "inherits explicit choices")
        let thread = try XCTUnwrap(try threads.get(id: try XCTUnwrap(next.selectedThreadId)))

        XCTAssertEqual(thread.effectiveRoutingConfiguration.mode, .manual)
        XCTAssertEqual(thread.runAsUser, chosenUser)
        XCTAssertEqual(thread.provider, .claude)
        XCTAssertEqual(thread.model, "claude-live")
        XCTAssertEqual(thread.reasoningEffort, .max)
    }

    func test_selectThread_disableAuto_updatesRailForCacheFirstReselect() throws {
        // WHY: selectThread now reads the rail instead of SQLite. Disabling Auto
        // used to restore Manual on the VM but leave Auto on the rail row, so a
        // cache-first reselect would put Auto back.
        let (vm, _, root) = try fixture()
        defer { try? FileManager.default.removeItem(atPath: root) }
        vm.createThread(title: "rail-routing")
        XCTAssertTrue(vm.setAutoModelRoutingEnabled(true))
        XCTAssertTrue(vm.setAutoModelRoutingEnabled(false))
        let tid = try XCTUnwrap(vm.selectedThreadId)
        let railRow = try XCTUnwrap(vm.threads.first(where: { $0.id == tid }))
        XCTAssertEqual(
            railRow.effectiveRoutingConfiguration.mode,
            .manual,
            "disabling Auto must update the painted rail row, not only durable storage"
        )
        vm.selectThread(tid)
        XCTAssertTrue(
            vm.lastThreadSelectionUsedRailForTesting,
            "reselect after a routing change must stay on the rail cache"
        )
        XCTAssertEqual(vm.routingMode, .manual,
                       "cache-first reselect must keep the Manual routing just saved")
    }

    func testAutoManualTransitionPersistsAndRestoresFastManualSelection() throws {
        let (vm, threads, root) = try fixture()
        defer {
            try? FileManager.default.removeItem(atPath: root)
            UserDefaults.standard.removePersistentDomain(forName: (root as NSString).lastPathComponent)
        }
        vm.provider = .claude
        vm.providerInstanceId = "claude"
        vm.model = "claude-live"
        vm.reasoningEffort = .max
        vm.serviceTier = .fast
        XCTAssertTrue(vm.setAutoModelRoutingEnabled(false))
        vm.createThread(title: "routing")
        var persistedModes: [AgentRoutingMode] = []
        vm.onThreadConfigPersisted = { persistedModes.append($0.effectiveRoutingConfiguration.mode) }

        XCTAssertTrue(vm.setAutoModelRoutingEnabled(true))
        XCTAssertEqual(vm.routingMode, .auto)
        XCTAssertEqual(try threads.get(id: try XCTUnwrap(vm.selectedThreadId))?.routingConfiguration?.mode, .auto)

        vm.model = "should-not-replace-manual-selection"
        vm.reasoningEffort = .low
        vm.serviceTier = .auto
        XCTAssertTrue(vm.setAutoModelRoutingEnabled(false))

        XCTAssertEqual(vm.routingMode, .manual)
        XCTAssertEqual(vm.provider, .claude)
        XCTAssertEqual(vm.model, "claude-live")
        XCTAssertEqual(vm.reasoningEffort, .max)
        XCTAssertEqual(vm.serviceTier, .fast)
        XCTAssertEqual(persistedModes, [.auto, .manual])
    }

    func testProviderChangedWhileAutoIsOnRemainsSelectedWhenAutoTurnsOff() throws {
        let (vm, threads, root) = try fixture()
        defer { try? FileManager.default.removeItem(atPath: root) }

        XCTAssertTrue(vm.setAutoModelRoutingEnabled(false))
        vm.setProvider(.claude)
        vm.createThread(title: "provider switch while auto")
        XCTAssertTrue(vm.setAutoModelRoutingEnabled(true))

        vm.setProvider(.grok)

        var persisted = try XCTUnwrap(try threads.get(id: try XCTUnwrap(vm.selectedThreadId)))
        XCTAssertEqual(persisted.effectiveRoutingConfiguration.mode, .auto)
        XCTAssertEqual(
            persisted.effectiveRoutingConfiguration.manualSelection.provider,
            .grok,
            "An explicit provider change while Auto is on must replace the manual fallback selection."
        )

        XCTAssertTrue(vm.setAutoModelRoutingEnabled(false))
        persisted = try XCTUnwrap(try threads.get(id: try XCTUnwrap(vm.selectedThreadId)))

        XCTAssertEqual(vm.routingMode, .manual)
        XCTAssertEqual(vm.provider, .grok)
        XCTAssertEqual(vm.model, "grok-live")
        XCTAssertEqual(persisted.provider, .grok)
        XCTAssertEqual(persisted.effectiveRoutingConfiguration.manualSelection.provider, .grok)
    }

    func testPopoverPresentationHidesAllLowerControlsAndRespectsReduceMotion() {
        let manual = AgentModelPopoverPresentation(mode: .manual, reduceMotion: false)
        XCTAssertTrue(manual.showsModelControls)
        XCTAssertTrue(manual.showsReasoningControls)
        XCTAssertTrue(manual.showsServiceTierControls)
        XCTAssertFalse(manual.showsDisclaimer)

        let auto = AgentModelPopoverPresentation(mode: .auto, reduceMotion: false)
        XCTAssertFalse(auto.showsModelControls)
        XCTAssertFalse(auto.showsReasoningControls)
        XCTAssertFalse(auto.showsServiceTierControls)
        XCTAssertTrue(auto.showsDisclaimer)
        XCTAssertEqual(auto.transition, .fadeAndSlide)
        XCTAssertEqual(auto.disclaimer, "Remote Code will automatically orchestrate the model to maximize quality while using the fewest tokens.")
        XCTAssertEqual(AgentModelPopoverPresentation.autoStatus, "Orchestration active")
        XCTAssertTrue(auto.autoToggleEnabled)
        XCTAssertEqual(auto.accessibilityLabel, "Automatic model routing")
        XCTAssertEqual(auto.accessibilityValue, "On")
        XCTAssertEqual(auto.accessibilityHint, "Turns automatic model routing on or off.")

        let loading = AgentModelPopoverPresentation(
            mode: .manual,
            reduceMotion: false,
            autoRoutingLoading: true
        )
        XCTAssertTrue(loading.showsAutoLoadingIndicator)
        XCTAssertFalse(loading.autoToggleEnabled)

        let reduced = AgentModelPopoverPresentation(mode: .auto, reduceMotion: true)
        XCTAssertEqual(reduced.transition, .none)

        let current = AgentModelPopoverPresentation.current(mode: .auto, autoRoutingLoading: true)
        XCTAssertEqual(current.mode, .auto)
        XCTAssertTrue(current.showsDisclaimer)
        XCTAssertTrue(current.showsAutoLoadingIndicator)
        XCTAssertFalse(current.autoToggleEnabled)
    }

    func test_agentAndBotsShareTheSameAutoPopoverChrome() throws {
        // WHY: Desk Auto used to be a header-only fork. Auto-on must paint
        // the same orchestration card from one component, not a second copy.
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let chrome = try String(
            contentsOf: repo.appendingPathComponent("Sources/Surfaces/AgentModelPopover.swift"),
            encoding: .utf8
        )
        let agent = try String(
            contentsOf: repo.appendingPathComponent("Sources/Surfaces/AgentAppSurface.swift"),
            encoding: .utf8
        )
        let bots = try String(
            contentsOf: repo.appendingPathComponent("Sources/AppShell/BotsWindow.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(chrome.contains("struct AgentModelPopoverChrome"))
        XCTAssertTrue(chrome.contains("struct AgentModelAutoRoutingCard"))
        XCTAssertTrue(chrome.contains("agent.model.auto.card"))
        XCTAssertTrue(chrome.contains(AgentModelPopoverPresentation.autoDisclaimer))
        XCTAssertTrue(chrome.contains(AgentModelPopoverPresentation.autoStatus))

        XCTAssertTrue(agent.contains("AgentModelPopoverChrome("))
        XCTAssertFalse(
            agent.contains("private func autoRoutingCard"),
            "Agent App must not keep a private Auto card after the shared chrome exists"
        )
        XCTAssertTrue(bots.contains("AgentModelPopoverChrome("))
        XCTAssertFalse(
            bots.contains(AgentModelPopoverPresentation.autoDisclaimer),
            "Bots Desk must not recopy the Auto card; use AgentModelPopoverChrome"
        )
    }

    func testProviderSnapshotLoadingStateCoversTheWholeStartupLoad() async throws {
        let (vm, _, root) = try fixture()
        defer { try? FileManager.default.removeItem(atPath: root) }
        vm.providerSnapshotLoader = {
            try await Task.sleep(for: .milliseconds(50))
            return []
        }

        let load = Task { await vm.loadProviderSnapshots() }
        await Task.yield()

        XCTAssertTrue(vm.providerSnapshotsLoading)
        await load.value
        XCTAssertFalse(vm.providerSnapshotsLoading)
    }

    /// WHY: with Auto selected and provider/model catalogs still loading, send
    /// must refuse so the user cannot start a turn against incomplete routing
    /// (button disabled + Enter path blocked).
    func test_composerSendBlockedWhileAutoRoutingPrerequisitesLoad() {
        XCTAssertTrue(
            AgentAppViewModel.isComposerSendBlockedByAutoRoutingLoad(
                routingMode: .auto,
                hasSelectedThread: true,
                providerSnapshotsEmpty: true,
                providerSnapshotsLoading: false,
                modelListLoading: false
            )
        )
        XCTAssertTrue(
            AgentAppViewModel.isComposerSendBlockedByAutoRoutingLoad(
                routingMode: .auto,
                hasSelectedThread: true,
                providerSnapshotsEmpty: false,
                providerSnapshotsLoading: true,
                modelListLoading: false
            )
        )
        XCTAssertTrue(
            AgentAppViewModel.isComposerSendBlockedByAutoRoutingLoad(
                routingMode: .auto,
                hasSelectedThread: true,
                providerSnapshotsEmpty: false,
                providerSnapshotsLoading: false,
                modelListLoading: true
            )
        )
        XCTAssertFalse(
            AgentAppViewModel.isComposerSendBlockedByAutoRoutingLoad(
                routingMode: .auto,
                hasSelectedThread: true,
                providerSnapshotsEmpty: false,
                providerSnapshotsLoading: false,
                modelListLoading: false
            ),
            "Auto ready must allow send"
        )
        XCTAssertFalse(
            AgentAppViewModel.isComposerSendBlockedByAutoRoutingLoad(
                routingMode: .manual,
                hasSelectedThread: true,
                providerSnapshotsEmpty: true,
                providerSnapshotsLoading: true,
                modelListLoading: true
            ),
            "manual mode is not gated by Auto loading"
        )
        XCTAssertFalse(
            AgentAppViewModel.isComposerSendBlockedByAutoRoutingLoad(
                routingMode: .auto,
                hasSelectedThread: false,
                providerSnapshotsEmpty: true,
                providerSnapshotsLoading: true,
                modelListLoading: true
            ),
            "no thread selected → Auto pill is not loading against a thread"
        )
    }

    func test_sendWhileAutoLoadingRefusesWithoutStartingProvider() async throws {
        let (vm, _, root) = try fixture()
        defer { try? FileManager.default.removeItem(atPath: root) }

        // Force Auto + incomplete prerequisites with a real selected thread.
        // Empty snapshots (still loading / not seeded) is the same gate the UI
        // uses for the Auto loading pill.
        vm.createThread(title: "auto-loading-send")
        XCTAssertNotNil(vm.selectedThreadId)
        XCTAssertEqual(vm.routingMode, .auto)
        vm.providerSnapshots = []
        vm.modelListLoading = true
        vm.prompt = "oi"

        await vm.send()

        XCTAssertTrue(
            vm.statusMessage.contains("still loading"),
            "expected loading refusal, got: \(vm.statusMessage)"
        )
        XCTAssertNotEqual(vm.status, .running)
        XCTAssertNil(vm.currentRunId)
    }
}

private final class OneShotBlockingClock: @unchecked Sendable {
    let blocked = XCTestExpectation(description: "off-main projection reached clock")
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var shouldBlock = true

    func now() -> Date {
        lock.lock()
        let block = shouldBlock
        shouldBlock = false
        lock.unlock()
        if block {
            blocked.fulfill()
            _ = release.wait(timeout: .now() + 3)
        }
        return Date(timeIntervalSince1970: 1_000)
    }
}
