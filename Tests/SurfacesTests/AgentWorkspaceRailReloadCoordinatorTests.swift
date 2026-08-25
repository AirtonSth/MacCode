import XCTest
import CoreModel
import AgentRuntime
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
