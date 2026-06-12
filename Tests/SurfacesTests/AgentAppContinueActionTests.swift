import XCTest
@testable import Surfaces
import AgentRuntime
import CoreModel

/// Tests for UX-MAC_AGENT-CONTINUE: showsContinueAction seam.
///
/// WHY: a relaunch-interrupted thread must be one-click resumable via the
/// inline Continue action. The pure seam is tested in isolation so the
/// preconditions are precisely expressed and cannot regress silently.
///
/// showsContinueAction(hasRecoverableContext:runActive:) must return:
///   true  when the thread has a recoverable context AND no run is active
///   false when the run is already active (Continue would start a duplicate run)
///   false when there is no recoverable context (nothing to resume)
final class AgentAppContinueActionTests: XCTestCase {

    // MARK: - showsContinueAction seam

    /// WHY: the primary case -- a relaunch-interrupted thread with a saved
    /// resume cursor and no run in flight must show the Continue button so
    /// the user can resume without retyping.
    func test_showsContinueAction_recoverableAndNotRunning_returnsTrue() {
        XCTAssertTrue(
            AgentAppViewModel.showsContinueAction(hasRecoverableContext: true, runActive: false),
            "Continue must be shown when the thread has a recoverable context and no run is active"
        )
    }

    /// WHY: if a run is already active the thread is resuming; showing Continue
    /// at the same time would let the user start a duplicate run on the same
    /// provider session.
    func test_showsContinueAction_recoverableButRunActive_returnsFalse() {
        XCTAssertFalse(
            AgentAppViewModel.showsContinueAction(hasRecoverableContext: true, runActive: true),
            "Continue must be hidden while a run is already active on this thread"
        )
    }

    /// WHY: without a recoverable context there is nothing for Continue to
    /// resume -- showing the button would produce a no-op or error.
    func test_showsContinueAction_noRecoverableContext_returnsFalse() {
        XCTAssertFalse(
            AgentAppViewModel.showsContinueAction(hasRecoverableContext: false, runActive: false),
            "Continue must be hidden when the thread has no recoverable provider session"
        )
    }

    /// WHY: the worst-case combination -- both guards false -- must also return
    /// false; the function must never produce true when context is absent.
    func test_showsContinueAction_noRecoverableAndRunActive_returnsFalse() {
        XCTAssertFalse(
            AgentAppViewModel.showsContinueAction(hasRecoverableContext: false, runActive: true),
            "Continue must be hidden when there is no recoverable context and a run is active"
        )
    }
}
