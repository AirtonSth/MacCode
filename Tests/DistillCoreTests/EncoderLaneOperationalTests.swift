import XCTest
@testable import DistillCore

/// I3.3 / I3.10 / K3 / M5 / M11: the encoder lane's operational safety layer —
/// per-call deadline, deadline-timeout accounting, anti-thrash latch, and
/// warmup/reclaim fail-open. Uses a stub scorer so no model is downloaded.
final class EncoderLaneOperationalTests: XCTestCase {
    private func chunks() -> [QueryAwareChunk] {
        [QueryAwareChunk(id: "a", text: "auth token refresh failed", position: 0)]
    }

    func test_deadlineTimeoutIsCountedAndFailsOpen() async {
        let lane = EncoderLane(
            manifest: TokenSaverApprovedEncoderManifests.bgeSmallEN,
            scorer: { _, _ in
                try await Task.sleep(nanoseconds: 300 * 1_000_000)
                return 1.0
            },
            deadlineMillis: 20
        )
        let ranked = await lane.rank(chunks: chunks(), query: "auth")
        let m = await lane.metricsSnapshot()
        XCTAssertNil(ranked, "deadline must fail open to deterministic/verbatim")
        XCTAssertEqual(m.deadlineTimeouts, 1)
        XCTAssertEqual(m.fallbacks, 1)
        XCTAssertEqual(m.failures, 0, "a deadline is not a failure")
        XCTAssertFalse(m.disabled)
    }

    func test_latchesDisabledAfterConsecutiveDeadlineTimeouts() async {
        let lane = EncoderLane(
            manifest: TokenSaverApprovedEncoderManifests.bgeSmallEN,
            scorer: { _, _ in
                try await Task.sleep(nanoseconds: 300 * 1_000_000)
                return 1.0
            },
            deadlineMillis: 20,
            maxConsecutiveDeadlineTimeouts: 3
        )
        for _ in 0..<3 { _ = await lane.rank(chunks: chunks(), query: "auth") }
        let mid = await lane.metricsSnapshot()
        XCTAssertTrue(mid.disabled, "lane must latch off after N consecutive deadline-outs (K3)")
        XCTAssertEqual(mid.deadlineTimeouts, 3)

        // A latched lane short-circuits: no further model path, counted as fallback.
        let after = await lane.rank(chunks: chunks(), query: "auth")
        let end = await lane.metricsSnapshot()
        XCTAssertNil(after)
        XCTAssertEqual(end.deadlineTimeouts, 3, "latched lane must not run the scorer again (anti-thrash)")
        XCTAssertEqual(end.fallbacks, 4)
        let disabled = await lane.isDisabled
        XCTAssertTrue(disabled)
    }

    func test_oneFastCallResetsConsecutiveCounter() async {
        actor Toggle { var slow = true; func flip() { slow.toggle() }; func isSlow() -> Bool { slow } }
        let toggle = Toggle()
        let lane = EncoderLane(
            manifest: TokenSaverApprovedEncoderManifests.bgeSmallEN,
            scorer: { _, text in
                if await toggle.isSlow() { try await Task.sleep(nanoseconds: 300 * 1_000_000) }
                return text.contains("auth") ? 1.0 : 0.0
            },
            deadlineMillis: 30,
            maxConsecutiveDeadlineTimeouts: 3
        )
        _ = await lane.rank(chunks: chunks(), query: "auth")   // timeout #1
        _ = await lane.rank(chunks: chunks(), query: "auth")   // timeout #2
        await toggle.flip()                                     // now fast
        _ = await lane.rank(chunks: chunks(), query: "auth")   // success → resets streak
        await toggle.flip()                                     // slow again
        _ = await lane.rank(chunks: chunks(), query: "auth")   // timeout #1 again
        let m = await lane.metricsSnapshot()
        XCTAssertFalse(m.disabled, "a successful call between timeouts must reset the streak")
        XCTAssertEqual(m.deadlineTimeouts, 3)
        XCTAssertEqual(m.accepts, 1)
    }

    func test_warmupAndReclaimAreFailOpenWithoutBackend() async {
        let lane = EncoderLane(
            manifest: TokenSaverApprovedEncoderManifests.bgeSmallEN,
            scorer: { _, _ in 1.0 }
        )
        await lane.warmup()          // no warmup closure → no-op, must not throw/hang
        await lane.reclaimIdleMemory()
        let ranked = await lane.rank(chunks: chunks(), query: "auth")
        XCTAssertNotNil(ranked, "lane stays usable after a no-op warmup/reclaim")
    }

    func test_warmupClosureErrorDoesNotDisableLane() async {
        struct Boom: Error {}
        let lane = EncoderLane(
            manifest: TokenSaverApprovedEncoderManifests.bgeSmallEN,
            scorer: { _, _ in 1.0 },
            warmup: { throw Boom() }
        )
        await lane.warmup()   // must swallow the error (fail-open)
        let ranked = await lane.rank(chunks: chunks(), query: "auth")
        XCTAssertNotNil(ranked)
    }
}
