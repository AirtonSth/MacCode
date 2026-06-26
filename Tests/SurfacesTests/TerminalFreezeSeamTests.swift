import XCTest
@testable import Surfaces

/// Pure-seam regressions for two freeze fixes whose AppKit wiring can't be
/// unit-tested without a window server, but whose decision logic can.
final class TerminalFreezeSeamTests: XCTestCase {

    // MARK: - audit #3: stuck-hidden detection

    func test_stuckHidden_trueWhenLogicallyHiddenButViewOnScreen() {
        XCTAssertTrue(
            TerminalSurface.isLikelyStuckHidden(isVisible: false, viewDefinitelyOnScreen: true),
            "a surface that believes it is hidden while its view is provably on a key on-screen window is a reconcile desync — must self-heal")
    }

    func test_stuckHidden_falseWhenCorrectlyHidden() {
        XCTAssertFalse(
            TerminalSurface.isLikelyStuckHidden(isVisible: false, viewDefinitelyOnScreen: false),
            "a correctly hidden surface (view not on screen) must NOT be force-revealed")
    }

    func test_stuckHidden_falseWhenAlreadyVisible() {
        XCTAssertFalse(
            TerminalSurface.isLikelyStuckHidden(isVisible: true, viewDefinitelyOnScreen: true),
            "an already-visible surface is not stuck")
        XCTAssertFalse(
            TerminalSurface.isLikelyStuckHidden(isVisible: true, viewDefinitelyOnScreen: false),
            "an already-visible surface is not stuck regardless of the on-screen probe")
    }

    // MARK: - audit #5: hidden-backlog drain deadline

    func test_drainRearm_allowedBeforeDeadline() {
        let now = Date(timeIntervalSince1970: 1000)
        let deadline = Date(timeIntervalSince1970: 1001)   // 1s in the future
        XCTAssertTrue(
            TerminalSurface.shouldRearmHiddenBacklogDrain(now: now, deadline: deadline),
            "before the absolute deadline the drain may keep re-arming its quiet-delay completion")
    }

    func test_drainRearm_stopsAtOrPastDeadline() {
        let deadline = Date(timeIntervalSince1970: 1000)
        XCTAssertFalse(
            TerminalSurface.shouldRearmHiddenBacklogDrain(now: deadline, deadline: deadline),
            "at the deadline the drain must stop re-arming and force-complete — otherwise a never-quiet stream latches canRender false (the frozen-frame bug)")
        XCTAssertFalse(
            TerminalSurface.shouldRearmHiddenBacklogDrain(now: Date(timeIntervalSince1970: 1005), deadline: deadline),
            "past the deadline the drain must force-complete")
    }

    func test_drainRearm_allowedWhenNoDeadlineSet() {
        XCTAssertTrue(
            TerminalSurface.shouldRearmHiddenBacklogDrain(now: Date(timeIntervalSince1970: 1000), deadline: nil),
            "with no deadline recorded (drain not started) the seam is permissive")
    }
}
