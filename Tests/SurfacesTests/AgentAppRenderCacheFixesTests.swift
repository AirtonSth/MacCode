import XCTest
import CoreModel
@testable import Surfaces

/// Regression tests for the transcript render-cache fixes:
///  F1  - the transcript cache memoizes only the ORDER; on a signature hit the
///        `.turn` payloads must be re-materialized from the live timeline so
///        streaming text/output, item state flips, and turn completion render
///        without waiting for the next structural change.
///  F40 - the SignatureCache item-count hash must not cancel for equal-count
///        turns (the old XOR fold gave h ^ h == 0), or a flush adding one item
///        to each of two equal-count turns serves a stale signature.
///  F21 - reasoning presentation must surface the actual reasoning text the
///        Codex adapter streams into `item.output`, not the constant
///        "Reasoning" placeholder summary.
final class AgentAppRenderCacheFixesTests: XCTestCase {

    private static let tid = AgentThreadID()

    private func msg(_ secs: TimeInterval, content: String = "m") -> AgentMessage {
        AgentMessage(threadId: Self.tid, role: .user,
                     content: content, createdAt: Date(timeIntervalSince1970: secs))
    }

    private func item(_ id: String, turnId: String, body: String = "",
                      output: String? = nil, state: AssistantItemState = .streaming,
                      startMs: Int64 = 1_000) -> AssistantItem {
        AssistantItem(id: id, turnId: turnId, type: .assistantMessage, state: state,
                      body: body, output: output, startedAtMs: startMs)
    }

    private func turn(_ turnId: String, items: [AssistantItem],
                      final: String? = nil, finished: Bool = false) -> AssistantTurnSnapshot {
        AssistantTurnSnapshot(turnId: turnId, items: items,
                              finalAssistantMessage: final, finished: finished)
    }

    // MARK: - F1: cache hits must serve LIVE turn payloads

    /// WHY: Codex (the default provider) streams the whole answer as body deltas
    /// into one existing item — zero structural changes — so if a signature hit
    /// returns the cached turn value-copies, the on-screen answer freezes at its
    /// first chunk while vm.timeline accumulates the full text.
    func test_rematerialize_servesStreamedBodyAndStateFromLiveTurns() {
        let stale = turn("t1", items: [item("i1", turnId: "t1", body: "Hel")])
        let cached: [AgentAppView.TranscriptEntry] = [.message(msg(1)), .turn(stale)]

        let live = turn(
            "t1",
            items: [item("i1", turnId: "t1", body: "Hello, full streamed answer",
                         output: "tool output", state: .completed)],
            final: "Hello, full streamed answer",
            finished: true
        )
        let refreshed = AgentAppView.rematerializedTranscriptEntries(cached: cached, turns: [live])

        XCTAssertEqual(refreshed.count, 2, "re-materialization must not add or drop entries")
        guard case .turn(let servedTurn) = refreshed[1] else {
            return XCTFail("the turn entry must stay a turn at its cached position")
        }
        XCTAssertEqual(servedTurn, live,
                       "a signature hit must serve the LIVE turn snapshot — the signature ignores bodies/outputs/states/finished, so serving the cached copy freezes streamed text until the next structural change (F1)")
    }

