import XCTest
import AppKit
import CoreModel
import DesignSystemKit
import Persistence
import AgentRuntime
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

    // MARK: AA-31 / AA-29

    func test_hiddenPersistedContentKeyPartsComposeToTheFullKey() {
        // WHY: the view now caches the per-message part (by messagesGeneration)
        // and per-finished-turn parts instead of re-hashing every assistant text
        // on each delta. The composition must stay byte-identical to the
        // single-pass key so the existing hide-set memo semantics hold.
        let messages = [
            AgentMessage(threadId: AgentThreadID(), role: .user, content: "question"),
            AgentMessage(threadId: AgentThreadID(), role: .assistant, content: "answer one"),
            AgentMessage(threadId: AgentThreadID(), role: .assistant, content: "answer two")
        ]
        var s = AssistantTimelineState()
        s.apply(.turnStarted(turnId: "t1"))
        s.apply(.itemStarted(item: AssistantItem(id: "a", turnId: "t1", type: .assistantMessage, body: "answer one", startedAtMs: 1)))
        s.apply(.turnCompleted(turnId: "t1", finalMessage: "answer one"))
        s.apply(.turnStarted(turnId: "t2"))
        s.apply(.itemStarted(item: AssistantItem(id: "b", turnId: "t2", type: .assistantMessage, body: "partial", startedAtMs: 2)))
        var composed = AgentAppView.hiddenPersistedMessagesKeyPart(messages: messages)
        composed += "|t\(s.turns.count)"
        for turn in s.turns { composed += AgentAppView.hiddenPersistedTurnKeyPart(turn) }
        XCTAssertEqual(
            composed,
            AgentAppView.hiddenPersistedAssistantContentKey(messages: messages, timelineTurns: s.turns)
        )
        // A finished turn's part is stable; the live turn's part follows its body.
        let before = AgentAppView.hiddenPersistedTurnKeyPart(s.turns[1])
        s.apply(.itemDelta(itemId: "b", bodyAppend: " more", outputAppend: nil, summary: nil))
        XCTAssertNotEqual(AgentAppView.hiddenPersistedTurnKeyPart(s.turns[1]), before)
    }

    @MainActor
    func test_messagesGenerationMovesOnlyWhenMessagesChange() {
        let state = AgentTranscriptState()
        let start = state.messagesGeneration
        let message = AgentMessage(threadId: AgentThreadID(), role: .assistant, content: "hello")
        state.messages = [message]
        XCTAssertEqual(state.messagesGeneration, start + 1)
        state.messages = [message]
        XCTAssertEqual(state.messagesGeneration, start + 1, "re-assigning equal messages is not a change")
        var timeline = AssistantTimelineState()
        timeline.apply(.turnStarted(turnId: "t"))
        state.timeline = timeline
        XCTAssertEqual(state.messagesGeneration, start + 1, "timeline changes must not invalidate the message digests")
    }

    func test_viewModelNoLongerBuildsTheUnreadTimelineItemIndex() throws {
        // WHY (AA-29): TimelineItemIndex was built O(total items) on every thread
        // open, replay and refused-event path and never read in production.
        let source = try String(contentsOf: sourceURL("Sources/Surfaces/AgentAppSurface.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("timelineItemIndex"), "no per-open/replay index rebuilds without a reader")
    }

    // MARK: AA-32

    func test_inlineCacheKeyIsTheSourceFingerprintSoRowsHashOnce() {
        // WHY: AgentLinkedInlineText hashed its text twice per body pass — once
        // for the inline NSCache key, once for the text view's fingerprint. The
        // two derivations must stay identical so one hash can serve both, and
        // a precomputed fingerprint must hit the same cache entry.
        let text = "Deploy finished; see `Package.swift` for the pinned version."
        let fingerprint = AgentMessageMarkdown.sourceFingerprint(for: text)
        XCTAssertEqual(
            AgentMessageMarkdown.cacheKey(for: text),
            AgentMessageMarkdown.cacheKey(for: text, fingerprint: fingerprint)
        )
        let plain = AgentMessageMarkdown.attributedInline(text)
        let computeAfterPlain = AgentMessageMarkdown.inlineComputeCountForTesting
        let viaFingerprint = AgentMessageMarkdown.attributedInline(text, fingerprint: fingerprint)
        XCTAssertEqual(plain, viaFingerprint)
        XCTAssertEqual(
            AgentMessageMarkdown.inlineComputeCountForTesting,
            computeAfterPlain,
            "the precomputed fingerprint must address the same cache entry (no re-parse)"
        )
        let source = try? String(contentsOf: sourceURL("Sources/Surfaces/AgentLinkedInlineText.swift"), encoding: .utf8)
        XCTAssertEqual(source?.components(separatedBy: "sourceFingerprint(for: text)").count, 2, "the row computes its fingerprint exactly once")
    }

    // MARK: S-02

    func test_toolCommandPreviewReusesTheMemoizedToolInputParse() {
        // WHY: a visible tool row derives label, L2 summary and the expanded
        // command from the same input JSON on every body pass; each derivation
        // re-parsed it. One parse per body string, shared with rawShellCommand.
        let body = "{\"command\":\"swift test --filter TranscriptGrowthPerf\",\"timeout\":120000}"
        let item = AssistantItem(id: "tool-\(UUID().uuidString)", turnId: "t", type: .tool, body: body, startedAtMs: 1)
        let before = AgentTimelineItemPresentation.toolInputObjectComputeCountForTesting
        let preview = AgentTimelineItemPresentation.toolCommandPreview(for: item)
        XCTAssertEqual(preview, "swift test --filter TranscriptGrowthPerf")
        let parsesAfterFirst = AgentTimelineItemPresentation.toolInputObjectComputeCountForTesting
        XCTAssertLessThanOrEqual(parsesAfterFirst - before, 1, "the first preview may parse once")
        _ = AgentTimelineItemPresentation.toolCommandPreview(for: item)
        _ = AgentTimelineItemPresentation.toolCommandSummary(for: item)
        _ = AgentTimelineItemPresentation.rawShellCommand(for: item)
        _ = AgentTimelineItemPresentation.toolDisplayLabel(for: item)
        XCTAssertEqual(
            AgentTimelineItemPresentation.toolInputObjectComputeCountForTesting,
            parsesAfterFirst,
            "label, summary, preview and raw command must share the single memoized parse"
        )
    }

    // MARK: AA-20 source pin

    @MainActor
    func test_composerSuggestionsMemoHitsOnIdenticalInputs() throws {
        // WHY: composerSuggestions rebuilt slash/mention matches on every
        // SwiftUI body pass even when prompt, caret, and bots were unchanged.
        let tmp = NSTemporaryDirectory() + "rc2-composer-memo-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [:]
        )
        let vm = AgentAppViewModel(
            workspaceID: WorkspaceID(),
            cwd: tmp,
            coordinator: coordinator,
            threadRepo: threadRepo,
            messageRepo: messageRepo
        )
        let bot = BotDefinition(handle: "quinn", name: "Quinn", title: "", description: "")
        vm.mentionableBotsProvider = { [bot] }
        vm.prompt = "@q"
        vm.composerCursorOffset = vm.prompt.utf16.count
        let first = vm.composerSuggestions
        let afterFirst = vm.composerSuggestionComputeCountForTesting
        XCTAssertFalse(first.isEmpty)
        _ = vm.composerSuggestions
        _ = vm.composerSuggestions
        XCTAssertEqual(
            vm.composerSuggestionComputeCountForTesting,
            afterFirst,
            "identical prompt/caret/bots must reuse the memo"
        )
        vm.prompt = "@qu"
        _ = vm.composerSuggestions
        XCTAssertEqual(
            vm.composerSuggestionComputeCountForTesting,
            afterFirst + 1,
            "a prompt change must recompute suggestions"
        )
    }

    func test_messageRowDoesNotCallMentionableBotsProvider() throws {
        // WHY: each user/peer row used to recopy the bot list. The timeline
        // column snapshots once and threads the array down.
        let source = try String(contentsOf: sourceURL("Sources/Surfaces/AgentAppSurface.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private func messageRow("))
        let slice = String(source[start.upperBound...].prefix(3_500))
        XCTAssertFalse(
            slice.contains("mentionableBotsProvider()"),
            "messageRow must reuse the parent snapshot"
        )
        XCTAssertTrue(slice.contains("mentionableBots: [BotDefinition]"))
    }

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
