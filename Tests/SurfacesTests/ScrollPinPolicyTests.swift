import XCTest
@testable import Surfaces

/// T040 - unit harness for the pin/unpin policy extracted from TimelineScrollFollower.
///
/// WHY: PERF-MAC_AGENT-021 identified a layout-storm regression caused by per-delta
/// SwiftUI @State writes. The policy is now a pure function (ScrollPinPolicy.evaluate)
/// so we can assert the exact conditions that produce each transition without any
/// AppKit geometry or scroll view.
///
/// Each test encodes the business rule it guards, not just the return value.
final class ScrollPinPolicyTests: XCTestCase {

    // MARK: - reachedBottom

    /// gap == 0: flush at the bottom => must re-pin.
    func testExactlyAtBottomPins() {
        XCTAssertEqual(
            ScrollPinPolicy.evaluate(originDelta: 0, gap: 0, slack: 4, userOwned: false),
            .reachedBottom,
            "gap=0 is inside slack(4); must re-pin so streaming content stays visible"
        )
    }

    /// gap == slack: boundary case - still within tolerance => must re-pin.
    func testGapEqualsSlackPins() {
        XCTAssertEqual(
            ScrollPinPolicy.evaluate(originDelta: 0, gap: 4, slack: 4, userOwned: true),
            .reachedBottom,
            "gap <= slack is the at-bottom definition; boundary must re-pin"
        )
    }

    /// gap < slack: anywhere inside the slack band => must re-pin.
    func testGapBelowSlackPins() {
        XCTAssertEqual(
            ScrollPinPolicy.evaluate(originDelta: 0, gap: 2, slack: 4, userOwned: false),
            .reachedBottom,
            "gap inside slack band must re-pin regardless of originDelta"
        )
    }

    /// gap <= slack takes priority over a concurrent origin drop (pathological: layout
    /// forced origin up while content also grew enough to close the gap).
    func testReachedBottomTakesPriorityOverOriginDrop() {
        XCTAssertEqual(
            ScrollPinPolicy.evaluate(originDelta: -10, gap: 1, slack: 4, userOwned: true),
            .reachedBottom,
            "atBottom wins over originDelta<0; reaching bottom always re-pins"
        )
    }

    // MARK: - scrolledAway

    /// User-owned origin drop while away from the bottom: genuine audit scroll-up.
    func testUserOwnedOriginDropScrollsAway() {
        XCTAssertEqual(
            ScrollPinPolicy.evaluate(originDelta: -1, gap: 200, slack: 4, userOwned: true),
            .scrolledAway,
            "userOwned + originDelta < -0.5 while gap > slack is the ONLY unpin signal"
        )
    }

    /// Larger user-owned origin drop: still scrolledAway (not a different case).
    func testLargeUserOwnedOriginDropScrollsAway() {
        XCTAssertEqual(
            ScrollPinPolicy.evaluate(originDelta: -100, gap: 500, slack: 4, userOwned: true),
            .scrolledAway,
            "magnitude of drop does not change the decision; any drop > 0.5pt while away = scrolledAway"
        )
    }

    /// WHY: stream growth / Lazy materialize / programmatic snap move origin without
    /// a user gesture. Origin-only unpin false-fired the FAB mid-shell stream.
    func testNonUserOwnedOriginDropDoesNotUnpin() {
        XCTAssertEqual(
            ScrollPinPolicy.evaluate(originDelta: -100, gap: 500, slack: 4, userOwned: false),
            .unchanged,
            "layout/programmatic origin jitter must not clear pin or show FAB"
        )
    }

    /// Programmatic follow lag (gap open, origin flat, not user-owned): stay pinned.
    func testContentGrowthGapWithoutUserOwnedIsUnchanged() {
        XCTAssertEqual(
            ScrollPinPolicy.evaluate(originDelta: 0, gap: 80, slack: 4, userOwned: false),
            .unchanged,
            "follow lag while pinned is AppKit snap work, not an audit unpin"
        )
    }

    // MARK: - unchanged

