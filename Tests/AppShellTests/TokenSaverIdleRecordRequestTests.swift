// TokenSaverIdleRecordRequestTests.swift
//
// WHY these tests exist (Rule 8):
// idleTimeoutMS was parsed, stored, and passed to the sidecar but
// recordRequest() was NEVER called on the routing path, so lastRequestAt
// was permanently set to the startup time and never updated. The model
// would therefore never be evicted (elapsed = small, timeout = 300s). These
// tests verify that:
//   (a) recordRequest() updates lastRequestAt
//   (b) shouldUnload is false immediately after recordRequest()
//   (c) shouldUnload becomes true once idleTimeoutMS has elapsed with no
//       further calls to recordRequest()

import Foundation
import XCTest
@testable import AppShell
import DistillCore

// MARK: - Tests

/// All tests on @MainActor to match TokenSaverDistillServiceController isolation.
@MainActor
final class TokenSaverIdleRecordRequestTests: XCTestCase {

    // MARK: - recordRequest: updates lastRequestAt

    func test_recordRequest_updatesLastRequestAt() {
        // WHY: lastRequestAt must advance on every routed request so that the
        // idle-eviction timer resets. If lastRequestAt stays at startup time
        // (the previous bug), the model evicts correctly by clock but for the
        // wrong reason (idleness from startup, not from the last real use).
        let controller = TokenSaverDistillServiceController(
            appSupportDirectory: tempDir(),
            executableURLResolver: { nil },
            idleTimeoutMS: 300_000
        )
        XCTAssertNil(controller.lastRequestAt, "before any activity lastRequestAt must be nil")

        let before = Date()
        controller.recordRequest()
        let after = Date()

        let last = try! XCTUnwrap(controller.lastRequestAt)
        XCTAssertGreaterThanOrEqual(last, before, "lastRequestAt must be >= the time before recordRequest()")
        XCTAssertLessThanOrEqual(last, after, "lastRequestAt must be <= the time after recordRequest()")
    }

    // MARK: - shouldUnload: false immediately after recordRequest

    func test_shouldUnload_falseImmediatelyAfterRecordRequest() {
        // WHY: a request was just dispatched; unloading mid-in-flight would kill
        // the in-progress MLX generation. The guard is that elapsed < timeout
        // right after a recordRequest() call.
        let controller = TokenSaverDistillServiceController(
            appSupportDirectory: tempDir(),
            executableURLResolver: { nil },
            idleTimeoutMS: 5_000
        )
        controller.recordRequest()
        let last = controller.lastRequestAt!
        // Check immediately (elapsed ~ 0 ms).
        XCTAssertFalse(
            TokenSaverIdlePolicy.shouldUnload(
                lastRequestAt: last,
                idleTimeoutMS: 5_000,
                now: last.addingTimeInterval(0.001)
            ),
            "model must NOT unload 1 ms after recordRequest(); in-flight requests must complete"
        )
    }

    // MARK: - shouldUnload: true once timeout elapses with no new requests

    func test_shouldUnload_trueAfterTimeoutWithNoSubsequentRequest() {
        // WHY: if no request arrives for idleTimeoutMS the model is holding ~1.1 GB
        // of RAM for zero benefit. The idle timer must fire and stop() the controller.
        // This test proves the policy returns true when recordRequest() was last called
        // idleTimeoutMS ms ago, so the timer's stop() call is correctly gated.
        let controller = TokenSaverDistillServiceController(
            appSupportDirectory: tempDir(),
            executableURLResolver: { nil },
            idleTimeoutMS: 300_000
        )
        controller.recordRequest()
        let last = controller.lastRequestAt!
        // Simulate 5 minutes + 1 ms of silence.
        let afterIdle = last.addingTimeInterval(300.001)
        XCTAssertTrue(
            TokenSaverIdlePolicy.shouldUnload(
                lastRequestAt: last,
                idleTimeoutMS: 300_000,
                now: afterIdle
            ),
            "model must evict after idleTimeoutMS of silence to reclaim ~1.1 GB RAM"
        )
    }

    // MARK: - recordRequest: resets the idle window (no double-eviction)

    func test_recordRequest_resetsIdleWindowSoEvictionDoesNotTriggerMidUse() {
        // WHY: the idle timer ticks on a fixed interval. Without resetting
        // lastRequestAt, a flurry of requests could still hit the eviction
        // predicate if the interval started before the last request. Each
        // recordRequest() call must push the window forward so the check
        // uses the most-recent activity timestamp.
        let controller = TokenSaverDistillServiceController(
            appSupportDirectory: tempDir(),
            executableURLResolver: { nil },
            idleTimeoutMS: 5_000
        )
        // First request at t=0.
        controller.recordRequest()
        let first = controller.lastRequestAt!

        // Second request 4 seconds later (still within idle window).
        let t4 = first.addingTimeInterval(4)
        // Simulate clock advance via policy check (not real sleep).
        // Before the second recordRequest(), 4 s have elapsed but < 5 s => no evict.
        XCTAssertFalse(
            TokenSaverIdlePolicy.shouldUnload(lastRequestAt: first, idleTimeoutMS: 5_000, now: t4),
            "4 s < 5 s timeout => must NOT evict"
        )

        // Second request resets lastRequestAt.
        controller.recordRequest()
        let second = controller.lastRequestAt!
        XCTAssertGreaterThanOrEqual(second, first, "second recordRequest() must advance lastRequestAt")

        // Now check 4 s after the SECOND request: must still not evict.
        XCTAssertFalse(
            TokenSaverIdlePolicy.shouldUnload(
                lastRequestAt: second,
                idleTimeoutMS: 5_000,
                now: second.addingTimeInterval(4)
            ),
            "4 s after the second request => window reset, must NOT evict"
        )
    }

    // MARK: - Helpers

    private func tempDir() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("IdleRecordTest-\(UUID().uuidString)", isDirectory: true)
    }
}
