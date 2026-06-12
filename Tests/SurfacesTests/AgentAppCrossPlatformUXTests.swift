import XCTest
@testable import Surfaces
import CoreModel
import Persistence
import AgentRuntime

// MARK: - :7 Revert confirmation

/// WHY: rolling back the working tree via agent.checkpoint.revert is irreversible
/// without a prior git commit. Any checkpoint whose status is .ready must demand
/// a destructive confirmation before the revert is executed. Tests here verify the
/// pure predicate seam so the guard cannot be removed without breaking the test.
final class RevertConfirmationSeamTests: XCTestCase {

    func test_needsRevertConfirmation_true_forReadyCheckpoint() {
        // WHY: .ready is the only status where revert is callable; it must always
        // require confirmation to prevent accidental file-tree rollbacks.
        XCTAssertTrue(
            AgentAppView.needsRevertConfirmation(checkpointStatus: .ready),
            "A .ready checkpoint must require a destructive confirmation before reverting"
        )
    }

    func test_needsRevertConfirmation_false_forMissingCheckpoint() {
        // WHY: .missing checkpoints cannot be applied; no confirmation needed
        // (the button is disabled when status != .ready, but the predicate must
        // also return false so tests can verify both branches independently).
        XCTAssertFalse(
            AgentAppView.needsRevertConfirmation(checkpointStatus: .missing),
            ".missing checkpoint must not trigger a confirmation (button is disabled but predicate must be false)"
        )
    }

    func test_needsRevertConfirmation_false_forErrorCheckpoint() {
        // WHY: .error checkpoints are non-applicable; same reasoning as .missing.
        XCTAssertFalse(
            AgentAppView.needsRevertConfirmation(checkpointStatus: .error),
            ".error checkpoint must not trigger a confirmation"
        )
    }
}

// MARK: - :8 resolvedRunStartedAt seam

/// WHY: the Mac IS the host; `AgentRun.startedAt` is the authoritative run clock.
/// When the view calls selectThread on a running thread it must use the persisted
/// start time so "Working for Xs" counts from the real start, not from when the
/// view noticed. These tests verify the pure seam so the regression is caught
/// without any coordinator or DB.
final class ResolvedRunStartedAtTests: XCTestCase {

    func test_resolvedRunStartedAt_persistedWins_overNil() {
        // WHY: selectThread finds a running thread but runStartedAt is nil
        // (first time the view loads). Must use persisted, not Date().
        let persisted = Date(timeIntervalSince1970: 1_000_000)
        let result = AgentAppViewModel.resolvedRunStartedAt(current: nil, persisted: persisted)
        XCTAssertEqual(result, persisted,
                       "persisted must be used when current is nil so elapsed time is accurate")
    }

    func test_resolvedRunStartedAt_persistedWins_overExistingCurrent() {
        // WHY: the view already holds a Date() from a previous selectThread call
        // (e.g. user switched away and back). The persisted value is always more
        // accurate; current must be discarded.
        let persisted = Date(timeIntervalSince1970: 1_000_000)
        let stale = Date(timeIntervalSince1970: 9_000_000)
        let result = AgentAppViewModel.resolvedRunStartedAt(current: stale, persisted: persisted)
        XCTAssertEqual(result, persisted,
                       "persisted must override stale current so elapsed time reflects the real run start")
    }

    func test_resolvedRunStartedAt_fallsBackToCurrentWhenNoPersistedValue() {
        // WHY: the run record may not be committed yet (brief DB write race).
        // In that case current holds the Date() stamped at run launch, which
        // is the best available approximation.
        let current = Date(timeIntervalSince1970: 2_000_000)
        let result = AgentAppViewModel.resolvedRunStartedAt(current: current, persisted: nil)
        XCTAssertEqual(result, current,
                       "when persisted is nil, current must be preserved as the best available start time")
    }

    func test_resolvedRunStartedAt_fallsBackToNowWhenBothNil() {
        // WHY: neither persisted nor current is available (fresh run before the
        // first DB flush and first selectThread). Must not crash; returns a fresh
        // Date() which is as close to correct as possible.
        let before = Date()
        let result = AgentAppViewModel.resolvedRunStartedAt(current: nil, persisted: nil)
        let after = Date()
        XCTAssertGreaterThanOrEqual(result, before,
                                    "fallback Date() must not be in the past relative to the test start")
        XCTAssertLessThanOrEqual(result, after,
                                 "fallback Date() must not be in the future relative to the test end")
    }
}

// MARK: - :9 activeTokenRange cursor-anchored seam

