import XCTest
@testable import AppShell

/// Freeze regression: orphan provider/sidecar reaping used to run on MainActor
/// (diagnostics heartbeat every 60s) and block on Thread.sleep grace windows.
/// The latch must skip stacked sweeps so a slow reaper cannot pile onto the UI.
final class OrphanSweepOffMainTests: XCTestCase {

    @MainActor
    func test_orphanSweepLatch_skipsOverlapAndClearsForNextTick() {
        var inFlight = false

        XCTAssertEqual(
            AppDelegate.beginOrphanSweepForTests(&inFlight),
            .start,
            "first periodic/launch sweep must start when no sweep is in flight"
        )
        XCTAssertTrue(inFlight, "begin must set the in-flight latch")

        XCTAssertEqual(
            AppDelegate.beginOrphanSweepForTests(&inFlight),
            .skipInFlight,
            "overlapping heartbeat must skip a second blocking process reaper"
        )
        XCTAssertTrue(inFlight, "skip must leave the latch set until the first sweep finishes")

        inFlight = false

        XCTAssertEqual(
            AppDelegate.beginOrphanSweepForTests(&inFlight),
            .start,
            "after the detached sweep clears the latch, the next tick must be allowed to re-run"
        )
    }
}
