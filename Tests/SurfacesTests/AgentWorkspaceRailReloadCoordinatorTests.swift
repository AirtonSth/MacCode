import XCTest
import CoreModel
@testable import AgentRuntime
@testable import Persistence
@testable import Surfaces

@MainActor
final class AgentWorkspaceRailReloadCoordinatorTests: XCTestCase {
    /// Every workspace used to own a repeating poll task. With many restored
    /// workspaces those tasks scanned the same receipt store concurrently every
    /// two seconds, contending on its cross-process mutex and sustaining CPU use
    /// while the user scrolled. One shared loop serializes complete poll rounds.
    func test_subagentPollingUsesOneSharedNonOverlappingLoop() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/Surfaces/AgentWorkspaceRailReloadCoordinator.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("private var subagentPollTask: Task<Void, Never>?"))
        XCTAssertFalse(
            source.contains("subagentPollTasks: [WorkspaceID: Task<Void, Never>]"),
            "workspace-owned repeating tasks can overlap receipt scans and starve UI work"
        )
        XCTAssertTrue(source.contains("loadSubagentActivitySnapshotsOffMainActor"))
        XCTAssertFalse(
            source.contains("for workspaceID in workspaceIDs"),
            "one receipt-store scan must serve the complete round instead of rescanning once per workspace"
        )
        XCTAssertFalse(
            source.contains("subagentPollTask?.cancel()"),
            "membership churn must not cancel and restart a poll while its detached receipt read is still finishing"
        )
        XCTAssertTrue(source.contains("defer { self?.subagentPollTask = nil }"))
        XCTAssertTrue(
            source.contains("guard self.hasSubagentPollMembers else { return }"),
            "an empty coordinator must stop before another receipt-store poll round"
        )
        XCTAssertTrue(
            source.contains("viewModel.selectedThreadRunIsStartingOrRunning || viewModel.subagentActivity.isLive"),
            "completed idle threads are refreshed by lifecycle events and must not rescan the receipt store forever"
        )
    }

    func test_registeredMembersShareOneWorkspaceReadAndKeepSelectionIdentity() async throws {
        let root = NSTemporaryDirectory() + "rc-rail-refresh-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: root).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let runCoordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [:]
        )
        let workspaceID = WorkspaceID()
        var firstThread = AgentThread(workspaceId: workspaceID, title: "First", provider: .codex, model: "gpt-5")
        firstThread.hasUnread = true
        let secondThread = AgentThread(workspaceId: workspaceID, title: "Second", provider: .codex, model: "gpt-5")
        try threadRepo.upsert(firstThread)
        try threadRepo.upsert(secondThread)
        let first = AgentAppViewModel(
            workspaceID: workspaceID,
            cwd: root,
            coordinator: runCoordinator,
            threadRepo: threadRepo,
            messageRepo: messageRepo
        )
        let second = AgentAppViewModel(
            workspaceID: workspaceID,
            cwd: root,
            coordinator: runCoordinator,
            threadRepo: threadRepo,
            messageRepo: messageRepo
        )
        first.selectThread(firstThread.id, markRead: false)
        second.selectThread(secondThread.id, markRead: false)
        XCTAssertEqual(first.selectedThreadId, firstThread.id)
        XCTAssertEqual(second.selectedThreadId, secondThread.id)
        var markReadCalls = 0
        first.markThreadRead = { _ in markReadCalls += 1 }
        second.markThreadRead = { _ in markReadCalls += 1 }

        var readCount = 0
        let coordinator = AgentWorkspaceRailReloadCoordinator(
            subagentPollNanoseconds: 1,
            hasMembers: { false },
            sleep: { _ in },
            pollRound: {},
            railSnapshotLoad: { _ in
                readCount += 1
                return AgentWorkspaceRailReloadCoordinator.RailSnapshot(
                    workspaceID: workspaceID,
                    threads: [firstThread, secondThread],
                    prunedThreadIDs: []
                )
            }
        )
        coordinator.debounceNanoseconds = 0
        coordinator.register(first)
        coordinator.register(second)
        defer {
            coordinator.unregister(first)
            coordinator.unregister(second)
            first.dispose()
            second.dispose()
        }

        coordinator.requestCoalescedReload(workspaceID: workspaceID)
        for _ in 0..<1_000 {
            if readCount == 1 && first.threads.count == 2 && second.threads.count == 2 { break }
            await Task.yield()
        }
        XCTAssertEqual(readCount, 1,
                       "one workspace snapshot read must serve every registered Agent surface")
        XCTAssertEqual(first.threads.map(\.id), [firstThread.id, secondThread.id])
        XCTAssertEqual(second.threads.map(\.id), [firstThread.id, secondThread.id])
        XCTAssertEqual(first.selectedThreadId, firstThread.id,
                       "rail fan-out must preserve the first surface's selected identity")
        XCTAssertEqual(second.selectedThreadId, secondThread.id,
                       "rail fan-out must preserve the second surface's selected identity")
        XCTAssertEqual(markReadCalls, 0,
                       "rail fan-out must preserve read state instead of marking selected threads read")
        XCTAssertTrue(try threadRepo.get(id: firstThread.id)?.hasUnread == true,
                      "the persisted selected thread must remain unread after fan-out")
    }

    func test_benchmarkEmptyMembershipPollTicks() async {
        let fixture = PollFixture()
        let coordinator = AgentWorkspaceRailReloadCoordinator(
            subagentPollNanoseconds: 2_000_000_000,
            hasMembers: { fixture.hasMembers },
            sleep: { _ in await fixture.clock.sleep() },
            pollRound: { fixture.roundCount += 1 }
        )
        var raw: [Int] = []
        var wakeRaw: [Int] = []

        for _ in 0..<7 {
            fixture.hasMembers = true
            coordinator.reconcileSubagentPollForTesting()
            await waitUntil { fixture.clock.waiterCount == 1 }

            fixture.hasMembers = false
            coordinator.reconcileSubagentPollForTesting()
            let start = fixture.roundCount
            var wakeCount = 0
            for _ in 0..<30 {
                await waitUntil {
                    fixture.clock.waiterCount == 1 || !coordinator.subagentPollIsRunningForTesting
                }
                guard coordinator.subagentPollIsRunningForTesting else { break }
                fixture.clock.advanceOne()
                wakeCount += 1
                await waitUntil {
                    fixture.clock.waiterCount == 1 || !coordinator.subagentPollIsRunningForTesting
                }
            }
            raw.append(fixture.roundCount - start)
            wakeRaw.append(wakeCount)
        }

        let warmup = Array(raw.prefix(2))
        let samples = Array(raw.dropFirst(2))
        let median = samples.sorted()[samples.count / 2]
        let wakeWarmup = Array(wakeRaw.prefix(2))
        let wakeSamples = Array(wakeRaw.dropFirst(2))
        let wakeMedian = wakeSamples.sorted()[wakeSamples.count / 2]
        print(
            "RAIL_POLL_BENCH rounds_warmup=\(warmup) rounds_samples=\(samples) "
                + "rounds_median=\(median) wakes_warmup=\(wakeWarmup) "
                + "wakes_samples=\(wakeSamples) wakes_median=\(wakeMedian) per_60s"
        )
        XCTAssertEqual(warmup, [0, 0])
        XCTAssertEqual(samples, [0, 0, 0, 0, 0])
        XCTAssertEqual(median, 0)
        XCTAssertEqual(wakeWarmup, [1, 1])
        XCTAssertEqual(wakeSamples, [1, 1, 1, 1, 1])
        XCTAssertEqual(wakeMedian, 1)

        if coordinator.subagentPollIsRunningForTesting {
            coordinator.cancelSubagentPollForTesting()
            fixture.clock.advanceOne()
            await waitUntil { !coordinator.subagentPollIsRunningForTesting }
        }
    }

    func test_applyRailSnapshot_doesNotDecodeReceiptsOnMainActor() async throws {
        // WHY: the freeze-class CPU diag was applyRailSnapshot →
        // refreshSubagentActivity → JSONDecoder of admission receipts on
        // MainActor. The spy is the real `activityReceipts` entry, not a
        // counter that never increments.
        let root = NSTemporaryDirectory() + "rc-rail-offmain-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: root).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let runCoordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
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
        let workspaceID = WorkspaceID()
        let vm = AgentAppViewModel(
            workspaceID: workspaceID,
            cwd: root,
            coordinator: runCoordinator,
            threadRepo: threadRepo,
            messageRepo: messageRepo,
            orchestrationRuntime: runtime
        )
        defer { vm.dispose() }
        vm.createThread(title: "Live")
        await vm.waitForSelectThreadHydrationForTesting()
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
            delegationCapabilitySHA256: AgentDelegationCapability.sha256Hex(parentCapability),
            ownerProcessID: 998
        )
        _ = try seedRuntime.recordAuthorizedExternalChild(
            runId: AgentRunID(),
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
        await vm.awaitSubagentActivityRefreshForTesting()
        runtime.activityReceiptsThreadProbeForTesting.reset()

        let thread = try XCTUnwrap(try threadRepo.get(id: threadID))
        vm.applyRailSnapshot(
            AgentWorkspaceRailReloadCoordinator.RailSnapshot(
                workspaceID: workspaceID,
                threads: [thread],
                prunedThreadIDs: []
            )
        )
        XCTAssertEqual(
            runtime.activityReceiptsThreadProbeForTesting.mainThreadCallCount,
            0,
            "rail apply must not decode orchestration receipts on the MainActor"
        )
        await vm.awaitSubagentActivityRefreshForTesting()
        XCTAssertEqual(
            runtime.activityReceiptsThreadProbeForTesting.mainThreadCallCount,
            0,
            "the winning off-main load must still not decode on the MainActor"
        )
        XCTAssertGreaterThan(
            runtime.activityReceiptsThreadProbeForTesting.backgroundCallCount,
            0,
            "the winning load must actually decode receipts off-main"
        )
        XCTAssertEqual(vm.subagentActivity.activeCount, 0)
        XCTAssertEqual(vm.subagentActivity.unknownCount, 1,
                       "eventual badge must match the durable dead-child receipt")
    }

    func test_applyRailSnapshot_doesNotReadFirstUserMessageOnMainActor() async throws {
        // WHY: applyRailSnapshot used to run placeholder title repair (SQLite
        // LIMIT 1 + upsert) on MainActor. That is the same hang_breach class as
        // receipt JSON decode — rail apply must stay a UI mutation.
        let root = NSTemporaryDirectory() + "rc-rail-title-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: root).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let runCoordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [:]
        )
        let workspaceID = WorkspaceID()
        let old = Date(timeIntervalSince1970: 1_000_000)
        var thread = AgentThread(
            workspaceId: workspaceID,
            title: AgentThreadTitle.defaultTitle,
            provider: .codex,
            model: "gpt-5"
        )
        thread.updatedAt = old
        let vm = AgentAppViewModel(
            workspaceID: workspaceID,
            cwd: root,
            coordinator: runCoordinator,
            threadRepo: threadRepo,
            messageRepo: messageRepo
        )
        defer { vm.dispose() }
        try threadRepo.upsert(thread)
        try messageRepo.append(AgentMessage(threadId: thread.id, role: .user, content: "Implement the parser"))
        vm.titleRepairStoreIOProbeForTesting.reset()
        vm.applyRailSnapshot(
            AgentWorkspaceRailReloadCoordinator.RailSnapshot(
                workspaceID: workspaceID,
                threads: [thread],
                prunedThreadIDs: []
            )
        )
        XCTAssertEqual(
            vm.titleRepairStoreIOProbeForTesting.mainThreadCallCount,
            0,
            "rail apply must not read firstUserMessage on the MainActor"
        )
        await vm.awaitTitleRepairForTesting()
        XCTAssertEqual(
            vm.titleRepairStoreIOProbeForTesting.mainThreadCallCount,
            0,
            "the winning title repair must still not read SQLite on the MainActor"
        )
        XCTAssertGreaterThan(
            vm.titleRepairStoreIOProbeForTesting.backgroundCallCount,
            0,
            "title repair must actually hit firstUserMessage off-main"
        )
        let repaired = try XCTUnwrap(vm.threads.first)
        XCTAssertFalse(AgentThreadTitle.isPlaceholder(repaired.title))
        XCTAssertEqual(repaired.updatedAt.timeIntervalSince1970, old.timeIntervalSince1970, accuracy: 0.001)
    }

    func test_applyRailSnapshot_doesNotCallDurableActiveRunOnMainActor() async throws {
        // WHY: pruneStaleRunThreadProjections used durableActiveRun (SQLite)
        // on MainActor during every rail apply.
        let root = NSTemporaryDirectory() + "rc-rail-prune-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: root).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let runCoordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [:]
        )
        let workspaceID = WorkspaceID()
        let thread = AgentThread(
            workspaceId: workspaceID,
            title: "Live",
            provider: .codex,
            model: "gpt-5"
        )
        try threadRepo.upsert(thread)
        let vm = AgentAppViewModel(
            workspaceID: workspaceID,
            cwd: root,
            coordinator: runCoordinator,
            threadRepo: threadRepo,
            messageRepo: messageRepo
        )
        defer { vm.dispose() }
        let staleRun = AgentRunID()
        vm.seedRunThreadProjectionForTesting(runId: staleRun, threadId: thread.id)
        runCoordinator.durableActiveRunThreadProbeForTesting.reset()
        vm.applyRailSnapshot(
            AgentWorkspaceRailReloadCoordinator.RailSnapshot(
                workspaceID: workspaceID,
                threads: [thread],
                prunedThreadIDs: []
            )
        )
        XCTAssertEqual(
            runCoordinator.durableActiveRunThreadProbeForTesting.mainThreadCallCount,
            0,
            "rail apply must not query durableActiveRun on the MainActor"
        )
        await vm.awaitPruneStaleRunProjectionsForTesting()
        XCTAssertEqual(
            runCoordinator.durableActiveRunThreadProbeForTesting.mainThreadCallCount,
            0,
            "the winning prune must still not query durableActiveRun on the MainActor"
        )
        XCTAssertGreaterThan(
            runCoordinator.durableActiveRunThreadProbeForTesting.backgroundCallCount,
            0,
            "prune must actually consult durableActiveRun off-main"
        )
        XCTAssertNil(vm.trackedRunIdForTesting(thread.id))
    }

    func test_titleRepair_doesNotClobberPersistThreadConfigFields() async throws {
        // WHY: off-main repair used to upsert the captured AgentThread snapshot
        // (status/unread/routing/updatedAt) before the generation check. A
        // persistThreadConfig that landed during firstUserMessage was clobbered.
        let root = NSTemporaryDirectory() + "rc-rail-title-race-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: root).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let runCoordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [:]
        )
        let workspaceID = WorkspaceID()
        let old = Date(timeIntervalSince1970: 1_000_000)
        var thread = AgentThread(
            workspaceId: workspaceID,
            title: AgentThreadTitle.defaultTitle,
            provider: .codex,
            model: "gpt-5"
        )
        thread.updatedAt = old
        thread.hasUnread = true
        let vm = AgentAppViewModel(
            workspaceID: workspaceID,
            cwd: root,
            coordinator: runCoordinator,
            threadRepo: threadRepo,
            messageRepo: messageRepo
        )
        defer { vm.dispose() }
        try threadRepo.upsert(thread)
        try messageRepo.append(AgentMessage(threadId: thread.id, role: .user, content: "Implement the parser"))
        let gate = AsyncResumeGate()
        vm.titleRepairBeforeFetchForTesting = { await gate.wait() }
        vm.applyRailSnapshot(
            AgentWorkspaceRailReloadCoordinator.RailSnapshot(
                workspaceID: workspaceID,
                threads: [thread],
                prunedThreadIDs: []
            )
        )
        vm.selectThread(thread.id, markRead: false)
        vm.model = "o4-mini"
        vm.permissionMode = .fullAccess
        XCTAssertTrue(vm.persistThreadConfig())
        let afterConfig = try XCTUnwrap(try threadRepo.get(id: thread.id))
        XCTAssertEqual(afterConfig.model, "o4-mini")
        XCTAssertEqual(afterConfig.permissionMode, .fullAccess)
        XCTAssertNotEqual(
            afterConfig.updatedAt.timeIntervalSince1970,
            old.timeIntervalSince1970,
            accuracy: 0.001
        )
        gate.open()
        await vm.awaitTitleRepairForTesting()
        let ui = try XCTUnwrap(vm.threads.first)
        XCTAssertFalse(AgentThreadTitle.isPlaceholder(ui.title))
        XCTAssertEqual(ui.model, afterConfig.model)
        XCTAssertEqual(ui.permissionMode, afterConfig.permissionMode)
        XCTAssertEqual(ui.hasUnread, afterConfig.hasUnread)
        XCTAssertEqual(ui.status, afterConfig.status)
        XCTAssertEqual(
            ui.updatedAt.timeIntervalSince1970,
            afterConfig.updatedAt.timeIntervalSince1970,
            accuracy: 1,
            "SQLite stores updated_at at second precision; repair must not revert persistThreadConfig's clock"
        )
        let durable = try XCTUnwrap(try threadRepo.get(id: thread.id))
        XCTAssertEqual(durable.title, ui.title)
        XCTAssertEqual(durable.model, afterConfig.model)
        XCTAssertEqual(durable.permissionMode, afterConfig.permissionMode)
        XCTAssertEqual(durable.hasUnread, afterConfig.hasUnread)
        XCTAssertEqual(durable.status, afterConfig.status)
        XCTAssertEqual(durable.updatedAt.timeIntervalSince1970, afterConfig.updatedAt.timeIntervalSince1970, accuracy: 0.001)
    }

    func test_prune_keepsRunStartedDuringDurableLookup() async throws {
        // WHY: prune scheduled against a stale projection must not clear
        // runThreads if startRun bound that runId before durableActiveRun returned.
        let root = NSTemporaryDirectory() + "rc-rail-prune-race-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: root).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let runCoordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [:]
        )
        let workspaceID = WorkspaceID()
        let thread = AgentThread(
            workspaceId: workspaceID,
            title: "Live",
            provider: .codex,
            model: "gpt-5"
        )
        try threadRepo.upsert(thread)
        let vm = AgentAppViewModel(
            workspaceID: workspaceID,
            cwd: root,
            coordinator: runCoordinator,
            threadRepo: threadRepo,
            messageRepo: messageRepo
        )
        defer { vm.dispose() }
        let liveRun = AgentRunID()
        vm.seedRunThreadProjectionForTesting(runId: liveRun, threadId: thread.id)
        let gate = AsyncResumeGate()
        vm.pruneBeforeDurableLookupForTesting = { await gate.wait() }
        vm.applyRailSnapshot(
            AgentWorkspaceRailReloadCoordinator.RailSnapshot(
                workspaceID: workspaceID,
                threads: [thread],
                prunedThreadIDs: []
            )
        )
        runCoordinator.bindActiveThreadForTesting(threadId: thread.id, runId: liveRun)
        gate.open()
        await vm.awaitPruneStaleRunProjectionsForTesting()
        XCTAssertEqual(vm.trackedRunIdForTesting(thread.id), liveRun)
        XCTAssertEqual(runCoordinator.activeRunId(threadId: thread.id), liveRun)
    }

    func test_prune_emptyStillMaybeLiveCancelsInFlightClear() async throws {
        // WHY: an apply whose projections all match in-memory activeRunId used
        // to return without bumping pruneGeneration, so an older prune still
        // applied and wiped the live spinner.
        let root = NSTemporaryDirectory() + "rc-rail-prune-cancel-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: root).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let runCoordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [:]
        )
        let workspaceID = WorkspaceID()
        let thread = AgentThread(
            workspaceId: workspaceID,
            title: "Live",
            provider: .codex,
            model: "gpt-5"
        )
        try threadRepo.upsert(thread)
        let vm = AgentAppViewModel(
            workspaceID: workspaceID,
            cwd: root,
            coordinator: runCoordinator,
            threadRepo: threadRepo,
            messageRepo: messageRepo
        )
        defer { vm.dispose() }
        let staleRun = AgentRunID()
        vm.seedRunThreadProjectionForTesting(runId: staleRun, threadId: thread.id)
        let gate = AsyncResumeGate()
        vm.pruneBeforeDurableLookupForTesting = { await gate.wait() }
        vm.applyRailSnapshot(
            AgentWorkspaceRailReloadCoordinator.RailSnapshot(
                workspaceID: workspaceID,
                threads: [thread],
                prunedThreadIDs: []
            )
        )
        let liveRun = AgentRunID()
        vm.clearRunThreadProjectionsForTesting()
        vm.seedRunThreadProjectionForTesting(runId: liveRun, threadId: thread.id)
        runCoordinator.bindActiveThreadForTesting(threadId: thread.id, runId: liveRun)
        vm.pruneBeforeDurableLookupForTesting = nil
        vm.applyRailSnapshot(
            AgentWorkspaceRailReloadCoordinator.RailSnapshot(
                workspaceID: workspaceID,
                threads: [thread],
                prunedThreadIDs: []
            )
        )
        gate.open()
        await vm.awaitPruneStaleRunProjectionsForTesting()
        XCTAssertEqual(vm.trackedRunIdForTesting(thread.id), liveRun)
        XCTAssertEqual(runCoordinator.activeRunId(threadId: thread.id), liveRun)
    }

    func test_subagentRefresh_rejectsStaleThreadResult() async throws {
        // WHY: rapid A→B must not let the slower A's receipt snapshot overwrite B.
        let root = NSTemporaryDirectory() + "rc-rail-ab-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: root).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let runCoordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [:]
        )
        let workspaceID = WorkspaceID()
        let threadA = AgentThread(workspaceId: workspaceID, title: "A", provider: .codex, model: "gpt-5")
        let threadB = AgentThread(workspaceId: workspaceID, title: "B", provider: .codex, model: "gpt-5")
        try threadRepo.upsert(threadA)
        try threadRepo.upsert(threadB)
        let vm = AgentAppViewModel(
            workspaceID: workspaceID,
            cwd: root,
            coordinator: runCoordinator,
            threadRepo: threadRepo,
            messageRepo: messageRepo
        )
        defer { vm.dispose() }
        vm.selectThread(threadA.id, markRead: false)
        let staleA = SubagentActivitySnapshot(
            active: [],
            done: [],
            unknown: [],
            completedBound: SubagentActivityProjection.defaultCompletedBound + 7
        )
        vm.selectThread(threadB.id, markRead: false)
        vm.applySubagentActivity(staleA, loadedFor: threadA.id)
        XCTAssertNotEqual(
            vm.subagentActivity.completedBound,
            staleA.completedBound,
            "a snapshot loaded for thread A must not publish after the user moved to B"
        )
        let liveB = SubagentActivitySnapshot(
            active: [],
            done: [],
            unknown: [],
            completedBound: SubagentActivityProjection.defaultCompletedBound + 3
        )
        vm.applySubagentActivity(liveB, loadedFor: threadB.id)
        XCTAssertEqual(vm.subagentActivity.completedBound, liveB.completedBound)
    }

    func test_reRegisterRestartsWithinOnePollCadence() async {
        let fixture = PollFixture()
        let coordinator = AgentWorkspaceRailReloadCoordinator(
            subagentPollNanoseconds: 2_000_000_000,
            hasMembers: { fixture.hasMembers },
            sleep: { _ in await fixture.clock.sleep() },
            pollRound: { fixture.roundCount += 1 }
        )

        coordinator.reconcileSubagentPollForTesting()
        await waitUntil { fixture.clock.waiterCount == 1 }
        fixture.hasMembers = false
        coordinator.reconcileSubagentPollForTesting()
        fixture.clock.advanceOne()
        await waitUntil { !coordinator.subagentPollIsRunningForTesting }
        XCTAssertEqual(fixture.roundCount, 0)

        fixture.hasMembers = true
        coordinator.reconcileSubagentPollForTesting()
        await waitUntil { fixture.clock.waiterCount == 1 }
        fixture.clock.advanceOne()
        await waitUntil { fixture.roundCount == 1 && fixture.clock.waiterCount == 1 }
        XCTAssertTrue(coordinator.subagentPollIsRunningForTesting)

        coordinator.cancelSubagentPollForTesting()
        fixture.clock.advanceOne()
        await waitUntil { !coordinator.subagentPollIsRunningForTesting }
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("condition did not become true", file: file, line: line)
    }
}

@MainActor
private final class PollFixture {
    let clock = ManualPollClock()
    var hasMembers = true
    var roundCount = 0
}

private final class AsyncResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var opened = false

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if opened {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        opened = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume() }
    }
}

@MainActor
private final class ManualPollClock {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var waiterCount: Int { waiters.count }

    func sleep() async {
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func advanceOne() {
        precondition(!waiters.isEmpty)
        waiters.removeFirst().resume()
    }
}