    /// WHY: the cache exists to skip the O(N log N) merge/sort — so the ORDER and
    /// the immutable message payloads must come from the cache verbatim; only the
    /// mutable turn payloads are refreshed.
    func test_rematerialize_preservesOrderAndMessagePayloads() {
        let m1 = msg(1, content: "first")
        let m2 = msg(3, content: "second")
        let staleA = turn("a", items: [item("ia", turnId: "a", body: "old-a", startMs: 2_000)])
        let staleB = turn("b", items: [item("ib", turnId: "b", body: "old-b", startMs: 4_000)])
        let cached: [AgentAppView.TranscriptEntry] = [
            .message(m1), .turn(staleA), .message(m2), .turn(staleB)
        ]
        // Live turns arrive in a different array order than the cached entries:
        // matching must be by turnId, never by position.
        let liveB = turn("b", items: [item("ib", turnId: "b", body: "new-b", startMs: 4_000)])
        let liveA = turn("a", items: [item("ia", turnId: "a", body: "new-a", startMs: 2_000)])

        let refreshed = AgentAppView.rematerializedTranscriptEntries(cached: cached, turns: [liveB, liveA])

        XCTAssertEqual(refreshed.map(\.id), cached.map(\.id),
                       "the cached ORDER is the whole point of the memo — re-materializing payloads must never reorder entries")
        guard case .message(let servedM1) = refreshed[0], case .message(let servedM2) = refreshed[2] else {
            return XCTFail("message entries must stay messages at their cached positions")
        }
        XCTAssertEqual([servedM1.content, servedM2.content], ["first", "second"],
                       "messages are append-only immutable rows — their cached copies pass through untouched")
        guard case .turn(let servedA) = refreshed[1], case .turn(let servedB) = refreshed[3] else {
            return XCTFail("turn entries must stay turns at their cached positions")
        }
        XCTAssertEqual(servedA.items.first?.body, "new-a",
                       "each turn must be refreshed from the live snapshot with the SAME turnId")
        XCTAssertEqual(servedB.items.first?.body, "new-b",
                       "each turn must be refreshed from the live snapshot with the SAME turnId")
    }

    /// WHY: a cached turn no longer present in the live timeline (defensive case)
    /// must degrade to the cached snapshot instead of vanishing — dropping rows on
    /// a payload refresh would be worse than showing slightly stale content.
    func test_rematerialize_keepsCachedSnapshotWhenTurnMissingFromLiveTimeline() {
        let stale = turn("gone", items: [item("ig", turnId: "gone", body: "kept")])
        let cached: [AgentAppView.TranscriptEntry] = [.turn(stale)]
        let unrelatedLive = turn("other", items: [item("io", turnId: "other")])

        let refreshed = AgentAppView.rematerializedTranscriptEntries(cached: cached, turns: [unrelatedLive])

        guard case .turn(let served) = refreshed.first else {
            return XCTFail("the cached turn entry must survive")
        }
        XCTAssertEqual(served, stale,
                       "a turn absent from the live timeline falls back to its cached snapshot — never dropped")
    }

    /// WHY: token deltas on a live turn must not rebuild every finished turn's
    /// item tree (large-thread stream path). Stable finished turns keep cache.
    func test_rematerialize_skipsStableFinishedTurnsOnStreamTick() {
        let finishedStale = turn(
            "done",
            items: [item("id", turnId: "done", body: "answer", state: .completed)],
            final: "answer",
            finished: true
        )
        let liveStale = turn(
            "live",
            items: [item("il", turnId: "live", body: "Hel", state: .streaming)]
        )
        let cached: [AgentAppView.TranscriptEntry] = [.turn(finishedStale), .turn(liveStale)]

        // Live finished payload mutates body (should NOT be taken for stable finished).
        let finishedLive = turn(
            "done",
            items: [item("id", turnId: "done", body: "answer SHOULD NOT REPLACE", state: .completed)],
            final: "answer",
            finished: true
        )
        let liveLive = turn(
            "live",
            items: [item("il", turnId: "live", body: "Hello streamed", state: .streaming)]
        )

        XCTAssertFalse(
            AgentAppView.shouldRematerializeTurn(stale: finishedStale, live: finishedLive),
            "stable finished turns skip rematerialize"
        )
        XCTAssertTrue(
            AgentAppView.shouldRematerializeTurn(stale: liveStale, live: liveLive),
            "unfinished turns always rematerialize"
        )

        let refreshed = AgentAppView.rematerializedTranscriptEntries(
            cached: cached,
            turns: [finishedLive, liveLive]
        )
        guard case .turn(let servedFinished) = refreshed[0],
              case .turn(let servedLive) = refreshed[1] else {
            return XCTFail("turn entries preserved")
        }
        XCTAssertEqual(servedFinished.items.first?.body, "answer",
                       "finished turn keeps cached body on stream tick")
        XCTAssertEqual(servedLive.items.first?.body, "Hello streamed",
                       "live turn takes streamed body")
    }