    /// Origin drop exactly at noise threshold: must NOT fire scrolledAway (avoids
    /// sub-pixel layout jitter being misread as a user scroll).
    func testOriginDropAtNoiseThresholdIsUnchanged() {
        XCTAssertEqual(
            ScrollPinPolicy.evaluate(originDelta: -0.5, gap: 200, slack: 4, userOwned: true),
            .unchanged,
            "originDelta == -0.5 is the noise floor; must not trigger scrolledAway (< -0.5 required)"
        )
    }

    /// Origin unchanged, away from bottom: no transition (content grew but user did not scroll).
    func testNoMovementAwayFromBottomIsUnchanged() {
        XCTAssertEqual(
            ScrollPinPolicy.evaluate(originDelta: 0, gap: 50, slack: 4, userOwned: true),
            .unchanged,
            "content growth without origin change must not alter pin state"
        )
    }

    /// Origin increased (scroll view grew its document upward, rare): not a user scroll-up.
    func testPositiveOriginDeltaIsUnchanged() {
        XCTAssertEqual(
            ScrollPinPolicy.evaluate(originDelta: 5, gap: 100, slack: 4, userOwned: true),
            .unchanged,
            "origin increasing while away from bottom is not a user scroll-up; no state change"
        )
    }

    /// Small sub-threshold drop while away: noise, must be unchanged.
    func testSubThresholdDropIsUnchanged() {
        XCTAssertEqual(
            ScrollPinPolicy.evaluate(originDelta: -0.3, gap: 100, slack: 4, userOwned: true),
            .unchanged,
            "drop < 0.5pt is within pixel-rounding noise; must not fire scrolledAway"
        )
    }

    // MARK: - slack variation

    /// Custom slack of 0: only gap==0 counts as atBottom.
    func testZeroSlackOnlyExactFlush() {
        XCTAssertEqual(
            ScrollPinPolicy.evaluate(originDelta: 0, gap: 0, slack: 0, userOwned: false),
            .reachedBottom
        )
        XCTAssertEqual(
            ScrollPinPolicy.evaluate(originDelta: 0, gap: 1, slack: 0, userOwned: false),
            .unchanged,
            "gap=1 with slack=0 is outside atBottom; no pin"
        )
    }

    /// Large slack: 20pt gap still inside tolerance => re-pin.
    func testLargeSlackIncludesWiderGap() {
        XCTAssertEqual(
            ScrollPinPolicy.evaluate(originDelta: 0, gap: 20, slack: 20, userOwned: false),
            .reachedBottom,
            "gap <= slack(20) must re-pin even when gap is large"
        )
    }

    /// WHY: every new message used force=true and re-pinned auditors mid-stream.
    /// Programmatic follow must respect the pin; only FAB/send/open use force.
    func testProgrammaticFollowRespectsAuditScrollUp() {
        XCTAssertFalse(
            ScrollPinPolicy.shouldProgrammaticFollow(pinned: false, force: false),
            "stream/message ticks must not follow while user scrolled up to audit"
        )
        XCTAssertTrue(
            ScrollPinPolicy.shouldProgrammaticFollow(pinned: true, force: false),
            "still pinned: stream may follow"
        )
        XCTAssertTrue(
            ScrollPinPolicy.shouldProgrammaticFollow(pinned: false, force: true),
            "FAB / send / open may rejoin intentionally"
        )
    }

    // MARK: - ScrollBottomGeometry (flip-aware)

    /// Flipped document: at bottom origin = content - visible, gap = 0.
    func testFlippedGapAtBottomIsZero() {
        let gap = ScrollBottomGeometry.gap(
            documentHeight: 1000,
            visibleOriginY: 200,
            visibleHeight: 800,
            isFlipped: true
        )
        XCTAssertEqual(gap, 0, accuracy: 0.001,
                       "flipped at-bottom must report gap 0 so pin re-arms")
    }

    /// Flipped document: scrolled up leaves a positive gap.
    func testFlippedGapWhenScrolledUp() {
        let gap = ScrollBottomGeometry.gap(
            documentHeight: 1000,
            visibleOriginY: 0,
            visibleHeight: 800,
            isFlipped: true
        )
        XCTAssertEqual(gap, 200, accuracy: 0.001,
                       "200pt above bottom must leave gap 200")
    }

