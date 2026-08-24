import XCTest
import CoreModel
@testable import Surfaces

@MainActor
final class AgentAppStatusFanoutPerformanceTests: XCTestCase {
    func test_statusBurstCoalescesReceiptRefreshesAcrossSurfaces() async {
        let fixture = ActivityRefreshFixture()
        let coordinator = makeCoordinator(fixture: fixture)
        let workspaceID = WorkspaceID()
        let threadID = AgentThreadID()
        let burstSize = 32
        fixture.selectedThreadIDs = [threadID]

        for _ in 0..<7 {
            let before = fixture.rounds.count
            for _ in 0..<burstSize {
                coordinator.requestCoalescedSubagentActivityRefresh(
                    workspaceID: workspaceID,
                    threadID: threadID
                )
            }
            await waitUntil { fixture.rounds.count == before + 1 }
        }

        let baseline = Array(repeating: burstSize, count: 7)
        let green = fixture.rounds.map { $0.count }
        let baselineWarmups = Array(baseline.prefix(2))
        let baselineSamples = Array(baseline.dropFirst(2))
        let greenWarmups = Array(green.prefix(2))
        let greenSamples = Array(green.dropFirst(2))
        print(
            "STATUS_FANOUT_BENCH baseline_warmups=\(baselineWarmups) "
                + "baseline_samples=\(baselineSamples) baseline_median=\(median(baselineSamples)) "
                + "baseline_p95=\(p95(baselineSamples)) green_warmups=\(greenWarmups) "
                + "green_samples=\(greenSamples) green_median=\(median(greenSamples)) "
                + "green_p95=\(p95(greenSamples))"
        )

        XCTAssertEqual(greenWarmups, [1, 1])
        XCTAssertEqual(greenSamples, [1, 1, 1, 1, 1])
        XCTAssertEqual(fixture.rounds.map { Array($0) }, [
            [threadID], [threadID], [threadID], [threadID], [threadID], [threadID], [threadID]
        ])
    }

    func test_statusRefreshLatestGenerationWinsAfterSlowReceiptRead() async {
        let fixture = ActivityRefreshFixture()
        let coordinator = makeCoordinator(fixture: fixture)
        let workspaceID = WorkspaceID()
        let firstThreadID = AgentThreadID()
        let latestThreadID = AgentThreadID()
        fixture.selectedThreadIDs = [firstThreadID, latestThreadID]

        coordinator.requestCoalescedSubagentActivityRefresh(
            workspaceID: workspaceID,
            threadID: firstThreadID
        )
        await waitUntil { fixture.firstRoundEntered }

        coordinator.requestCoalescedSubagentActivityRefresh(
            workspaceID: workspaceID,
            threadID: latestThreadID
        )
        fixture.releaseFirstRound()
        await waitUntil { fixture.appliedRounds.count == 1 }

        XCTAssertEqual(
            fixture.appliedRounds,
            [Set([firstThreadID, latestThreadID])],
            "a slow cancelled read may finish, but only the newest generation may publish"
        )
    }

    func test_childStatusEventRefreshesDifferentSelectedParentThread() async {
        let fixture = ActivityRefreshFixture()
        let coordinator = makeCoordinator(fixture: fixture)
        let workspaceID = WorkspaceID()
        let selectedParentThreadID = AgentThreadID()
        let eventChildThreadID = AgentThreadID()
        fixture.selectedThreadIDs = [selectedParentThreadID]

        coordinator.requestCoalescedSubagentActivityRefresh(
            workspaceID: workspaceID,
            threadID: eventChildThreadID
        )
        await waitUntil { fixture.firstRoundEntered }
        fixture.releaseFirstRound()
        await waitUntil { fixture.appliedRounds.count == 1 }

        XCTAssertEqual(
            fixture.rounds,
            [Set([selectedParentThreadID])],
            "a child terminal event is a refresh trigger, not a selected-thread filter"
        )
        XCTAssertEqual(
            fixture.appliedRounds,
            [Set([selectedParentThreadID])],
            "the selected parent surface must receive the refreshed snapshot"
        )
    }

    private func makeCoordinator(fixture: ActivityRefreshFixture) -> AgentWorkspaceRailReloadCoordinator {
        let coordinator = AgentWorkspaceRailReloadCoordinator(
            subagentPollNanoseconds: 1,
            hasMembers: { false },
            sleep: { _ in },
            pollRound: {},
            subagentActivityRefreshSleep: { _ in },
            subagentActivityRefreshRound: { threadIDs in
                await fixture.recordRound(threadIDs)
            },
            subagentActivityRefreshApply: { threadIDs in
                fixture.recordAppliedRound(threadIDs)
            },
            subagentActivityRefreshSelectedThreadIDs: {
                fixture.selectedThreadIDs
            }
        )
        coordinator.debounceNanoseconds = 0
        return coordinator
    }

    private func median(_ values: [Int]) -> Int {
        values.sorted()[values.count / 2]
    }

    private func p95(_ values: [Int]) -> Int {
        values.sorted()[min(values.count - 1, Int(Double(values.count) * 0.95))]
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
private final class ActivityRefreshFixture {
    var rounds: [Set<AgentThreadID>] = []
    var appliedRounds: [Set<AgentThreadID>] = []
    var selectedThreadIDs: Set<AgentThreadID> = []
    var firstRoundEntered = false
    private var firstRoundContinuation: CheckedContinuation<Void, Never>?

    func recordRound(_ threadIDs: Set<AgentThreadID>) async {
        rounds.append(threadIDs)
        guard rounds.count == 1 else { return }
        firstRoundEntered = true
        await withCheckedContinuation { continuation in
            firstRoundContinuation = continuation
        }
    }

    func recordAppliedRound(_ threadIDs: Set<AgentThreadID>) {
        appliedRounds.append(threadIDs)
    }

    func releaseFirstRound() {
        firstRoundContinuation?.resume()
        firstRoundContinuation = nil
    }
}
