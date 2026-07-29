import XCTest
@testable import Surfaces
import CoreModel
import Persistence
@testable import AgentRuntime

/// Regression coverage for the send-path beachball: catalog / provider snapshot
/// probes must not re-run on every send when a fresh TTL cache exists, and
/// live verification must be callable off the MainActor.
@MainActor
final class AgentAppSendCatalogProbeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "agent.lastModel.byProvider.v1")
        AgentAppViewModel.resetCatalogVerificationCacheForTesting()
    }

    override func tearDown() {
        AgentAppViewModel.resetCatalogVerificationCacheForTesting()
        super.tearDown()
    }

    private func makeVM() throws -> AgentAppViewModel {
        let tmp = NSTemporaryDirectory() + "rc2-send-catalog-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let coord = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [
                .codex: FakeProviderRunner(provider: .codex),
                .claude: FakeProviderRunner(provider: .claude),
                .grok: FakeProviderRunner(provider: .grok),
            ]
        )
        return AgentAppViewModel(
            workspaceID: WorkspaceID(),
            cwd: tmp,
            coordinator: coord,
            threadRepo: threadRepo,
            messageRepo: messageRepo,
            draftRepo: AgentThreadDraftRepository(db: db),
            attachmentStore: AgentAttachmentStore(
                root: URL(fileURLWithPath: tmp).appendingPathComponent("agent-attachments")
            ),
            promptHistoryStore: PromptHistoryStore(db: db)
        )
    }

    private func unavailableCodexSnapshot() -> AgentProviderSnapshot {
        // Empty binary → not installed → selectedProviderCanRun == false.
        // Tagged `.live` so verification skips CLI probes; this test measures
        // loadProviderSnapshots invocation count from send(), not live discovery.
        AgentProviderSnapshotFactory.snapshot(
            provider: .codex,
            models: [AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)],
            binaryPath: "",
            modelDiscoverySource: .live
        )
    }

    private func untaggedCodexSnapshot(models: [AgentModelDescriptor]) -> AgentProviderSnapshot {
        AgentProviderSnapshotFactory.snapshot(
            provider: .codex,
            models: models,
            binaryPath: "/usr/bin/true",
            authenticated: true,
            modelDiscoverySource: nil
        )
    }

    // MARK: - send() at most one snapshot load

    func test_send_loadsProviderSnapshotsAtMostOnceWhenStillUnavailable() async throws {
        // WHY: the pre-fix send path awaited loadProviderSnapshots when the
        // selected snapshot was nil AND again when !selectedProviderCanRun —
        // two full CLI/network probes on the MainActor for one message, which
        // beachballed the app for several seconds. One load per send is enough
        // to report genuine unavailability and restore the draft.
        let vm = try makeVM()
        var loads = 0
        let unavailable = unavailableCodexSnapshot()
        vm.providerSnapshots = []
        vm.provider = .codex
        vm.providerInstanceId = unavailable.id
        vm.providerSnapshotLoader = {
            loads += 1
            return [unavailable]
        }
        vm.prompt = "hello from send catalog probe"

        await vm.send()

        XCTAssertEqual(
            loads,
            1,
            "send must load provider snapshots at most once; a second load after a still-unavailable result is the old beachball path"
        )
        XCTAssertEqual(
            vm.prompt,
            "hello from send catalog probe",
            "composer draft must be restored when the provider remains unavailable"
        )
        XCTAssertFalse(
            vm.statusMessage.isEmpty,
            "genuinely unavailable providers must still surface a reason"
        )
    }

    func test_send_skipsSnapshotReloadWhenFreshCatalogAlreadyRunnable() async throws {
        // WHY: after a successful load, a second send must not re-enter the
        // snapshot loader while ModelListTTLDecision says the cache is fresh.
        let vm = try makeVM()
        var loads = 0
        let runnable = AgentProviderSnapshotFactory.snapshot(
            provider: .codex,
            models: [AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)],
            binaryPath: "/usr/bin/true",
            authenticated: true,
            modelDiscoverySource: .live
        )
        vm.providerSnapshotLoader = {
            loads += 1
            return [runnable]
        }
        vm.provider = .codex
        vm.providerInstanceId = runnable.id
        // First load populates the TTL-stamped cache.
        await vm.loadProviderSnapshots()
        XCTAssertEqual(loads, 1)
        XCTAssertTrue(vm.selectedProviderCanRun)

        vm.prompt = "second send"
        await vm.send()

        XCTAssertEqual(
            loads,
            1,
            "a fresh runnable catalog must not re-trigger the snapshot loader on send"
        )
    }

    // MARK: - verification helper isolation + TTL

    func test_catalogVerification_isCallableOffMainActorAndSkipsLiveProbeOnTTLHit() async throws {
        // WHY: snapshotsWithVerifiedCatalogProvenance used to be an instance
        // method on @MainActor AgentAppViewModel, so every await still resumed
        // under MainActor isolation. It is now nonisolated + TTL-cached; a
        // second call within the window must not invoke the live probe.
        let models = [AgentModelDescriptor(id: "gpt-cache", label: "GPT Cache", provider: .codex)]
        let snapshot = untaggedCodexSnapshot(models: models)
        var liveProbeCalls = 0
        AgentAppViewModel.catalogVerificationLiveProbeForTesting = { _, _, _, _ in
            liveProbeCalls += 1
            return models
        }

        let first = await Task.detached {
            // Non-MainActor caller: would fail to compile / hop if the helper
            // were still MainActor-isolated without a nonisolated surface.
            await AgentAppViewModel.snapshotsWithVerifiedCatalogProvenance(
                [snapshot],
                cwd: "/tmp",
                launchConfig: nil,
                forceRefresh: false,
                now: Date(timeIntervalSinceReferenceDate: 1_000_000)
            )
        }.value
        XCTAssertEqual(liveProbeCalls, 1, "first verification of an untagged row must probe once")
        XCTAssertEqual(first.first?.modelDiscoverySource, .live)
        XCTAssertEqual(AgentAppViewModel.catalogVerificationProbeCountForTesting, 1)

        let second = await Task.detached {
            await AgentAppViewModel.snapshotsWithVerifiedCatalogProvenance(
                [snapshot],
                cwd: "/tmp",
                launchConfig: nil,
                forceRefresh: false,
                // 10s later — well inside ModelListTTLDecision.defaultCatalogTTL (300s)
                now: Date(timeIntervalSinceReferenceDate: 1_000_010)
            )
        }.value
        XCTAssertEqual(
            liveProbeCalls,
            1,
            "TTL hit must reuse the cached catalog instead of re-probing (old path re-probed every send)"
        )
        XCTAssertEqual(AgentAppViewModel.catalogVerificationProbeCountForTesting, 1)
        XCTAssertEqual(second.first?.models.map(\.id), models.map(\.id))
    }

    func test_catalogVerification_forceRefreshBypassesTTL() async throws {
        // WHY: explicit "Refresh model list" must still force a live probe
        // even when the shared catalog TTL has not elapsed.
        let models = [AgentModelDescriptor(id: "gpt-refresh", label: "GPT Refresh", provider: .codex)]
        let snapshot = untaggedCodexSnapshot(models: models)
        var liveProbeCalls = 0
        AgentAppViewModel.catalogVerificationLiveProbeForTesting = { _, _, _, _ in
            liveProbeCalls += 1
            return models
        }
        let t0 = Date(timeIntervalSinceReferenceDate: 2_000_000)
        _ = await AgentAppViewModel.snapshotsWithVerifiedCatalogProvenance(
            [snapshot],
            cwd: "/tmp",
            launchConfig: nil,
            forceRefresh: false,
            now: t0
        )
        _ = await AgentAppViewModel.snapshotsWithVerifiedCatalogProvenance(
            [snapshot],
            cwd: "/tmp",
            launchConfig: nil,
            forceRefresh: true,
            now: t0.addingTimeInterval(1)
        )
        XCTAssertEqual(liveProbeCalls, 2, "forceRefresh must bypass the catalog TTL cache")
    }

    func test_modelListTTLDecision_defaultCatalogTTL_matchesCodexAdapterConvention() {
        // WHY: send-path snapshot reuse and CodexAppServerAdapter.listModels
        // must share the same freshness window so one path cannot thrash the other.
        XCTAssertEqual(ModelListTTLDecision.defaultCatalogTTL, 300)
        let fetched = Date(timeIntervalSinceReferenceDate: 3_000_000)
        XCTAssertFalse(
            ModelListTTLDecision.shouldRefetch(
                lastFetchedAt: fetched,
                ttl: ModelListTTLDecision.defaultCatalogTTL,
                now: fetched.addingTimeInterval(299)
            )
        )
        XCTAssertTrue(
            ModelListTTLDecision.shouldRefetch(
                lastFetchedAt: fetched,
                ttl: ModelListTTLDecision.defaultCatalogTTL,
                now: fetched.addingTimeInterval(300)
            )
        )
    }
}
