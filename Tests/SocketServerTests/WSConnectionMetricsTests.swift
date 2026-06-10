import XCTest
@testable import SocketServer

/// Tests for the pure connection-metrics helper and WSConnectionTracker.
/// No @MainActor, no network I/O, no timing - all assertions are structural.
final class WSConnectionMetricsTests: XCTestCase {

    // MARK: - connectionMetricsJSON helper

    func test_connectionMetricsJSON_includesAllThreeFields() {
        // WHY: the health assembler must include every field the client
        // and support tooling depend on for "why is sync slow" analysis.
        let result = connectionMetricsJSON(
            activeClients: 3,
            totalQueuedBytes: 4096,
            slowClientDrops: 1
        )
        XCTAssertEqual(result["active_clients"] as? Int, 3,
                       "active_clients must reflect the given counter")
        XCTAssertEqual(result["total_queued_bytes"] as? Int, 4096,
                       "total_queued_bytes must reflect the given counter")
        XCTAssertEqual(result["slow_client_drops"] as? Int, 1,
                       "slow_client_drops must reflect the given counter")
    }

    func test_connectionMetricsJSON_zeroState_isValid() {
        // WHY: a freshly started server with no WS clients must return
        // zeros, not missing keys or nil - callers must not need nil-checks.
        let result = connectionMetricsJSON(
            activeClients: 0,
            totalQueuedBytes: 0,
            slowClientDrops: 0
        )
        XCTAssertEqual(result["active_clients"] as? Int, 0)
        XCTAssertEqual(result["total_queued_bytes"] as? Int, 0)
        XCTAssertEqual(result["slow_client_drops"] as? Int, 0)
    }

    func test_connectionMetricsJSON_keysOnly_noExtraKeys() {
        // WHY: health response schema must be stable; unexpected keys
        // break iOS client decoding contracts.
        let result = connectionMetricsJSON(
            activeClients: 0,
            totalQueuedBytes: 0,
            slowClientDrops: 0
        )
        let expected: Set<String> = ["active_clients", "total_queued_bytes", "slow_client_drops"]
        XCTAssertEqual(Set(result.keys), expected,
                       "connectionMetricsJSON must return exactly the three documented keys")
    }

    // MARK: - WSConnectionTracker

    func test_tracker_initialState_allZero() {
        // WHY: a new server must start with zero counters; non-zero
        // defaults would corrupt the /v1/health baseline reading.
        let tracker = WSConnectionTracker()
        XCTAssertEqual(tracker.activeClients, 0)
        XCTAssertEqual(tracker.totalQueuedBytes, 0)
        XCTAssertEqual(tracker.slowClientDrops, 0)
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
    }
}
