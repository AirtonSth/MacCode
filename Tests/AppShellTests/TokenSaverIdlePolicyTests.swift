import XCTest
@testable import AppShell

/// Pure unit tests for TokenSaverIdlePolicy.shouldUnload.
/// No @MainActor, no async, no process spawn, no timers.
final class TokenSaverIdlePolicyTests: XCTestCase {

    // MARK: - shouldUnload: true past idle window

    func test_shouldUnload_trueWhenElapsedExceedsTimeout() {
        // WHY: idleTimeoutMS=5000; last request 6 seconds ago => model must unload
        // to reclaim ~1.1 GB RAM between sessions.
        let last = Date(timeIntervalSinceReferenceDate: 0)
        let now  = Date(timeIntervalSinceReferenceDate: 6)
        XCTAssertTrue(
            TokenSaverIdlePolicy.shouldUnload(lastRequestAt: last, idleTimeoutMS: 5_000, now: now),
            "elapsed 6000 ms >= timeout 5000 ms => must signal unload"
        )
    }

    func test_shouldUnload_trueWhenElapsedExactlyEqualsTimeout() {
        // WHY: boundary — elapsed == timeout is past the window, must unload.
        let last = Date(timeIntervalSinceReferenceDate: 0)
        let now  = Date(timeIntervalSinceReferenceDate: 5)
        XCTAssertTrue(
            TokenSaverIdlePolicy.shouldUnload(lastRequestAt: last, idleTimeoutMS: 5_000, now: now),
            "elapsed 5000 ms == timeout 5000 ms => boundary must signal unload"
        )
    }

    // MARK: - shouldUnload: false within idle window

    func test_shouldUnload_falseWhenElapsedBelowTimeout() {
        // WHY: last request 3 seconds ago; 5-second window not yet expired => keep
        // model loaded so the next request returns without the startup latency.
        let last = Date(timeIntervalSinceReferenceDate: 0)
        let now  = Date(timeIntervalSinceReferenceDate: 3)
        XCTAssertFalse(
            TokenSaverIdlePolicy.shouldUnload(lastRequestAt: last, idleTimeoutMS: 5_000, now: now),
            "elapsed 3000 ms < timeout 5000 ms => must NOT unload"
        )
    }

    func test_shouldUnload_falseWhenNowEqualsLastRequestAt() {
        // WHY: just received a request; elapsed == 0 => never unload immediately.
        let instant = Date(timeIntervalSinceReferenceDate: 100)
        XCTAssertFalse(
            TokenSaverIdlePolicy.shouldUnload(lastRequestAt: instant, idleTimeoutMS: 1_000, now: instant),
            "elapsed 0 ms < timeout => must NOT unload"
        )
    }

    // MARK: - shouldUnload: disabled when idleTimeoutMS <= 0

    func test_shouldUnload_falseWhenTimeoutIsZero() {
        // WHY: idleTimeoutMS == 0 is the explicit opt-out signal; the feature must
        // be fully disabled regardless of how long ago the last request was.
        let last = Date(timeIntervalSinceReferenceDate: 0)
        let now  = Date(timeIntervalSinceReferenceDate: 9999)
        XCTAssertFalse(
            TokenSaverIdlePolicy.shouldUnload(lastRequestAt: last, idleTimeoutMS: 0, now: now),
            "idleTimeoutMS == 0 => feature disabled, must never unload"
        )
    }

    func test_shouldUnload_falseWhenTimeoutIsNegative() {
        // WHY: negative values are another disabled-feature sentinel; same contract
        // as zero.
        let last = Date(timeIntervalSinceReferenceDate: 0)
        let now  = Date(timeIntervalSinceReferenceDate: 9999)
        XCTAssertFalse(
            TokenSaverIdlePolicy.shouldUnload(lastRequestAt: last, idleTimeoutMS: -1, now: now),
            "idleTimeoutMS < 0 => feature disabled, must never unload"
        )
    }

    // MARK: - shouldUnload: no lastRequestAt

    func test_shouldUnload_falseWhenLastRequestAtIsNil() {
        // WHY: nil means no request has occurred yet; unloading a model that was
        // never used would be a no-op at best and confusing at worst. The sidecar
        // seeds lastRequestAt = Date() on first ready, so nil only occurs before
        // the first start — never unload in that state.
        let now = Date(timeIntervalSinceReferenceDate: 9999)
        XCTAssertFalse(
            TokenSaverIdlePolicy.shouldUnload(lastRequestAt: nil, idleTimeoutMS: 1_000, now: now),
            "nil lastRequestAt => no prior activity, must NOT unload"
        )
    }
}
