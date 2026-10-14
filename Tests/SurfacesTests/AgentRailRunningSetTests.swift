import XCTest
import Combine
@testable import Surfaces
import CoreModel
import GitTestSupport
@testable import Persistence
@testable import AgentRuntime

/// The Agent App rail rebuilds on every AgentAppViewModel publish (stream
/// ticks, keystrokes). Work it does per pass must not scale with lock
/// acquisitions per thread, and publishes that change nothing must not happen.
@MainActor
final class AgentRailRunningSetTests: XCTestCase {
    private struct Harness {
        let vm: AgentAppViewModel
        let coordinator: AgentRunCoordinator
        let runRepo: AgentRunRepository
        let threads: [AgentThread]
    }

    private func makeHarness(cwd: String? = nil, threadCount: Int = 4) throws -> Harness {
        let tmp = NSTemporaryDirectory() + "rc2-rail-running-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let coordinator = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo,
                                              threadRepo: threadRepo, providers: [:])
        let workspaceID = WorkspaceID()
        var threads: [AgentThread] = []
        for i in 0..<threadCount {
            let thread = AgentThread(workspaceId: workspaceID, title: "t\(i)", provider: .codex,
                                     model: "gpt-5.6-sol", status: .completed)
            try threadRepo.upsert(thread)
            threads.append(thread)
        }
        let vm = AgentAppViewModel(workspaceID: workspaceID, cwd: cwd ?? tmp,
                                   coordinator: coordinator, threadRepo: threadRepo,
                                   messageRepo: messageRepo,
                                   promptHistoryStore: PromptHistoryStore(db: db))
        vm.reloadThreads()
        return Harness(vm: vm, coordinator: coordinator, runRepo: runRepo, threads: threads)
    }

    private func waitAsync(_ desc: String, timeout: TimeInterval = 4, _ cond: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for: \(desc)")
    }

    /// WHY: the rail used to ask `isThreadStartingOrRunning` per thread, taking
    /// the coordinator's global lock once per row on every body pass. The
    /// precomputed set must give every row the exact same running indicator:
    /// tracked (surface-owned) runs, coordinator-owned runs, and LaunchAgent
    /// scheduled runs all count; idle threads do not.
    func test_railRunningSetMatchesPerThreadPredicate() async throws {
        let h = try makeHarness()
        let tracked = h.threads[0], coordinatorOwned = h.threads[1]
        let scheduled = h.threads[2], idle = h.threads[3]

        h.vm.selectThread(tracked.id, markRead: false)
        let live = AgentRun(threadId: tracked.id, provider: .codex, model: "gpt-5.6-sol", status: .running)
        try h.runRepo.upsert(live)
        h.vm.runCoordinator(h.coordinator, didReceive: .providerRuntime(ProviderRuntimeEvent(
            provider: .codex, source: "codex", method: "mcpServer/startupStatus",
            payloadJSON: #"{"server":"remote-code","state":"ready"}"#, receivedAtMs: 1
        )), run: live.id, threadId: tracked.id)
        await waitAsync("surface tracks the live run") { h.vm.isThreadStartingOrRunning(tracked.id) }
        h.coordinator.bindActiveThreadForTesting(threadId: coordinatorOwned.id, runId: AgentRunID())
        h.vm.isScheduledThreadRunning = { $0 == scheduled.id }

        let set = h.vm.startingOrRunningThreadIds(among: h.vm.filteredThreads)
        for thread in h.vm.filteredThreads {
            XCTAssertEqual(set.contains(thread.id), h.vm.isThreadStartingOrRunning(thread.id),
                           "rail row \(thread.title) must show the same running state as before")
        }
        XCTAssertTrue(set.isSuperset(of: [tracked.id, coordinatorOwned.id, scheduled.id]))
        XCTAssertFalse(set.contains(idle.id), "an idle thread must never render as running")
    }

    /// WHY: pins the rail body to the one-lock set; a per-thread predicate in the
    /// body is the O(threads) lock pattern this replaced.
    func test_railBodyUsesPrecomputedRunningSet() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/Surfaces/AgentAppSurface.swift"),
                                encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "let runningThreadIds = "))
        let line = source[start.lowerBound...].prefix(while: { $0 != "\n" })
        XCTAssertEqual(String(line), "let runningThreadIds = vm.startingOrRunningThreadIds(among: vm.filteredThreads)")
    }

    /// WHY: every coalesced run finish reloads the git branch/summary. Writing an
    /// equal value to a @Published property still fires objectWillChange, which
    /// rebuilds the whole AgentAppView (rail + transcript) for nothing.
    func test_unchangedGitBranchAndSummaryDoNotRepublish() async throws {
        let repo = try GitRepoFixture(prefix: "rc2-rail-git")
        defer { repo.cleanup() }
        try repo.commit(file: "a.txt")
        let h = try makeHarness(cwd: repo.path, threadCount: 1)
        await waitAsync("init git load lands") { h.vm.gitBranch == "main" && h.vm.gitSummary != nil }

        var writes = 0
        var bag = Set<AnyCancellable>()
        h.vm.$gitBranch.dropFirst().sink { _ in writes += 1 }.store(in: &bag)
        h.vm.$gitSummary.dropFirst().sink { _ in writes += 1 }.store(in: &bag)
        h.vm.loadGitBranch()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(writes, 0, "an unchanged repo must not republish gitBranch/gitSummary")

        try repo.writeUnstaged(file: "a.txt", content: "changed\n")
        h.vm.loadGitBranch()
        await waitAsync("a real change still lands") { writes == 1 }
        XCTAssertEqual(h.vm.gitBranch, "main")
    }
}