    func test_hotMessagePageLimit_isBoundedForLargeThreads() {
        XCTAssertLessThanOrEqual(
            AgentAppViewModel.messageHistoryPageLimit,
            200,
            "hot UI page must not rehydrate multi-thousand-row histories at once"
        )
        XCTAssertLessThanOrEqual(
            AgentAppViewModel.fullLoadBodyBudgetBytes,
            16 * 1024 * 1024,
            "hot body budget must stay well below the old 96 MB full-thread load"
        )
    }

    func test_idlePaintWindow_boundsLargeThread() {
        XCTAssertEqual(AgentAppView.idleTranscriptWindowCount, 20)
        let entries: [AgentAppView.TranscriptEntry] = (0..<100).map { i in
            .message(msg(TimeInterval(i), content: "m\(i)"))
        }
        let visible = AgentAppView.visibleTranscriptWindow(
            entries: entries,
            status: .completed,
            runStartedAt: nil
        )
        XCTAssertEqual(visible.count, AgentAppView.idleTranscriptWindowCount)
        XCTAssertEqual(visible.map(\.id), Array(entries.suffix(20)).map(\.id))
    }

    func test_hotMessageFirstPaint_isAggressiveForFluidOpen() {
        XCTAssertLessThanOrEqual(AgentAppViewModel.messageHistoryPageLimit, 30)
        XCTAssertLessThanOrEqual(AgentAppViewModel.fullLoadBodyBudgetBytes, 400 * 1024)
    }

    /// WHY: older durable rows must prepend into the hot window without
    /// duplicating ids already present (load-older keyset path).
    func test_mergeOlderMessagePage_prependsWithoutDuplicates() {
        // Same AgentMessage instance appears in older page and hot window (shared id).
        let shared = msg(2, content: "shared")
        let olderPage = [msg(1, content: "old-a"), shared]
        let hot = [shared, msg(3, content: "new")]
        let merged = AgentAppViewModel.mergeOlderMessagePage(older: olderPage, current: hot)
        XCTAssertEqual(merged.count, 3, "duplicate id must not double")
        XCTAssertEqual(merged.map(\.content), ["old-a", "shared", "new"])
    }

    /// WHY: after a live turn finishes, the cache baseline must reflect finished
    /// so later stream ticks do not keep rematerializing it (cache write-back).
    func test_shouldRematerialize_falseAfterFinishedBaseline() {
        let finished = turn(
            "t1",
            items: [item("i1", turnId: "t1", body: "done", state: .completed)],
            final: "done",
            finished: true
        )
        // Same structural snapshot (as if cache was write-back after complete)
        XCTAssertFalse(
            AgentAppView.shouldRematerializeTurn(stale: finished, live: finished),
            "write-back baseline finished==live finished must skip rematerialize"
        )
    }

    /// WHY: generation ownership — only the live older-page Task may clear loading.
    /// A-load then switch/bump then B-load: A's defer must NOT clear B's generation.
    func test_shouldClearLoadingOlderMessages_generationOwnership() {
        // Live load owns gen 5
        XCTAssertTrue(
            AgentAppViewModel.shouldClearLoadingOlderMessages(
                myGeneration: 5,
                currentGeneration: 5
            ),
            "matching non-zero gen clears"
        )
        // Stale after cancelOlderMessageLoad / newer load bumped gen
        XCTAssertFalse(
            AgentAppViewModel.shouldClearLoadingOlderMessages(
                myGeneration: 5,
                currentGeneration: 6
            ),
            "stale gen must not clear a newer load's ownership"
        )
        // Idle / cleared
        XCTAssertFalse(
            AgentAppViewModel.shouldClearLoadingOlderMessages(
                myGeneration: 0,
                currentGeneration: 0
            ),
            "zero gen is idle — not a live owner"
        )
        // Simulate A=1, switch bumps to 2 (cancel), B starts and becomes 3:
        // A's defer with myGen=1 must not clear while current=3
        XCTAssertFalse(
            AgentAppViewModel.shouldClearLoadingOlderMessages(
                myGeneration: 1,
                currentGeneration: 3
            ),
            "A's stale defer after A-switch-B must leave B's load alone"
        )
    }

