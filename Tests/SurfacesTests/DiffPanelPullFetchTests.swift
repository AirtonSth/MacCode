import XCTest
import AgentRuntime
@testable import Surfaces

/// Unit tests for the pull/fetch error-humanizer extensions and the
/// FSEvents debounce-decision helper added in P2 (Pull/Fetch + auto-refresh).
///
/// WHY these tests exist:
/// - `humanizeError` must map well-known pull/fetch stderr patterns to
///   actionable copy so the user knows exactly what went wrong and what
///   to do next. A passthrough-on-unknown guard prevents the panel from
///   eating real git messages the user needs to act on.
/// - `DiffPanelViewModel.shouldRefresh(elapsed:)` is the only stateful
///   decision in the FSEvents path that is expressible as a pure function;
///   testing it here prevents regressions to the debounce logic without
///   needing FSEvents infrastructure.
///
/// Non-@MainActor: all helpers under test are pure static functions with
/// no @MainActor annotation, so the test class does not need one.
final class DiffPanelPullFetchTests: XCTestCase {

    // MARK: - humanizeError: pull/fetch patterns

    func test_humanize_conflictKeyword_returnsConflictCopy() {
        // Real git pull stderr when conflicts prevent a merge:
        //   "CONFLICT (content): Merge conflict in foo.swift"
        let raw = "CONFLICT (content): Merge conflict in foo.swift\nAutomatic merge failed;"
        let result = GitDiff.humanizeError(raw)
        XCTAssertTrue(result.lowercased().contains("conflict"),
                      "merge conflict stderr must produce copy naming 'conflict' so the user knows they need to resolve files - got: \(result)")
        XCTAssertNotEqual(result, raw,
                          "a known conflict pattern must be replaced with friendly copy, not echoed raw")
    }

    func test_humanize_mergeConflictPhrase_returnsConflictCopy() {
        // Lowercase variant as it might appear in different git versions.
        let raw = "error: merge conflict in bar.txt"
        let result = GitDiff.humanizeError(raw)
        XCTAssertTrue(result.lowercased().contains("conflict"),
                      "lowercase 'merge conflict' must match the conflict pattern - got: \(result)")
        XCTAssertNotEqual(result, raw)
    }

    func test_humanize_cannotFastForward_returnsDivergenceCopy() {
        // git pull --ff-only stderr when the branch has diverged:
        //   "fatal: Not possible to fast-forward, aborting."
        let raw = "fatal: Not possible to fast-forward, aborting."
        let result = GitDiff.humanizeError(raw)
        XCTAssertTrue(
            result.lowercased().contains("fast-forward") || result.lowercased().contains("diverged"),
            "cannot fast-forward must produce copy about diverged history or fast-forward - got: \(result)"
        )
        XCTAssertNotEqual(result, raw)
    }

    func test_humanize_cannotFastForwardVariant_returnsDivergenceCopy() {
        // Alternate phrasing from older git versions.
        let raw = "error: Cannot fast-forward your working tree."
        let result = GitDiff.humanizeError(raw)
        XCTAssertTrue(
            result.lowercased().contains("fast-forward") || result.lowercased().contains("diverged"),
            "alternate 'cannot fast-forward' phrasing must match - got: \(result)"
        )
        XCTAssertNotEqual(result, raw)
    }

    func test_humanize_localChangesOverwritten_returnsStashCopy() {
        // git pull stderr when uncommitted local changes would be overwritten:
        //   "error: Your local changes to the following files would be overwritten by merge:"
        let raw = "error: Your local changes to the following files would be overwritten by merge:\n\tReadme.md"
        let result = GitDiff.humanizeError(raw)
        XCTAssertTrue(
            result.lowercased().contains("stash") || result.lowercased().contains("commit"),
            "local-changes-overwritten must tell the user to stash or commit - got: \(result)"
        )
        XCTAssertNotEqual(result, raw)
    }

