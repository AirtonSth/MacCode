import XCTest
@testable import SocketServer

/// Tests for the pure connection-metrics helper and WSConnectionTracker.
/// No @MainActor, no network I/O, no timing - all assertions are structural.
final class WSConnectionMetricsTests: XCTestCase {

    // MARK: - connectionMetricsJSON helper

    func test_connectionMetricsJSON_includesAllDocumentedFields() {
        // WHY: the health assembler must include every field the client
        // and support tooling depend on for "why is sync slow" / 3G limit analysis.
        let result = connectionMetricsJSON(
            activeClients: 3,
            totalQueuedBytes: 4096,
            slowClientDrops: 1,
            maxObservedOutboundQueuedBytes: 8192,
            maxObservedFrameBytes: 2048,
            framesRejectedOrEvicted: 7
        )
        XCTAssertEqual(result["active_clients"] as? Int, 3,
                       "active_clients must reflect the given counter")
        XCTAssertEqual(result["total_queued_bytes"] as? Int, 4096,
                       "total_queued_bytes must reflect the given counter")
        XCTAssertEqual(result["slow_client_drops"] as? Int, 1,
                       "slow_client_drops must reflect the given counter")
        XCTAssertEqual(result["max_observed_outbound_queued_bytes"] as? Int, 8192,
                       "max_observed_outbound_queued_bytes must reflect the high-water mark")
        XCTAssertEqual(result["max_observed_frame_bytes"] as? Int, 2048,
                       "max_observed_frame_bytes must reflect the high-water mark")
        XCTAssertEqual(result["frames_rejected_or_evicted"] as? Int, 7,
                       "frames_rejected_or_evicted must reflect the reject/evict counter")
    }

    func test_connectionMetricsJSON_zeroState_isValid() {
        // WHY: a freshly started server with no WS clients must return
        // zeros, not missing keys or nil - callers must not need nil-checks.
        let result = connectionMetricsJSON(
            activeClients: 0,
            totalQueuedBytes: 0,
            slowClientDrops: 0,
            maxObservedOutboundQueuedBytes: 0,
            maxObservedFrameBytes: 0,
            framesRejectedOrEvicted: 0
        )
        XCTAssertEqual(result["active_clients"] as? Int, 0)
        XCTAssertEqual(result["total_queued_bytes"] as? Int, 0)
        XCTAssertEqual(result["slow_client_drops"] as? Int, 0)
        XCTAssertEqual(result["max_observed_outbound_queued_bytes"] as? Int, 0)
        XCTAssertEqual(result["max_observed_frame_bytes"] as? Int, 0)
        XCTAssertEqual(result["frames_rejected_or_evicted"] as? Int, 0)
    }

    func test_connectionMetricsJSON_keysOnly_noExtraKeys() {
        // WHY: health response schema must be stable; unexpected keys
        // break iOS client decoding contracts.
        let result = connectionMetricsJSON(
            activeClients: 0,
            totalQueuedBytes: 0,
            slowClientDrops: 0
        )
        let expected: Set<String> = [
            "active_clients",
            "total_queued_bytes",
            "slow_client_drops",
            "max_observed_outbound_queued_bytes",
            "max_observed_frame_bytes",
            "frames_rejected_or_evicted"
        ]
        XCTAssertEqual(Set(result.keys), expected,
                       "connectionMetricsJSON must return exactly the documented keys")
    }

    func test_connectionMetricsJSON_clampsNegativeInputs() {
        // WHY: health must never emit negative gauges even if a caller
        // passes a bad sample under race or bug — support tooling treats
        // negatives as corruption.
        let result = connectionMetricsJSON(
            activeClients: -1,
            totalQueuedBytes: -100,
            slowClientDrops: -2,
            maxObservedOutboundQueuedBytes: -5,
            maxObservedFrameBytes: -9,
            framesRejectedOrEvicted: -3
        )
        for key in result.keys {
            XCTAssertGreaterThanOrEqual(result[key] as? Int ?? -1, 0,
                                        "\(key) must be nonnegative in health JSON")
        }
    }

    // MARK: - WSConnectionTracker

