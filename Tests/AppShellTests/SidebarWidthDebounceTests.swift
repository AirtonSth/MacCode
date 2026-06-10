import XCTest
@testable import AppShell

/// Tests for the `sidebarWidthShouldWrite(lastWriteAt:now:interval:)` pure helper.
///
/// WHY these tests matter:
///   - Without debounce, every NSSplitView resize tick during a live drag
///     fires a synchronous SQLite write (~60/s), blocking the main thread.
///   - The helper gates whether a write should occur; incorrect logic would
///     either starve writes (never persisting) or defeat the debounce (still
///     writing every tick).
///
/// All assertions target the pure helper only -- no AppKit, no @MainActor,
/// no async, no flakiness.
final class SidebarWidthDebounceTests: XCTestCase {

    // MARK: - First write (no prior write)

    func test_noLastWrite_alwaysReturnsTrue() {
        // WHY: on first drag there is no previous write; the first idle flush
        // must be allowed so the user's initial position is persisted.
        XCTAssertTrue(
            sidebarWidthShouldWrite(lastWriteAt: nil, now: Date(), interval: 0.3),
            "no prior write => shouldWrite must be true so the first drag is persisted"
        )
    }

    // MARK: - Within debounce interval

    func test_withinInterval_returnsFalse() {
        // WHY: a tick arriving 0.05 s after the last write is a mid-drag event;
        // suppressing it is the entire point of the debounce -- prevents the
        // synchronous-SQLite-per-tick performance regression.
        let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let justAfter = base.addingTimeInterval(0.05)
        XCTAssertFalse(
            sidebarWidthShouldWrite(lastWriteAt: base, now: justAfter, interval: 0.3),
            "tick at +0.05s within 0.3s interval => shouldWrite must be false (debounced)"
        )
    }

    func test_exactlyAtInterval_returnsFalse() {
        // WHY: the boundary is exclusive on the left; a tick arriving at
        // exactly interval seconds is still "within" the window (elapsed < interval).
        // The DispatchWorkItem fires *after* the interval, so this edge case
        // is never reached in practice, but correctness must be precise.
        let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let exact = base.addingTimeInterval(0.3 - 1e-9)
        XCTAssertFalse(
            sidebarWidthShouldWrite(lastWriteAt: base, now: exact, interval: 0.3),
            "tick at exactly interval-epsilon => shouldWrite must be false (still within window)"
        )
    }

    // MARK: - Past debounce interval

    func test_pastInterval_returnsTrue() {
        // WHY: the DispatchWorkItem fires 0.3 s after the last tick; by then
        // elapsed > interval; the write must be allowed so the final drag
        // position is always persisted.
        let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let after = base.addingTimeInterval(0.301)
        XCTAssertTrue(
            sidebarWidthShouldWrite(lastWriteAt: base, now: after, interval: 0.3),
            "tick at +0.301s past 0.3s interval => shouldWrite must be true (idle flush)"
        )
    }

    func test_longAfterInterval_returnsTrue() {
        // WHY: if the user drags, waits several seconds, then drags again,
        // the first new tick must be treated as a fresh idle flush opportunity.
        let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let longAfter = base.addingTimeInterval(5.0)
        XCTAssertTrue(
            sidebarWidthShouldWrite(lastWriteAt: base, now: longAfter, interval: 0.3),
            "tick at +5s well past interval => shouldWrite must be true"
        )
    }

    // MARK: - Custom interval

    func test_customInterval_respectsOverride() {
        // WHY: the helper is parameterised; callers can tune the debounce window
        // without touching helper logic. A 1 s interval must suppress a 0.5 s tick.
        let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let halfSecond = base.addingTimeInterval(0.5)
        XCTAssertFalse(
            sidebarWidthShouldWrite(lastWriteAt: base, now: halfSecond, interval: 1.0),
            "0.5s tick with 1.0s interval => shouldWrite must be false"
        )
        let oneSecond = base.addingTimeInterval(1.001)
        XCTAssertTrue(
            sidebarWidthShouldWrite(lastWriteAt: base, now: oneSecond, interval: 1.0),
            "1.001s tick with 1.0s interval => shouldWrite must be true"
        )
    }
}
