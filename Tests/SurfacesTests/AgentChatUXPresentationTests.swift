import XCTest
import CoreModel
@testable import Surfaces

final class AgentChatUXPresentationTests: XCTestCase {

    // MARK: System strip

    func test_systemStrip_collapse_ordersErrorBeforeInfo_andCapsVisible() {
        let items = [
            AgentSystemStripItem(id: "info", severity: .info, message: "replay"),
            AgentSystemStripItem(id: "err", severity: .error, message: "send failed"),
            AgentSystemStripItem(id: "warn", severity: .warning, message: "stale snapshot"),
            AgentSystemStripItem(id: "q", severity: .warning, message: "queue issue")
        ]
        let result = AgentSystemStripPresentation.collapse(items, maxVisible: 2)
        XCTAssertEqual(result.visible.map(\.id), ["err", "warn"])
        XCTAssertEqual(result.overflowCount, 2)
        // WHY: errors must surface first so recovery is not buried under info banners.
        XCTAssertEqual(result.visible.first?.severity, .error)
    }

    func test_systemStrip_items_skipsEmpty_andClassifiesFailures() {
        let items = AgentSystemStripPresentation.items(
            historyReplayNotice: "  ",
            statusMessage: "Run failed: timeout",
            providerSnapshotStatus: "Snapshot stale",
            standaloneQueueStatus: nil
        )
        XCTAssertEqual(items.map(\.id), ["agent.status.message", "agent.provider.snapshot.stale"])
        XCTAssertEqual(items[0].severity, .error)
        XCTAssertTrue(items[1].offersRetry)
    }

    // MARK: Working strip

    func test_workingPhase_prefersAwaitingOverTools() {
        let phase = AgentWorkingStripPresentation.phase(
            runIsLive: true,
            isAwaitingBackground: true,
            backgroundShellCount: 0,
            activeSubagentCount: 2,
            hasStreamingTools: true
        )
        XCTAssertEqual(phase, .awaitingBackground)
    }

    func test_workingLabel_includesElapsed() {
        let label = AgentWorkingStripPresentation.label(phase: .thinking, elapsedSeconds: 95)
        XCTAssertEqual(label, "Thinking · 1m 35s")
        XCTAssertNil(AgentWorkingStripPresentation.label(phase: .idle, elapsedSeconds: 10))
    }

    // MARK: Composer chrome

    func test_composerChrome_simpleHidesPermissionAndSource() {
        XCTAssertTrue(AgentComposerChromePresentation.shows(.model, mode: .simple))
        XCTAssertTrue(AgentComposerChromePresentation.shows(.sendStop, mode: .simple))
        XCTAssertFalse(AgentComposerChromePresentation.shows(.permission, mode: .simple))
        XCTAssertFalse(AgentComposerChromePresentation.shows(.source, mode: .simple))
        XCTAssertTrue(AgentComposerChromePresentation.shows(.permission, mode: .power))
        // WHY: Simple mode must keep send reachable while parking advanced identity/safety chrome.
    }

    // MARK: Completed work perf gate

    func test_completedWork_shouldBuildBlocks_onlyWhenExpanded() {
        XCTAssertFalse(AgentCompletedWorkPresentation.shouldBuildBlocks(
            expandCompletedWork: false, workItemCount: 12
        ))
        XCTAssertTrue(AgentCompletedWorkPresentation.shouldBuildBlocks(
            expandCompletedWork: true, workItemCount: 3
        ))
        XCTAssertFalse(AgentCompletedWorkPresentation.shouldBuildBlocks(
            expandCompletedWork: true, workItemCount: 0
        ))
    }

    func test_collapsedLabel_prefersDuration() {
        XCTAssertEqual(
            AgentCompletedWorkPresentation.collapsedLabel(workBlockCount: 4, durationText: "12s"),
            "Worked for 12s"
        )
        XCTAssertEqual(
            AgentCompletedWorkPresentation.collapsedLabel(workBlockCount: 4, durationText: nil),
            "Worked · 4 steps"
        )
    }

    // MARK: Thread rail

    func test_threadRail_monogramAndRelativeTime() {
        XCTAssertEqual(AgentThreadRailRowCopy.monogram(for: .claude), "C")
        let now = Date()
        let threeMin = now.addingTimeInterval(-180)
        XCTAssertEqual(AgentThreadRailRowCopy.relativeTime(from: threeMin, now: now), "3m")
        let subtitle = AgentThreadRailRowCopy.subtitle(
            provider: .codex,
            model: "gpt-5.4-extra-long-model-name-that-should-truncate",
            updatedAt: threeMin,
            now: now
        )
        XCTAssertTrue(subtitle.contains("codex"))
        XCTAssertTrue(subtitle.contains("3m"))
        XCTAssertTrue(subtitle.contains("…"), "long models truncate for rail density")
    }

    func test_emptyStarters_alignedCount() {
        XCTAssertEqual(AgentEmptyConversationStarters.all.count, 4)
        XCTAssertFalse(AgentEmptyConversationStarters.all[0].prompt.isEmpty)
    }
}