    func test_tracker_initialState_allZero() {
        // WHY: a new server must start with zero counters; non-zero
        // defaults would corrupt the /v1/health baseline reading.
        let tracker = WSConnectionTracker()
        XCTAssertEqual(tracker.activeClients, 0)
        XCTAssertEqual(tracker.totalQueuedBytes, 0)
        XCTAssertEqual(tracker.slowClientDrops, 0)
        XCTAssertEqual(tracker.maxObservedOutboundQueuedBytes, 0)
        XCTAssertEqual(tracker.maxObservedFrameBytes, 0)
        XCTAssertEqual(tracker.framesRejectedOrEvicted, 0)
    }

    func test_tracker_clientConnected_incrementsActiveClients() {
        // WHY: /v1/health "active_clients" must rise when a WS client connects.
        let tracker = WSConnectionTracker()
        tracker.clientConnected()
        XCTAssertEqual(tracker.activeClients, 1)
        tracker.clientConnected()
        XCTAssertEqual(tracker.activeClients, 2)
    }

    func test_tracker_clientDisconnected_decrementsActiveClients() {
        // WHY: active count must drop when the WS loop exits so the counter
        // stays accurate across connect/disconnect cycles.
        let tracker = WSConnectionTracker()
        tracker.clientConnected()
        tracker.clientConnected()
        tracker.clientDisconnected(queuedBytes: 0)
        XCTAssertEqual(tracker.activeClients, 1)
        tracker.clientDisconnected(queuedBytes: 0)
        XCTAssertEqual(tracker.activeClients, 0)
    }

    func test_tracker_clientDisconnected_doesNotGoNegative() {
        // WHY: if disconnect races with a missed connect (e.g. during
        // stop()), the counter must clamp to 0 not underflow to -1,
        // which would make health look stale/broken.
        let tracker = WSConnectionTracker()
        tracker.clientDisconnected(queuedBytes: 0)
        XCTAssertEqual(tracker.activeClients, 0)
    }

    func test_tracker_recordSlowClientDrop_incrementsDrops() {
        // WHY: slow-client drops are the primary signal for "sync is slow
        // because the server is shedding backpressure" - each queue_full
        // eviction must increment the counter exactly once.
        let tracker = WSConnectionTracker()
        tracker.recordSlowClientDrop()
        XCTAssertEqual(tracker.slowClientDrops, 1)
        tracker.recordSlowClientDrop()
        XCTAssertEqual(tracker.slowClientDrops, 2)
    }

    func test_tracker_clientDisconnected_substractsQueuedBytesFromTotal() {
        // WHY: totalQueuedBytes is an aggregate across all live connections;
        // when a connection exits it must remove its byte contribution so
        // the aggregate stays accurate.
        let tracker = WSConnectionTracker()
        tracker.updateQueuedBytes(previous: 0, current: 1024)
        tracker.clientDisconnected(queuedBytes: 1024)
        // after disconnect the contribution is removed
        XCTAssertEqual(tracker.totalQueuedBytes, 0)
        // high-water mark is process-scoped and must survive disconnect
        XCTAssertEqual(tracker.maxObservedOutboundQueuedBytes, 1024,
                       "max queue depth must not reset on connection lifecycle")
    }

    func test_tracker_updateQueuedBytes_reflectsLatestSample() {
        // WHY: total_queued_bytes must track backpressure accurately;
        // stale high values hide the fact that the queue drained.
        let tracker = WSConnectionTracker()
        tracker.updateQueuedBytes(previous: 0, current: 512)
        XCTAssertEqual(tracker.totalQueuedBytes, 512)
        tracker.updateQueuedBytes(previous: 512, current: 256)
        XCTAssertEqual(tracker.totalQueuedBytes, 256)
    }

    func test_tracker_queuedBytesDoNotGoNegative() {
        // WHY: floating-point-style underflow on integer counters would
        // make health report garbage; must clamp to 0.
        let tracker = WSConnectionTracker()
        tracker.updateQueuedBytes(previous: 1000, current: 0)
        // previous > current: net delta is -1000 from 0 base
        XCTAssertEqual(tracker.totalQueuedBytes, 0)
        XCTAssertGreaterThanOrEqual(tracker.maxObservedOutboundQueuedBytes, 0)
    }

