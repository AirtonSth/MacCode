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

    func test_workingCatCopy_hasOneHundredEnglishActivities() {
        // WHY: product asks for 100 kitten activities rotating every 15s.
        XCTAssertEqual(AgentWorkingCatCopy.activities.count, 100)
        XCTAssertEqual(Set(AgentWorkingCatCopy.activities).count, 100,
                       "activities must be unique so rotation does not feel stuck")
        XCTAssertEqual(AgentWorkingCatCopy.rotationSeconds, 15)
        XCTAssertTrue(
            AgentWorkingCatCopy.activities.allSatisfy {
                !$0.isEmpty && $0.unicodeScalars.allSatisfy(\.isASCII)
            },
            "all phrases stay English ASCII for the strip"
        )
    }

    func test_workingCatCopy_rotatesEveryFifteenSeconds() {
        // WHY: same elapsed window must be stable; next window must advance.
        XCTAssertEqual(AgentWorkingCatCopy.activity(elapsedSeconds: 0), "Working")
        XCTAssertEqual(AgentWorkingCatCopy.activity(elapsedSeconds: 14), "Working")
        XCTAssertEqual(
            AgentWorkingCatCopy.activity(elapsedSeconds: 15),
            AgentWorkingCatCopy.activities[1]
        )
        XCTAssertEqual(
            AgentWorkingCatCopy.statusLabel(elapsedSeconds: 95),
            "\(AgentWorkingCatCopy.activities[95 / 15]) for 1m 35s"
        )
        XCTAssertEqual(
            AgentWorkingCatCopy.accessibilityLabel(elapsedSeconds: 95),
            "Working for 1m 35s",
            "VoiceOver / UITests keep a stable Working-for label"
        )
        XCTAssertEqual(
            AgentWorkingCatCopy.activity(elapsedSeconds: 100 * 15),
            AgentWorkingCatCopy.activities[0],
            "deck wraps after 100 phrases"
        )
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

    func test_splitTrailingLiveTurns_preservesOrder_andKeepsLiveEager() {
        // WHY: Lazy history + eager live tail must reassemble to the same sequence;
        // a finished entry after a live turn must stay in the eager suffix so the
        // still-streaming row never migrates into LazyVStack.
        let finished = AssistantTurnSnapshot(
            turnId: "done",
            items: [AssistantItem(id: "i", turnId: "done", type: .tool, state: .completed, startedAtMs: 1, finishedAtMs: 2)],
            finished: true
        )
        let live = AssistantTurnSnapshot(
            turnId: "live",
            items: [AssistantItem(id: "j", turnId: "live", type: .tool, state: .streaming, startedAtMs: 3)],
            finished: false
        )
        let afterLive = AssistantTurnSnapshot(
            turnId: "after",
            items: [AssistantItem(id: "k", turnId: "after", type: .tool, state: .completed, startedAtMs: 4, finishedAtMs: 5)],
            finished: true
        )
        let msg = AgentMessage(
            id: AgentMessageID(),
            threadId: AgentThreadID(),
            role: .user,
            content: "hi",
            createdAt: Date(timeIntervalSince1970: 0.5)
        )
        let entries: [AgentAppView.TranscriptEntry] = [
            .message(msg),
            .turn(finished),
            .turn(live),
            .turn(afterLive),
        ]
        let split = AgentAppView.splitTrailingLiveTurns(entries, latestLiveTurnId: "live")
        XCTAssertEqual(split.history.map(\.id), [entries[0].id, entries[1].id])
        XCTAssertEqual(split.liveTail.map(\.id), [entries[2].id, entries[3].id])
        XCTAssertEqual(
            (split.history + split.liveTail).map(\.id),
            entries.map(\.id),
            "history+liveTail must equal original order"
        )
    }

    func test_splitTrailingLiveTurns_staleUnfinishedDoesNotDisableLazy() {
        // WHY: a stuck unfinished turn near the top must stay Lazy; only the
        // current live (or trailing unfinished) is eager.
        let stuckLive = AssistantTurnSnapshot(
            turnId: "stuck",
            items: [AssistantItem(id: "s", turnId: "stuck", type: .tool, state: .streaming, startedAtMs: 1)],
            finished: false
        )
        let laterFinished = AssistantTurnSnapshot(
            turnId: "later",
            items: [AssistantItem(id: "l", turnId: "later", type: .tool, state: .completed, startedAtMs: 2, finishedAtMs: 3)],
            finished: true
        )
        let currentLive = AssistantTurnSnapshot(
            turnId: "now",
            items: [AssistantItem(id: "n", turnId: "now", type: .tool, state: .streaming, startedAtMs: 4)],
            finished: false
        )
        let paint: [AgentAppView.TranscriptEntry] = [
            .turn(stuckLive),
            .turn(laterFinished),
            .turn(currentLive),
        ]
        let split = AgentAppView.splitTrailingLiveTurns(paint, latestLiveTurnId: "now")
        XCTAssertEqual(split.history.map(\.id), [paint[0].id, paint[1].id])
        XCTAssertEqual(split.liveTail.map(\.id), [paint[2].id])
        // Without latest id: only trailing unfinished peels.
        let peel = AgentAppView.splitTrailingLiveTurns(paint)
        XCTAssertEqual(peel.liveTail.map(\.id), [paint[2].id])
        XCTAssertEqual(peel.history.map(\.id), [paint[0].id, paint[1].id])
    }

    func test_turnSortTime_usesOnlyFirstItemStartedAt() {
        // WHY: min() pulls the turn backward when a later parallel tool has an
        // earlier host stamp — Lazy identity thrash mid-stream.
        let turn = AssistantTurnSnapshot(
            turnId: "t",
            items: [
                AssistantItem(id: "a", turnId: "t", type: .tool, state: .streaming, startedAtMs: 5_000),
                AssistantItem(id: "b", turnId: "t", type: .tool, state: .streaming, startedAtMs: 1_000),
            ],
            finished: false
        )
        XCTAssertEqual(
            AgentAppView.TranscriptEntry.turn(turn).sortTime,
            5.0,
            "must use first item startedAtMs, not min across items"
        )
        let empty = AssistantTurnSnapshot(turnId: "empty", items: [], finished: false, startedAtMs: 7_000)
        XCTAssertEqual(
            AgentAppView.TranscriptEntry.turn(empty).sortTime,
            7.0,
            "empty turn falls back to turn.startedAtMs"
        )
    }

    func test_transcriptOrder_ensuringOrdered_fixesInversionWithoutDuplicates() {
        // WHY: Lazy lists require a stable total order; disorder would reshuffle rows mid-stream.
        struct E: Equatable { let id: String; let t: TimeInterval }
        let disordered = [
            E(id: "message-b", t: 2),
            E(id: "message-a", t: 1),
            E(id: "turn-z", t: 1.5),
        ]
        let ordered = AgentTranscriptOrder.ensuringOrdered(disordered, time: \.t, id: \.id)
        XCTAssertEqual(ordered.map(\.id), ["message-a", "turn-z", "message-b"])
        let already = AgentTranscriptOrder.ensuringOrdered(ordered, time: \.t, id: \.id)
        XCTAssertEqual(already.map(\.id), ordered.map(\.id), "already-ordered list must not reshuffle")
        XCTAssertTrue(
            AgentTranscriptOrder.isOrdered(times: ordered.map(\.t), ids: ordered.map(\.id))
        )
        let remat = AgentTranscriptOrder.rematerializePreservingOrder(
            orderedIds: ["message-a", "turn-z", "message-b"],
            payloadsById: ["message-a": "A", "message-b": "B", "turn-z": "T", "extra": "X"]
        )
        XCTAssertEqual(remat, ["A", "T", "B"], "rematerialize keeps sequence; never inserts unknown mid-list")
    }

    /// WHY: opening a long thread sometimes painted the persisted final *above*
    /// "Work so far" when message.createdAt sorted before the turn sort anchor.
    func test_placingMatchingFinalsAfterTurns_movesAnswerBelowWorkSoFar() {
        struct Row: Equatable {
            enum Kind { case user, turn, assistant }
            let id: String
            let kind: Kind
            let text: String?
        }
        let inverted: [Row] = [
            Row(id: "user", kind: .user, text: "do the work"),
            Row(id: "final-msg", kind: .assistant, text: "Here is the Phases table answer"),
            Row(id: "turn-1", kind: .turn, text: "Here is the Phases table answer"),
        ]
        let fixed = AgentTranscriptOrder.placingMatchingFinalsAfterTurns(
            inverted,
            turnFinalText: { $0.kind == .turn ? $0.text : nil },
            assistantMessageText: { $0.kind == .assistant ? $0.text : nil },
            textsMatch: AgentTranscriptOrder.finalTextsMatch
        )
        XCTAssertEqual(
            fixed.map(\.id),
            ["user", "turn-1", "final-msg"],
            "final answer must paint after its turn (Work so far → final)"
        )
        let alreadyGood = AgentTranscriptOrder.placingMatchingFinalsAfterTurns(
            fixed,
            turnFinalText: { $0.kind == .turn ? $0.text : nil },
            assistantMessageText: { $0.kind == .assistant ? $0.text : nil },
            textsMatch: AgentTranscriptOrder.finalTextsMatch
        )
        XCTAssertEqual(alreadyGood.map(\.id), fixed.map(\.id), "idempotent when order is already correct")
    }

    func test_finalTextsMatch_ignoresWhitespaceNoise() {
        XCTAssertTrue(
            AgentTranscriptOrder.finalTextsMatch("Hello  world\n", "Hello world"),
            "whitespace-only differences must still associate final with its turn"
        )
        XCTAssertFalse(
            AgentTranscriptOrder.finalTextsMatch("alpha", "beta"),
            "unrelated answers must not be reordered against each other"
        )
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

    func test_appendFriendlyCompletedWorkBlocks_refreshesPayloadWhenIdsUnchanged() {
        // WHY: token deltas keep item ids; returning previous blocks froze body mid-stream.
        var first = AssistantItem(
            id: "r1", turnId: "t", type: .reasoning, state: .streaming,
            body: "thin", startedAtMs: 1
        )
        let firstBlocks = AgentAppView.turnRenderBlocks([first])
        first.body = "thinking out loud fully"
        let refreshed = AgentAppView.appendFriendlyCompletedWorkBlocks(
            previousItems: [
                AssistantItem(
                    id: "r1", turnId: "t", type: .reasoning, state: .streaming,
                    body: "thin", startedAtMs: 1
                )
            ],
            previousBlocks: firstBlocks,
            nextItems: [first]
        )
        XCTAssertEqual(refreshed.count, 1)
        if case .item(let item) = refreshed[0] {
            XCTAssertEqual(item.body, "thinking out loud fully")
        } else {
            XCTFail("expected single item block")
        }
    }

    func test_eagerAnchorTurnId_rejectsStaleLiveNearTop() {
        // WHY: stale unfinished at index 0 must not force whole paint eager.
        let stuck = AssistantTurnSnapshot(
            turnId: "stuck",
            items: [AssistantItem(id: "s", turnId: "stuck", type: .tool, state: .streaming, startedAtMs: 1)],
            finished: false
        )
        var entries: [AgentAppView.TranscriptEntry] = [.turn(stuck)]
        for i in 0..<25 {
            entries.append(.turn(AssistantTurnSnapshot(
                turnId: "f\(i)",
                items: [AssistantItem(id: "x\(i)", turnId: "f\(i)", type: .tool, state: .completed, startedAtMs: Int64(i + 2), finishedAtMs: Int64(i + 3))],
                finished: true
            )))
        }
        XCTAssertNil(
            AgentAppView.eagerAnchorTurnId(entries, latestLiveTurnId: "stuck", maxEagerTail: 20)
        )
        let live = AssistantTurnSnapshot(
            turnId: "now",
            items: [AssistantItem(id: "n", turnId: "now", type: .tool, state: .streaming, startedAtMs: 100)],
            finished: false
        )
        entries.append(.turn(live))
        XCTAssertEqual(
            AgentAppView.eagerAnchorTurnId(entries, latestLiveTurnId: "now", maxEagerTail: 20),
            "now"
        )
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