    func test_humanize_alreadyUpToDate_returnsFriendlyCopy() {
        // git pull when there is nothing to pull:
        //   "Already up to date."
        let raw = "Already up to date."
        let result = GitDiff.humanizeError(raw)
        XCTAssertTrue(
            result.lowercased().contains("already up to date") || result.lowercased().contains("nothing to pull"),
            "already-up-to-date must produce copy confirming no work was needed - got: \(result)"
        )
        XCTAssertNotEqual(result, raw,
                          "even a benign message should be translated to friendlier copy")
    }

    // MARK: - humanizeError: existing patterns still hold

    func test_humanize_authFailure_returnsFriendlyCopy() {
        // Existing auth pattern must still match after the pull additions.
        let raw = "remote: HTTP Basic: Access denied\nfatal: Authentication failed for 'https://github.com/org/repo.git/'"
        let result = GitDiff.humanizeError(raw)
        XCTAssertTrue(
            result.lowercased().contains("auth") || result.lowercased().contains("credential") || result.lowercased().contains("ssh"),
            "auth failure must still produce friendly copy - got: \(result)"
        )
        XCTAssertNotEqual(result, raw)
    }

    func test_humanize_noUpstream_returnsFriendlyCopy() {
        // Existing upstream pattern must still match.
        let raw = "fatal: The current branch feature has no upstream branch."
        let result = GitDiff.humanizeError(raw)
        XCTAssertTrue(
            result.lowercased().contains("upstream"),
            "no-upstream error must still produce friendly copy - got: \(result)"
        )
        XCTAssertNotEqual(result, raw)
    }

    // MARK: - humanizeError: passthrough for unknown patterns

    func test_humanize_unknownMessage_passthroughUnchanged() {
        // WHY: if we replace an unknown error with generic copy the user loses
        // the actual git message they need to diagnose the problem. Passthrough
        // is the correct behaviour for messages we have not classified.
        let raw = "fatal: some completely new git error that we have not seen before xyzzy"
        let result = GitDiff.humanizeError(raw)
        XCTAssertEqual(result, raw,
                       "unrecognised git messages must pass through unchanged so no information is lost")
    }

    func test_humanize_emptyString_passthroughUnchanged() {
        // Edge case: empty stderr should not produce phantom copy.
        XCTAssertEqual(GitDiff.humanizeError(""), "",
                       "empty stderr must pass through as empty - no phantom copy injected")
    }

    // MARK: - FSEvents debounce helper

    func test_shouldRefresh_elapsedAboveThreshold_returnsTrue() {
        // WHY: when enough time has passed since the last refresh the FSEvent
        // callback must trigger a new refresh so the panel stays in sync with
        // agent-driven working-tree mutations.
        let interval = DiffPanelViewModel.fsDebounceInterval
        XCTAssertTrue(
            DiffPanelViewModel.shouldRefresh(elapsed: interval),
            "elapsed == threshold must be treated as ready-to-refresh (boundary inclusive)"
        )
        XCTAssertTrue(
            DiffPanelViewModel.shouldRefresh(elapsed: interval + 1),
            "elapsed > threshold must return true - the debounce window has expired"
        )
    }

    func test_shouldRefresh_elapsedBelowThreshold_returnsFalse() {
        // WHY: rapid file-system events (save storms) must be coalesced into a
        // single refresh. Returning false here suppresses the extra callbacks
        // so git is not hammered on every keystroke.
        let interval = DiffPanelViewModel.fsDebounceInterval
        XCTAssertFalse(
            DiffPanelViewModel.shouldRefresh(elapsed: 0),
            "zero elapsed must not trigger a refresh - the debounce window has not started"
        )
        XCTAssertFalse(
            DiffPanelViewModel.shouldRefresh(elapsed: interval - 0.001),
            "elapsed just below threshold must not trigger a refresh - debounce window still active"
        )
    }

    func test_shouldRefresh_negativeElapsed_returnsFalse() {
        // Defensive: if the clock skews backwards the helper must not fire.
        XCTAssertFalse(
            DiffPanelViewModel.shouldRefresh(elapsed: -1),
            "negative elapsed (clock skew) must not trigger a refresh"
        )
    }
}
