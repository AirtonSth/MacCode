import XCTest
import AppKit
import CoreModel
import DesignSystemKit
@testable import Surfaces

/// Regression pins for TODO.md F2 (2026-09-14): work in the Agent App transcript
/// that grew with the number of turns / items / streamed text per frame.
final class TranscriptGrowthPerfTests: XCTestCase {
    // MARK: AA-24

    func test_timelineItemStructureKey_changesOnlyWhenTheItemSetChanges() {
        // WHY: the Token Saver per-item translation index walked every item of
        // the thread on every stream quantum. It is rebuilt only when this key
        // (or the translations) change; body deltas must not move it.
        var s = AssistantTimelineState()
        s.apply(.turnStarted(turnId: "t1"))
        s.apply(.itemStarted(item: AssistantItem(id: "a", turnId: "t1", type: .assistantMessage, startedAtMs: 1)))
        let before = AgentAppViewModel.timelineItemStructureKey(s.turns)
        s.apply(.itemDelta(itemId: "a", bodyAppend: "more text", outputAppend: nil, summary: nil))
        XCTAssertEqual(AgentAppViewModel.timelineItemStructureKey(s.turns), before, "a body delta is not a structural change")
        s.apply(.itemStarted(item: AssistantItem(id: "b", turnId: "t1", type: .tool, startedAtMs: 2)))
        XCTAssertNotEqual(AgentAppViewModel.timelineItemStructureKey(s.turns), before, "a new item must invalidate the index")
        let afterItem = AgentAppViewModel.timelineItemStructureKey(s.turns)
        s.apply(.turnStarted(turnId: "t2"))
        XCTAssertNotEqual(AgentAppViewModel.timelineItemStructureKey(s.turns), afterItem, "a new turn must invalidate the index")
    }

    // MARK: AA-28

    func test_updatePlan_contentFingerprintsMakeEqualRowsNoOpWithoutDeepCompare() {
        // WHY: with a length-only fingerprint, unchanged rows fell through to a
        // full AttributedString comparison on every layout pass (O(text) per
        // mounted row). A content fingerprint on both sides is authoritative.
        let font = NSFont.systemFont(ofSize: 13)
        func state(_ text: String, fingerprint: Int, content: Bool) -> AgentLinkedInlineTextAppliedState {
            AgentLinkedInlineTextAppliedState(
                attributed: AttributedString(text),
                font: font,
                textColor: DS.NS.text,
                lineSpacing: 5,
                maximumNumberOfLines: nil,
                lineFragmentPadding: 0,
                sourceFingerprint: fingerprint,
                contentFingerprinted: content
            )
        }
        // Same fingerprint + content-fingerprinted: no-op even though the
        // attributed values differ (proves the deep compare is not consulted).
        let plan = AgentLinkedInlineTextUpdatePlan.make(
            previous: state("Hello", fingerprint: 7, content: true),
            next: state("Hello!", fingerprint: 7, content: true)
        )
        XCTAssertTrue(plan.isNoOp)
        // Length-only fingerprints keep the deep compare (legacy callers).
        let legacy = AgentLinkedInlineTextUpdatePlan.make(
            previous: state("Hello", fingerprint: 5, content: false),
            next: state("Hallo", fingerprint: 5, content: false)
        )
        XCTAssertTrue(legacy.storageDirty, "without a content fingerprint, differing text must still mark storage dirty")
        // Real source fingerprints differ when the text differs.
        XCTAssertNotEqual(
            AgentMessageMarkdown.sourceFingerprint(for: "Hello"),
            AgentMessageMarkdown.sourceFingerprint(for: "Hello!")
        )
        XCTAssertEqual(
            AgentMessageMarkdown.sourceFingerprint(for: "same"),
            AgentMessageMarkdown.sourceFingerprint(for: "same")
        )
    }

    // MARK: AA-20 source pin

    func test_turnViewDoesNotComputeTheFullTurnRenderModel() throws {
        // WHY: `turnView` consumed only `turnPlans` from `turnRenderInputs(for:)`
        // but paid, for the live turn on every body pass, the assistant-text
        // dedupe against every persisted message (O(items × messages × body)).
        let source = try String(contentsOf: sourceURL("Sources/Surfaces/AgentAppSurface.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private func turnView("))
        let slice = String(source[start.upperBound...].prefix(2_500))
        XCTAssertFalse(slice.contains("turnRenderInputs(for:"), "turnView must only filter the turn's plans")
        XCTAssertTrue(slice.contains("vm.timeline.proposedPlans.filter"))
        XCTAssertFalse(source.contains("private func turnRenderInputs(for turn:"), "the per-turn render-input plumbing on the view is dead once turnView stops calling it")
    }

    private func sourceURL(_ relative: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relative)
    }
}