    // MARK: - F40: item-count hash must not cancel for equal-count turns

    /// WHY: the Claude parser routes hook/status items into a parallel "" turn
    /// alongside the active turn, so one 16 ms flush can add an item to EACH of
    /// two turns. With the old XOR fold, two equal-count turns contributed
    /// h(c) ^ h(c) == 0 before AND after ({c,c} -> {c+1,c+1}), so the signature
    /// pre-check served the stale signature and the new items never rendered.
    func test_turnItemCountsHash_changesWhenTwoEqualCountTurnsEachGainAnItem() {
        func turns(counts: [Int]) -> [AssistantTurnSnapshot] {
            counts.enumerated().map { idx, count in
                turn("t\(idx)", items: (0..<count).map {
                    item("t\(idx)-i\($0)", turnId: "t\(idx)")
                })
            }
        }
        // The exact failure shape: both turns gain their first item in one flush.
        XCTAssertNotEqual(
            AgentAppView.turnItemCountsHash(turns(counts: [0, 0])),
            AgentAppView.turnItemCountsHash(turns(counts: [1, 1])),
            "simultaneous item adds to equal-count turns must change the hash, or the signature cache suppresses the transcript re-merge (F40)"
        )
        XCTAssertNotEqual(
            AgentAppView.turnItemCountsHash(turns(counts: [2, 2])),
            AgentAppView.turnItemCountsHash(turns(counts: [3, 3])),
            "equal-count turns must never cancel each other out of the hash"
        )
        // XOR is also order-insensitive; the fold must be position-sensitive to
        // match the ordered per-turn string signature it stands in for.
        XCTAssertNotEqual(
            AgentAppView.turnItemCountsHash(turns(counts: [1, 2])),
            AgentAppView.turnItemCountsHash(turns(counts: [2, 1])),
            "the hash must be order-sensitive like the full signature string"
        )
    }

    // MARK: - F21: reasoning detail prefers the streamed text over the placeholder

    /// WHY: the Codex app-server adapter streams reasoning text into `item.output`
    /// with the constant summary "Reasoning". The Thought row's expanded text comes
    /// from presentation.detail when body is empty, so returning the summary showed
    /// the literal word "Reasoning" and silently discarded the model's reasoning.
    func test_reasoningPresentation_detailPrefersOutputOverPlaceholderSummary() {
        let reasoning = AssistantItem(
            id: "r1", turnId: "t1", type: .reasoning, state: .completed,
            summary: "Reasoning", body: "",
            output: "First I checked the failing test, then traced the cache key.",
            startedAtMs: 1_000
        )
        XCTAssertEqual(
            AgentTimelineItemPresentation.make(for: reasoning).detail,
            "First I checked the failing test, then traced the cache key.",
            "expanding a Thought row must show the model's actual reasoning (streamed into output by the Codex adapter), not the constant \"Reasoning\" summary (F21)"
        )
    }

    /// WHY: providers that only send reasoning SUMMARIES (no text) must keep
    /// showing them — the output preference is a fallback order, not a removal.
    func test_reasoningPresentation_detailFallsBackToSummaryWhenNoOutput() {
        let summaryOnly = AssistantItem(
            id: "r2", turnId: "t1", type: .reasoning, state: .completed,
            summary: "Weighed cache invalidation options", body: "",
            output: nil, startedAtMs: 1_000
        )
        XCTAssertEqual(
            AgentTimelineItemPresentation.make(for: summaryOnly).detail,
            "Weighed cache invalidation options",
            "with no reasoning text, the summary is still the best available detail"
        )
        let empty = AssistantItem(
            id: "r3", turnId: "t1", type: .reasoning, state: .completed,
            summary: "   ", body: "", output: "", startedAtMs: 1_000
        )
        XCTAssertNil(
            AgentTimelineItemPresentation.make(for: empty).detail,
            "blank output and blank summary must yield no detail (row stays collapsed)"
        )
    }
}
