import XCTest
@testable import Surfaces
import CoreModel
import Persistence
@testable import AgentRuntime

/// Model-picker cluster fixes (F8-F11, F33-F35): a fallback list must never
/// silently rewrite a pinned model (the built-in defaults are no evidence the
/// model is gone), the picker must say when it is showing built-in defaults,
/// a kept-but-missing pin must be explained instead of silently unchecked,
/// and "Refresh model list" must refresh what the picker actually displays.
@MainActor
final class AgentAppModelPickerFixesTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Isolate from model choices remembered by earlier test runs via
        // AgentLastModelStore.shared (runner-level UserDefaults leak).
        UserDefaults.standard.removeObject(forKey: "agent.lastModel.byProvider.v1")
    }

    private func makeVM() throws -> AgentAppViewModel {
        let tmp = NSTemporaryDirectory() + "rc2-vm-modelpicker-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let coord = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo,
                                        threadRepo: threadRepo,
                                        providers: [.codex: FakeProviderRunner(provider: .codex),
                                                    .claude: FakeProviderRunner(provider: .claude)])
        return AgentAppViewModel(workspaceID: WorkspaceID(), cwd: tmp,
                                 coordinator: coord, threadRepo: threadRepo,
                                 messageRepo: messageRepo,
                                 promptHistoryStore: PromptHistoryStore(db: db))
    }

    private func codexModel(_ id: String) -> AgentModelDescriptor {
        AgentModelDescriptor(id: id, label: id, provider: .codex,
                             supportsReasoning: true, supportsServiceTier: true,
                             supportsCustomModel: true)
    }

    private func claudeModel(_ id: String) -> AgentModelDescriptor {
        AgentModelDescriptor(id: id, label: id, provider: .claude,
                             supportsReasoning: true,
                             supportedReasoningEfforts: AgentReasoningEffort.claudeSupportedCases,
                             supportsCustomModel: true)
    }

    private var claudeAliasTrio: [AgentModelDescriptor] {
        [claudeModel("opus"), claudeModel("sonnet"), claudeModel("haiku")]
    }

    // MARK: F8 + F33 — loadModels must not rewrite a pin against a fallback list

    func test_loadModels_fallbackListNeverRewritesPinnedModel() async throws {
        // F8: a previously live-discovered model that the baked-in list omits
        // must survive a re-fetch that fell back — otherwise a network blip
        // silently downgrades and persists the wrong model for the thread.
        let vm = try makeVM()
        vm.provider = .codex
        vm.model = "gpt-6-preview"
        await vm.loadModels()

        XCTAssertTrue(vm.availableModelsAreFallback,
                      "F33: the VM-local codex list is CodexRunner's baked-in set and must be flagged as a fallback, not presented as live discovery")
        XCTAssertEqual(vm.model, "gpt-6-preview",
                       "F8: a fallback list is no evidence the pinned model is gone — the selection must be kept, not reset to the first baked-in id")
        XCTAssertEqual(vm.selectedModelUnavailableNotice, "gpt-6-preview is not in the current model list",
                       "F9: the kept pin must be explained so the picker does not just show no checked row")
    }

    func test_loadModels_fallbackStillEvictsOtherProvidersModelId() async throws {
        // B8 backstop: keeping the pin never extends to an id that provably
        // belongs to a different provider (e.g. a claude id left behind by a
        // direct provider assignment) — that id can never be right here.
        let vm = try makeVM()
        vm.providerSnapshots = [
            AgentProviderSnapshotFactory.snapshot(provider: .claude, models: [claudeModel("claude-sonnet-4-5")])
        ]
        vm.provider = .codex
        vm.providerInstanceId = "codex-cli"
        vm.model = "claude-sonnet-4-5"
        await vm.loadModels()

        XCTAssertNotEqual(vm.model, "claude-sonnet-4-5",
                          "B8: a stale id from the other provider must not survive loadModels, even when the codex list is a fallback")
        XCTAssertTrue(vm.availableModels.contains { $0.id == vm.model },
                      "the replacement must be a model the picker actually offers")
    }

    func test_loadModels_liveListValidatesAgainstUnionWithSnapshotModels() async throws {
        // F8: the picker displays snapshot rows when present, so a narrower
        // live fetch must validate the pin against the union — resetting a
        // model the picker still visibly offers is a silent rewrite.
        let vm = try makeVM()
        vm.provider = .claude
        vm.providerInstanceId = "claude-cli"
        vm.providerSnapshots = [
            AgentProviderSnapshotFactory.snapshot(
                provider: .claude,
                models: [claudeModel("claude-fable-5"), claudeModel("claude-sonnet-4-5")]
            )
        ]
        vm.model = "claude-fable-5"
        let sonnetOnly = [claudeModel("claude-sonnet-4-5")]
        vm.modelListLoader = { _ in sonnetOnly }
        await vm.loadModels()

        XCTAssertEqual(vm.model, "claude-fable-5",
                       "F8: the snapshot list the picker shows still contains the pin; a narrower live fetch must not silently rewrite it")
    }

    // MARK: F9 — snapshot apply keeps the pin and explains it

    func test_snapshotApply_keepsPinnedModelAndSurfacesUnavailableNotice() async throws {
        // F9: relaunch offline — the alias-only fallback snapshot replaces the
        // live list. The thread's pinned model must survive (it would be
        // persisted and run otherwise) and the mismatch must be explained.
        let vm = try makeVM()
        vm.provider = .claude
        vm.providerInstanceId = "claude-cli"
        vm.model = "claude-fable-5"
        let trio = claudeAliasTrio
        vm.providerSnapshotLoader = { [AgentProviderSnapshotFactory.snapshot(provider: .claude, models: trio)] }
        await vm.loadProviderSnapshots()

        XCTAssertEqual(vm.model, "claude-fable-5",
                       "F9: applying an alias-only fallback snapshot must not swap the pinned model to the first alias")
        XCTAssertEqual(vm.selectedModelUnavailableNotice, "claude-fable-5 is not in the current model list",
                       "the kept pin must be surfaced as missing from the current list, not silently unchecked")
    }

    func test_snapshotApply_fillsEmptySelectionAfterProviderSwitch() async throws {
        // The one legitimate reset: a provider switch clears the model, and
        // the next snapshot apply must fill in a valid selection.
        let vm = try makeVM()
        vm.setProvider(.claude)
        XCTAssertEqual(vm.model, "", "setProvider clears the model before lists load")
        let trio = claudeAliasTrio
        vm.providerSnapshotLoader = { [AgentProviderSnapshotFactory.snapshot(provider: .claude, models: trio)] }
        await vm.loadProviderSnapshots()

        XCTAssertEqual(vm.model, "opus",
                       "an empty selection (post provider switch) must be filled from the snapshot list")
        XCTAssertNil(vm.selectedModelUnavailableNotice,
                     "a selection taken from the list needs no unavailable notice")
    }

    func test_snapshotApply_stillEvictsOtherProvidersModelId() async throws {
        // B8 backstop on the snapshot path: an id that another provider's
        // snapshot proves belongs elsewhere must be replaced, not kept.
        let vm = try makeVM()
        vm.provider = .claude
        vm.providerInstanceId = "claude-cli"
        vm.model = "gpt-5.5"
        let trio = claudeAliasTrio
        let codexSnapshot = AgentProviderSnapshotFactory.snapshot(provider: .codex, models: [codexModel("gpt-5.5")])
        vm.providerSnapshotLoader = {
            [AgentProviderSnapshotFactory.snapshot(provider: .claude, models: trio), codexSnapshot]
        }
        await vm.loadProviderSnapshots()

        XCTAssertEqual(vm.model, "opus",
                       "B8: an id that provably belongs to another provider must not survive the snapshot apply")
    }

    // MARK: F10 — startup path must populate the fallback signal

    func test_startupSnapshotPath_populatesFallbackSignal() async throws {
        // F10: the snapshot pipeline drops the live/fallback signal, so before
        // the fix the "Using built-in defaults" warning and its Refresh row
        // could never appear on the normal startup path.
        let vm = try makeVM()
        let hardcoded = await CodexRunner().listModels()
        vm.providerSnapshotLoader = { [AgentProviderSnapshotFactory.snapshot(provider: .codex, models: hardcoded)] }

        vm.refreshProviderSnapshotsInBackground()

        await waitAsync("startup path surfaces the built-in-defaults signal") {
            vm.availableModelsAreFallback && vm.displayedModelListIsFallback
        }
    }

    func test_fallbackNotice_hiddenWhenSnapshotBringsDifferentLiveList() async throws {
        // F10/F33 guard: the warning describes the rows on screen. Once a
        // snapshot delivers a *different* (live) list, the built-in-defaults
        // warning must clear instead of slandering the live rows.
        let vm = try makeVM()
        vm.provider = .codex
        await vm.loadModels()
        XCTAssertTrue(vm.displayedModelListIsFallback,
                      "with no snapshots, the flagged baked-in fetch is exactly what the picker shows")

        let live = [codexModel("gpt-6-live")]
        // Declare the source: a nil modelDiscoverySource makes
        // snapshotsWithVerifiedCatalogProvenance probe the REAL provider binary
        // to verify the catalog, which is neither hermetic nor this test's point.
        vm.providerSnapshotLoader = { [AgentProviderSnapshotFactory.snapshot(
            provider: .codex, models: live, modelDiscoverySource: .live
        )] }
        await vm.loadProviderSnapshots()

        XCTAssertFalse(vm.availableModelsAreFallback,
                       "a snapshot bringing a different list is live discovery — the fetch flag must clear")
        XCTAssertFalse(vm.displayedModelListIsFallback,
                       "a live snapshot list must not carry the built-in-defaults warning")
    }

    // MARK: F11 — Refresh must reload what the picker displays

    func test_refreshModelList_reloadsSnapshotsAndModels() async throws {
        // F11: the picker rows come from provider snapshots; a Refresh that
        // only reloads availableModels changes nothing the user can see.
        let vm = try makeVM()
        vm.provider = .codex
        var snapshotLoads = 0
        var modelLoads = 0
        let live = [codexModel("gpt-6-live")]
        vm.providerSnapshotLoader = {
            snapshotLoads += 1
            return [AgentProviderSnapshotFactory.snapshot(provider: .codex, models: live)]
        }
        vm.modelListLoader = { _ in
            modelLoads += 1
            return live
        }

        await vm.refreshModelList()

        XCTAssertEqual(snapshotLoads, 1,
                       "F11: Refresh must reload the provider snapshots — the rows the picker actually shows")
        XCTAssertEqual(modelLoads, 1,
                       "F11: Refresh must also re-run the VM's own model fetch so the fallback signal is current")
    }

    // MARK: F34 — effort rows carry descriptions

    func test_reasoningEffortPickerHelp_distinguishesUltracode() {
        XCTAssertEqual(AgentReasoningEffort.ultracode.pickerHelpText,
                       "Extra High effort + autonomous workflow orchestration",
                       "F34: Ultracode must say it adds workflow orchestration on top of Extra High effort — the name alone does not")
        XCTAssertNotEqual(AgentReasoningEffort.max.pickerHelpText,
                          AgentReasoningEffort.ultracode.pickerHelpText,
                          "Max and Ultracode must be distinguishable before selection")
        for effort in AgentReasoningEffort.claudeSupportedCases {
            XCTAssertFalse(effort.pickerHelpText.isEmpty,
                           "every effort row the picker offers needs a tooltip: \(effort)")
        }
    }

    private func waitAsync(_ desc: String, timeout: TimeInterval = 6, _ cond: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(cond(), "timed out waiting for: \(desc)")
    }
}
