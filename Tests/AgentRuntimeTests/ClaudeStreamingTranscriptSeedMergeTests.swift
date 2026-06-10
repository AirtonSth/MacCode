import XCTest
import CoreModel
@testable import AgentRuntime

/// Tests for the pure transcript-seed seams extracted so that the slow disk
/// read in ClaudeTranscriptStore.readSession happens OUTSIDE the adapter lock.
///
/// Why these tests matter (perf fix intent, not just behavior):
/// - The lock-scope decision was hoisted into pure helpers so the adapter can
///   release `lock` before the recursive ~/.claude/projects enumeration and
///   re-take it only to merge. These tests pin the merge/skip contract that the
///   restructured `seedTranscriptOutsideLock` relies on:
///     * a seeded session is found (transcript merged when there is nothing
///       readable yet),
///     * a concurrent live turn that produced a readable turn during the
///       unlocked disk read is NOT clobbered (no double-seed),
///     * disk is not even touched when it would be wasted.
/// If the merge guard regressed (e.g. always overwrote events), these fail.
final class ClaudeStreamingTranscriptSeedMergeTests: XCTestCase {

    private func turn(_ id: String) -> AssistantEvent {
        .turnCompleted(turnId: id, finalMessage: nil)
    }

    private func emptyDelta(_ id: String) -> AssistantEvent {
        // Non-readable: no body/output appended.
        .itemDelta(itemId: id, bodyAppend: nil, outputAppend: nil, summary: nil)
    }

    // MARK: - transcriptSeedMerge

    func test_mergeSeedsWhenNoReadableTurnYet() {
        // Session has only a placeholder event with no readable content; the
        // disk transcript carries real history -> it must be adopted so a
        // recovered session is found in readThread after restart.
        let current = [emptyDelta("i1")]
        let transcript = [turn("t1"), turn("t2")]

        let merged = ClaudeStreamingCLIAdapter.transcriptSeedMerge(
            currentEvents: current,
            transcriptEvents: transcript,
            maxReadableEvents: 5_000
        )

        XCTAssertEqual(merged?.compactMap { event -> String? in
            if case .turnCompleted(let id, _) = event { return id } else { return nil }
        }, ["t1", "t2"],
        "transcript must seed in-memory events when the session has no readable turn yet")
    }

    func test_mergeSkipsWhenLiveReadableTurnAlreadyPresent() {
        // Models the race: while the lock was released for the disk read, a live
        // turn completed and produced a readable turn. The stale transcript must
        // NOT clobber it -> merge returns nil so live events are preserved.
        let current = [turn("live-1")]
        let transcript = [turn("stale-1"), turn("stale-2")]

        let merged = ClaudeStreamingCLIAdapter.transcriptSeedMerge(
            currentEvents: current,
            transcriptEvents: transcript,
            maxReadableEvents: 5_000
        )

        XCTAssertNil(merged,
            "a live readable turn that appeared during the unlocked disk read must not be overwritten by a stale transcript")
    }

    func test_mergeSkipsWhenTranscriptEmpty() {
        let merged = ClaudeStreamingCLIAdapter.transcriptSeedMerge(
            currentEvents: [emptyDelta("i1")],
            transcriptEvents: [],
            maxReadableEvents: 5_000
        )

        XCTAssertNil(merged,
            "an empty transcript must not replace existing events with an empty array")
    }

    func test_mergeCapsToMaxReadableEvents() {
        // The disk read can return more than the cap; the merge must keep only
        // the most recent maxReadableEvents so memory stays bounded.
        let transcript = (0..<10).map { turn("t\($0)") }

        let merged = ClaudeStreamingCLIAdapter.transcriptSeedMerge(
            currentEvents: [emptyDelta("i1")],
            transcriptEvents: transcript,
            maxReadableEvents: 3
        )

        XCTAssertEqual(merged?.compactMap { event -> String? in
            if case .turnCompleted(let id, _) = event { return id } else { return nil }
        }, ["t7", "t8", "t9"],
        "merge must retain only the most recent maxReadableEvents (suffix), matching prior in-lock behavior")
    }

    // MARK: - shouldReadTranscript (pre-read disk guard)

    func test_shouldReadTrueWhenThreadKnownAndNoReadableTurn() {
        XCTAssertTrue(
            ClaudeStreamingCLIAdapter.shouldReadTranscript(
                currentEvents: [emptyDelta("i1")],
                providerThreadId: "sess-abc"
            ),
            "disk read is warranted when there is a provider thread and no readable turn yet")
    }

    func test_shouldReadFalseWhenAlreadyHasReadableTurn() {
        XCTAssertFalse(
            ClaudeStreamingCLIAdapter.shouldReadTranscript(
                currentEvents: [turn("t1")],
                providerThreadId: "sess-abc"
            ),
            "must avoid the disk walk entirely when a readable turn already exists")
    }

    func test_shouldReadFalseWhenProviderThreadMissingOrEmpty() {
        XCTAssertFalse(
            ClaudeStreamingCLIAdapter.shouldReadTranscript(
                currentEvents: [emptyDelta("i1")],
                providerThreadId: nil
            ),
            "no provider thread => nothing to read => skip disk")
        XCTAssertFalse(
            ClaudeStreamingCLIAdapter.shouldReadTranscript(
                currentEvents: [emptyDelta("i1")],
                providerThreadId: ""
            ),
            "empty provider thread => skip disk")
    }
}
