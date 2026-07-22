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
        }
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
