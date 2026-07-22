import XCTest
import CoreModel
@testable import Persistence
@testable import AgentRuntime
@testable import Surfaces

@MainActor
final class AgentAutoRoutingViewModelTests: XCTestCase {
    private func fixture() throws -> (AgentAppViewModel, AgentThreadRepository, String) {
        let suiteName = "rc-auto-vm-" + UUID().uuidString
        let root = NSTemporaryDirectory() + suiteName
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
            orchestrationRuntime: runtime
        )
        let lastModelStore = AgentLastModelStore(defaults: UserDefaults(suiteName: suiteName)!)
        lastModelStore.remember(model: "claude-live", for: .claude)
        vm.lastModelStore = lastModelStore
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
        XCTAssertEqual(auto.disclaimer, "O Remote Code vai orquestrar automaticamente o modelo para buscar a máxima qualidade usando o mínimo de tokens. Se alguma capacidade não estiver disponível, a rota será degradada de forma explícita.")
        XCTAssertTrue(auto.autoToggleEnabled)
        XCTAssertEqual(auto.accessibilityLabel, "Roteamento automático do modelo")
        XCTAssertEqual(auto.accessibilityValue, "Ativado")
        XCTAssertEqual(auto.accessibilityHint, "Ativa ou desativa o roteamento automático do modelo.")

        let reduced = AgentModelPopoverPresentation(mode: .auto, reduceMotion: true)
        XCTAssertEqual(reduced.transition, .none)
    }
}