    func test_tracker_maxObservedOutboundQueuedBytes_isMonotonic() {
        // WHY: 3G diagnosis needs a true high-water mark; draining the queue
        // must not erase the worst observed backlog.
        let tracker = WSConnectionTracker()
        tracker.updateQueuedBytes(previous: 0, current: 100)
        XCTAssertEqual(tracker.maxObservedOutboundQueuedBytes, 100)
        tracker.updateQueuedBytes(previous: 100, current: 400)
        XCTAssertEqual(tracker.maxObservedOutboundQueuedBytes, 400)
        tracker.updateQueuedBytes(previous: 400, current: 50)
        XCTAssertEqual(tracker.totalQueuedBytes, 50)
        XCTAssertEqual(tracker.maxObservedOutboundQueuedBytes, 400,
                       "max must stay at peak after drain")
        tracker.updateQueuedBytes(previous: 50, current: 200)
        XCTAssertEqual(tracker.maxObservedOutboundQueuedBytes, 400,
                       "max must not decrease when a lower peak is observed")
    }

    func test_tracker_maxObservedFrameBytes_isMonotonic() {
        // WHY: oversized frames on cellular are a root-cause signal; max
        // must only rise and never track the latest smaller frame.
        let tracker = WSConnectionTracker()
        tracker.recordFrameBytes(128)
        XCTAssertEqual(tracker.maxObservedFrameBytes, 128)
        tracker.recordFrameBytes(1024)
        XCTAssertEqual(tracker.maxObservedFrameBytes, 1024)
        tracker.recordFrameBytes(64)
        XCTAssertEqual(tracker.maxObservedFrameBytes, 1024)
        tracker.recordFrameBytes(-10)
        XCTAssertEqual(tracker.maxObservedFrameBytes, 1024,
                       "negative samples must not corrupt the high-water mark")
    }

    func test_tracker_framesRejectedOrEvicted_countsAndIgnoresNonPositive() {
        // WHY: each backpressure refuse / degrade eviction is one unit of
        // transport-limit pain; zeros/negatives must not move the counter.
        let tracker = WSConnectionTracker()
        tracker.recordFramesRejectedOrEvicted(3)
        XCTAssertEqual(tracker.framesRejectedOrEvicted, 3)
        tracker.recordFramesRejectedOrEvicted(1)
        XCTAssertEqual(tracker.framesRejectedOrEvicted, 4)
        tracker.recordFramesRejectedOrEvicted(0)
        tracker.recordFramesRejectedOrEvicted(-5)
        XCTAssertEqual(tracker.framesRejectedOrEvicted, 4)
    }

    func test_tracker_connectionLifecycle_doesNotResetTransportLimits() {
        // WHY: process-scoped limit counters diagnose multi-session 3G pain;
        // only live gauges (active clients, current queue) follow lifecycle.
        let tracker = WSConnectionTracker()
        tracker.clientConnected()
        tracker.updateQueuedBytes(previous: 0, current: 2048)
        tracker.recordFrameBytes(512)
        tracker.recordFramesRejectedOrEvicted(2)
        tracker.recordSlowClientDrop()
        tracker.clientDisconnected(queuedBytes: 2048)

        XCTAssertEqual(tracker.activeClients, 0)
        XCTAssertEqual(tracker.totalQueuedBytes, 0)
        XCTAssertEqual(tracker.maxObservedOutboundQueuedBytes, 2048)
        XCTAssertEqual(tracker.maxObservedFrameBytes, 512)
        XCTAssertEqual(tracker.framesRejectedOrEvicted, 2)
        XCTAssertEqual(tracker.slowClientDrops, 1)
    }

    func test_tracker_allGaugesRemainNonnegative() {
        // WHY: health JSON consumers assume nonnegative integers; any
        // lifecycle race that underflows would poison dashboards.
        let tracker = WSConnectionTracker()
        tracker.clientDisconnected(queuedBytes: 999)
        tracker.updateQueuedBytes(previous: 500, current: 0)
        tracker.recordFrameBytes(-1)
        tracker.recordFramesRejectedOrEvicted(-1)
        XCTAssertGreaterThanOrEqual(tracker.activeClients, 0)
        XCTAssertGreaterThanOrEqual(tracker.totalQueuedBytes, 0)
        XCTAssertGreaterThanOrEqual(tracker.slowClientDrops, 0)
        XCTAssertGreaterThanOrEqual(tracker.maxObservedOutboundQueuedBytes, 0)
        XCTAssertGreaterThanOrEqual(tracker.maxObservedFrameBytes, 0)
        XCTAssertGreaterThanOrEqual(tracker.framesRejectedOrEvicted, 0)
    }
}
