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

    // MARK: Work so far expand policy + append growth

    func test_workExpandPolicy_defaultOpenLatestLive_andCollapseOnFinal() {
        // WHY: latest live Work so far must open by default so users see in-flight tools.
        XCTAssertTrue(
            AgentCompletedWorkExpandPolicy.isExpanded(
                isLive: true,
                isLatestLiveTurn: true,
                userExplicitlyExpanded: false,
                userCollapsedWhileLive: false
            ),
            "latest live work disclosure defaults open"
        )
        XCTAssertFalse(
            AgentCompletedWorkExpandPolicy.isExpanded(
                isLive: true,
                isLatestLiveTurn: true,
                userExplicitlyExpanded: false,
                userCollapsedWhileLive: true
            ),
            "user can manually collapse the live default-open disclosure"
        )
        XCTAssertFalse(
            AgentCompletedWorkExpandPolicy.isExpanded(
                isLive: false,
                isLatestLiveTurn: false,
                userExplicitlyExpanded: false,
                userCollapsedWhileLive: false
            ),
            "finished work stays collapsed unless the user re-opens it"
        )
        XCTAssertTrue(
            AgentCompletedWorkExpandPolicy.isExpanded(
                isLive: false,
                isLatestLiveTurn: false,
                userExplicitlyExpanded: true,
                userCollapsedWhileLive: false
            ),
            "user can re-open a finished Worked disclosure"
        )
        let cleared = AgentCompletedWorkExpandPolicy.clearedExpansionState()
        XCTAssertTrue(cleared.expanded.isEmpty && cleared.collapsedLive.isEmpty,
                      "final answer clears every work-disclosure override")
    }

    func test_workExpandPolicy_toggle_liveCollapseAndReopen() {
        let collapsed = AgentCompletedWorkExpandPolicy.toggle(
            turnId: "t1",
            currentlyExpanded: true,
            isLive: true,
            isLatestLiveTurn: true,
            userExpanded: [],
            userCollapsedLive: []
        )
        XCTAssertTrue(collapsed.collapsedLive.contains("t1"))
        XCTAssertFalse(collapsed.expanded.contains("t1"))
        let reopened = AgentCompletedWorkExpandPolicy.toggle(
            turnId: "t1",
            currentlyExpanded: false,
            isLive: true,
            isLatestLiveTurn: true,
            userExpanded: collapsed.expanded,
            userCollapsedLive: collapsed.collapsedLive
        )
        XCTAssertFalse(reopened.collapsedLive.contains("t1"))
        XCTAssertTrue(reopened.expanded.contains("t1"))
    }

    func test_workBlockGrowth_prefixStableAppend_reusesPriorIdentities() {
        // N settled → N+1 settled while expanded must be append/reuse, not full_rebuild.
        let previousItems = ["i0", "i1", "i2"]
        let previousBlocks = ["block-item-i0", "block-item-i1", "block-item-i2"]
        let nextItems = ["i0", "i1", "i2", "i3"]
        let nextBlocks = ["block-item-i0", "block-item-i1", "block-item-i2", "block-item-i3"]
        let growth = AgentCompletedWorkBlockGrowth.growthDecision(
            previousItemIds: previousItems,
            previousBlockIds: previousBlocks,
            nextItemIds: nextItems,
            nextBlockIds: nextBlocks
        )
        XCTAssertEqual(growth.mode, "append",
                       "settled tail growth must append rather than rematerialize the full prior set")
        XCTAssertEqual(growth.reusedCount, 3)
        XCTAssertEqual(growth.appendedBlockIds, ["block-item-i3"])

        let identical = AgentCompletedWorkBlockGrowth.growthDecision(
            previousItemIds: nextItems,
            previousBlockIds: nextBlocks,
            nextItemIds: nextItems,
            nextBlockIds: nextBlocks
        )
        XCTAssertEqual(identical.mode, "reuse")
        XCTAssertTrue(identical.appendedBlockIds.isEmpty)

        let rebuilt = AgentCompletedWorkBlockGrowth.growthDecision(
            previousItemIds: ["a", "b"],
            previousBlockIds: ["block-a", "block-b"],
            nextItemIds: ["x", "y"],
            nextBlockIds: ["block-x", "block-y"]
        )
        XCTAssertEqual(rebuilt.mode, "full_rebuild")
    }

    func test_workDisclosureLayout_paintSliceAndDiffPreview() {
        let all = Array(0..<100)
        let slice = AgentWorkDisclosureLayout.paintSlice(all: all, revealCount: 0)
        XCTAssertEqual(slice.rows.count, AgentWorkDisclosureLayout.expandedPaintWindow)
        XCTAssertEqual(slice.hiddenCount, 100 - AgentWorkDisclosureLayout.expandedPaintWindow)
        let more = AgentWorkDisclosureLayout.paintSlice(all: all, revealCount: 48)
        XCTAssertEqual(more.rows.count, 96)
        let lines = (0..<50).map { "L\($0)" }
        let preview = AgentWorkDisclosureLayout.visibleDiffLines(
            lines,
            isMeta: { $0.hasPrefix("M") },
            showAll: false,
            previewLimit: 10
        )
        XCTAssertEqual(preview.rows.count, 10)
        XCTAssertEqual(preview.hiddenCount, 40)
    }

    func test_turnChatComposition_liveAllInWork_finishedFinalOutside() {
        // WHY: chat chrome must match iOS — user | Work so far | final only.
        let live = AgentTurnChatComposition.splitItems(
            ["tool-1", "tool-2", "stream"],
            turnFinished: false,
            isFinalItem: { $0 == "final" }
        )
        XCTAssertEqual(live.work, ["tool-1", "tool-2", "stream"])
        XCTAssertTrue(live.outside.isEmpty)
        let finished = AgentTurnChatComposition.splitItems(
            ["tool", "preamble", "final"],
            turnFinished: true,
            isFinalItem: { $0 == "final" }
        )
        XCTAssertEqual(finished.work, ["tool", "preamble"])
        XCTAssertEqual(finished.outside, ["final"])
    }

    // MARK: File edit diff presentation

    func test_fileEditDiff_parsesUnifiedHunkWithLineNumbers() {
        let diff = """
        diff --git a/src/foo.ts b/src/foo.ts
        --- a/src/foo.ts
        +++ b/src/foo.ts
        @@ -10,3 +10,4 @@
         context
        -old line
        +new line
        +another
         trail
        """
        let parsed = AgentFileEditDiffPresentation.parseUnifiedDiff(diff)
        XCTAssertEqual(parsed.inferredPath, "src/foo.ts")
        let kinds = parsed.lines.map(\.kind)
        XCTAssertTrue(kinds.contains(.deletion))
        XCTAssertTrue(kinds.contains(.addition))
        XCTAssertTrue(kinds.contains(.context))
        let firstAdd = parsed.lines.first(where: { $0.kind == .addition && $0.text.contains("new line") })
        XCTAssertEqual(firstAdd?.newLineNumber, 11,
                       "@@ -10 +10 maps first context to 10; first + is line 11")
    }

    func test_fileEditDiff_synthesizesClaudeEditJSON() {
        let body = """
        {"file_path":"/Users/me/app/generate-invoice.ts","old_string":"a = 1\\nb = 2","new_string":"a = 1\\nb = 3\\nc = 4"}
        """
        let item = AssistantItem(
            id: "edit-1",
            turnId: "t1",
            type: .tool,
            state: .completed,
            summary: "Edit",
            body: body,
            startedAtMs: 1
        )
        let model = AgentFileEditDiffPresentation.model(for: item)
        XCTAssertNotNil(model, "Claude Edit JSON must become a paint-able Edit card model")
        XCTAssertEqual(model?.path, "/Users/me/app/generate-invoice.ts")
        XCTAssertTrue(model?.hasRenderableCode == true)
        XCTAssertTrue(model?.lines.contains(where: { $0.kind == .deletion }) == true)
        XCTAssertTrue(model?.lines.contains(where: { $0.kind == .addition }) == true)
    }

    func test_fileEditDiff_codexPatchOnFileChangeItem() {
        let patch = """
        *** Update File: path/to/file.swift
        @@ -1,2 +1,2 @@
        -let x = 1
        +let x = 2
        """
        let item = AssistantItem(
            id: "fc-1",
            turnId: "t1",
            type: .fileChange,
            state: .completed,
            summary: "1 file change",
            output: patch,
            resourcePath: "path/to/file.swift",
            startedAtMs: 1
        )
        let model = AgentFileEditDiffPresentation.model(for: item)
        XCTAssertEqual(model?.path, "path/to/file.swift")
        XCTAssertTrue(model?.lines.contains(where: { $0.kind == .deletion && $0.text.contains("let x = 1") }) == true)
        XCTAssertTrue(model?.lines.contains(where: { $0.kind == .addition && $0.text.contains("let x = 2") }) == true)
    }

    func test_appendFriendlyCompletedWorkBlocks_appendsNewSettledTool() {
        func item(_ id: String) -> AssistantItem {
            AssistantItem(
                id: id,
                turnId: "t1",
                type: .commandExecution,
                state: .completed,
                body: "cmd \(id)",
                startedAtMs: 1
            )
        }
        let first = [item("i0"), item("i1")]
        let firstBlocks = AgentAppView.turnRenderBlocks(first)
        let second = first + [item("i2")]
        let grown = AgentAppView.appendFriendlyCompletedWorkBlocks(
            previousItems: first,
            previousBlocks: firstBlocks,
            nextItems: second
        )
        // Pure tool run ≥ threshold folds into one group with stable first-item id.
        XCTAssertEqual(grown.count, 1)
        if case .toolGroup(let id, let items) = grown[0] {
            XCTAssertEqual(id, "i0")
            XCTAssertEqual(items.map(\.id), ["i0", "i1", "i2"])
        } else {
            XCTFail("expected single tool group after append")
        }
        let third = second + [item("i3")]
        let grownAgain = AgentAppView.appendFriendlyCompletedWorkBlocks(
            previousItems: second,
            previousBlocks: grown,
            nextItems: third
        )
        if case .toolGroup(let id, let items) = grownAgain[0] {
            XCTAssertEqual(id, "i0", "group identity must stay stable across appends")
            XCTAssertEqual(items.map(\.id), ["i0", "i1", "i2", "i3"])
        } else {
            XCTFail("expected stable tool group after second append")
        }
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