/// WHY: slash-command suggestions must anchor at the cursor so that editing the
/// middle of a multiline prompt (e.g. inserting /skill on line 2 of 3) returns
/// the correct token. The old endIndex anchor returned the LAST token in the
/// buffer regardless of where the cursor was. These tests verify the new cursor-
/// anchored seam. Each test encodes WHY it matters so regressions are caught.
final class ActiveTokenRangeCursorTests: XCTestCase {

    // MARK: - cursor at end of token

    func test_activeTokenRange_cursorAtEnd_returnsToken() {
        // WHY: typing "/foo" with cursor at the end is the common case.
        // The range must cover "/foo" exactly.
        let text = "/foo"
        let range = AgentComposerSuggestions.activeTokenRange(text: text, cursorOffset: 4)
        XCTAssertNotNil(range, "range must be non-nil when cursor is inside a token")
        XCTAssertEqual(String(text[range!]), "/foo",
                       "token must be the full word before the cursor")
    }

    // MARK: - cursor mid-prompt (the bug case)

    func test_activeTokenRange_cursorMidPrompt_returnsTokenAtCursor_notEndToken() {
        // WHY: "do /foo\nother /bar" with cursor right after "/foo" must return
        // "/foo", NOT "/bar". The old endIndex impl returned "/bar". This test
        // fails on the old implementation, proving the cursor-anchored fix works.
        let text = "do /foo\nother /bar"
        // cursor offset 7 = right after "do /foo"
        let offset = 7
        let range = AgentComposerSuggestions.activeTokenRange(text: text, cursorOffset: offset)
        XCTAssertNotNil(range, "cursor inside /foo must yield a range")
        XCTAssertEqual(String(text[range!]), "/foo",
                       "token under cursor (/foo) must be returned, not the final token (/bar)")
    }

    func test_activeTokenRange_cursorAtLineStart_returnsNilForWhitespacePrefix() {
        // WHY: cursor placed at the start of a line (after a newline) has no
        // preceding non-whitespace characters; range must be nil so no stale
        // suggestion appears.
        let text = "hello\n"
        let range = AgentComposerSuggestions.activeTokenRange(text: text, cursorOffset: 6)
        XCTAssertNil(range,
                     "cursor at start of empty line must yield nil (no token to anchor)")
    }

    func test_activeTokenRange_cursorAfterSpace_returnsNil() {
        // WHY: "hello " with cursor right after the space — no incomplete token
        // is being typed, so suggestions must not appear.
        let text = "hello "
        let range = AgentComposerSuggestions.activeTokenRange(text: text, cursorOffset: 6)
        XCTAssertNil(range,
                     "cursor right after whitespace must yield nil (user has not started a new token)")
    }

    func test_activeTokenRange_cursorBeyondEnd_treatsAsEndIndex() {
        // WHY: off-by-one defense — if the NSTextView reports an offset past the
        // string's UTF-16 count (e.g. race during paste), the call must clamp
        // gracefully rather than crash or return garbage.
        let text = "/cmd"
        // cursorOffset == 100 >> text.utf16.count (4); must not crash.
        let range = AgentComposerSuggestions.activeTokenRange(text: text, cursorOffset: 100)
        // Clamped to endIndex == same as "/cmd" at end.
        XCTAssertNotNil(range,
                        "out-of-bounds cursor must clamp to endIndex and return the token rather than crash")
        XCTAssertEqual(String(text[range!]), "/cmd",
                       "clamped cursor must return the last token")
    }

    func test_activeTokenRange_negativeCursorOffset_returnsNil() {
        // WHY: guard against negative offsets from buggy callers.
        let range = AgentComposerSuggestions.activeTokenRange(text: "/cmd", cursorOffset: -1)
        XCTAssertNil(range,
                     "negative cursor offset is invalid and must return nil without crashing")
    }

    // MARK: - suggestions plumbing (integration of cursor seam)

    func test_suggestions_cursorMidPrompt_returnsCorrectSuggestions() {
        // WHY: the full suggestions() entry point must honor cursorOffset so
        // the wrong token at endIndex does not pollute the suggestion list.
        // "done /cle\nnot here /foo" with cursor after "/cle" (offset 9)
        // must suggest /clear, not /foo.
        let text = "done /cle\nnot here /foo"
        let cursor = 9 // right after "/cle"
        let result = AgentComposerSuggestions.suggestions(
            for: text,
            cursorOffset: cursor,
            snapshot: nil,
            localSlashCommands: ["/clear", "/status", "/foo"],
            limit: 8
        )
        let titles = result.map(\.title)
        XCTAssert(titles.contains("/clear"),
                  "suggestions must include /clear which matches the token at cursor (/cle)")
        XCTAssertFalse(titles.contains("/foo"),
                       "/foo does not match /cle and must not appear (old endIndex bug would include it)")
    }
}