    /// Non-flipped: origin 0 is bottom → gap 0.
    func testNonFlippedGapAtBottomIsZero() {
        let gap = ScrollBottomGeometry.gap(
            documentHeight: 1000,
            visibleOriginY: 0,
            visibleHeight: 800,
            isFlipped: false
        )
        XCTAssertEqual(gap, 0, accuracy: 0.001,
                       "non-flipped origin 0 is document bottom")
    }

    /// Non-flipped: larger origin is farther from bottom.
    func testNonFlippedGapWhenScrolledUp() {
        let gap = ScrollBottomGeometry.gap(
            documentHeight: 1000,
            visibleOriginY: 200,
            visibleHeight: 800,
            isFlipped: false
        )
        XCTAssertEqual(gap, 200, accuracy: 0.001)
    }

    func testMaxScrollOriginYFlippedAndNot() {
        XCTAssertEqual(
            ScrollBottomGeometry.maxScrollOriginY(documentHeight: 1000, visibleHeight: 800, isFlipped: true),
            200,
            accuracy: 0.001,
            "flipped bottom target is content - visible"
        )
        XCTAssertEqual(
            ScrollBottomGeometry.maxScrollOriginY(documentHeight: 1000, visibleHeight: 800, isFlipped: false),
            0,
            accuracy: 0.001,
            "non-flipped bottom target is origin 0"
        )
    }

    /// Scroll toward top must produce a negative delta in both coordinate systems.
    func testOriginDeltaTowardTopIsNegativeOnScrollUp() {
        // Flipped: origin drops when scrolling up.
        XCTAssertEqual(
            ScrollBottomGeometry.originDeltaTowardTop(previousOriginY: 100, currentOriginY: 40, isFlipped: true),
            -60,
            accuracy: 0.001
        )
        // Non-flipped: origin rises when scrolling up.
        XCTAssertEqual(
            ScrollBottomGeometry.originDeltaTowardTop(previousOriginY: 40, currentOriginY: 100, isFlipped: false),
            -60,
            accuracy: 0.001
        )
    }

    /// Sticky detach: stream body must not re-arm pin; force token and true bottom may.
    func testShouldAcceptSwiftUIPinStickyDetach() {
        XCTAssertFalse(
            ScrollBottomGeometry.shouldAcceptSwiftUIPin(
                localPinned: false,
                swiftUIPinned: true,
                forceTokenChanged: false,
                geometricallyAtBottom: false
            ),
            "stale stream pinned:true must not re-arm a local detach"
        )
        XCTAssertTrue(
            ScrollBottomGeometry.shouldAcceptSwiftUIPin(
                localPinned: false,
                swiftUIPinned: true,
                forceTokenChanged: true,
                geometricallyAtBottom: false
            ),
            "FAB / send / open force token must re-arm pin"
        )
        XCTAssertTrue(
            ScrollBottomGeometry.shouldAcceptSwiftUIPin(
                localPinned: false,
                swiftUIPinned: true,
                forceTokenChanged: false,
                geometricallyAtBottom: true
            ),
            "user returned to bottom may re-arm from SwiftUI"
        )
        XCTAssertFalse(
            ScrollBottomGeometry.shouldAcceptSwiftUIPin(
                localPinned: false,
                swiftUIPinned: false,
                forceTokenChanged: false,
                geometricallyAtBottom: true
            ),
            "SwiftUI detach always wins"
        )
    }
    /// Stream follow must not dual-scroll content+BOTTOM (multipass jump).
    func test_programmaticScrollTargets_streamUsesBottomOnly() {
        let targets = AgentAppView.programmaticScrollTargets(
            messages: [],
            turns: [],
            force: false
        )
        XCTAssertEqual(targets, ["BOTTOM"])
    }

    /// WHY: force rejoin (open/FAB/send) used content+BOTTOM dual scrollTo and
    /// multipass-jumped the viewport the same way stream did; single BOTTOM only.
    func test_programmaticScrollTargets_forceAlsoBottomOnly() {
        XCTAssertEqual(
            AgentAppView.programmaticScrollTargets(messages: [], turns: [], force: true),
            ["BOTTOM"],
            "force rejoin must not dual-target content then BOTTOM"
        )
    }

}
