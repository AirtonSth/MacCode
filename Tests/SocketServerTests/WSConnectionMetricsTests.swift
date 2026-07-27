import XCTest
@testable import SocketServer

/// Tests for the pure connection-metrics helper and WSConnectionTracker.
/// No @MainActor, no network I/O, no timing - all assertions are structural.
final class WSConnectionMetricsTests: XCTestCase {

    /// JSONSerialization boxes integers/floats loosely; normalize for asserts.
    private func jsonUInt64(_ value: Any?) -> UInt64? {
        if let v = value as? UInt64 { return v }
        if let v = value as? Int { return UInt64(v) }
        if let v = value as? NSNumber { return v.uint64Value }
        return nil
    }

    private func jsonDouble(_ value: Any?) -> Double? {
        if let v = value as? Double { return v }
        if let v = value as? Int { return Double(v) }
        if let v = value as? NSNumber { return v.doubleValue }
        return nil
    }

    // MARK: - connectionMetricsJSON helper

    func test_connectionMetricsJSON_includesAllDocumentedFields() {
        // WHY: the health assembler must include every field the client
        // and support tooling depend on for "why is sync slow" / 3G limit analysis.
        var wait = OutboundQueueWaitMetricsSnapshot.zero
        wait.priority.record(waitMilliseconds: 12)
        wait.normal.record(waitMilliseconds: 40)
        wait.bulk.record(waitMilliseconds: 90)
        let result = connectionMetricsJSON(
            activeClients: 3,
            totalQueuedBytes: 4096,
            slowClientDrops: 1,
            maxObservedOutboundQueuedBytes: 8192,
            maxObservedFrameBytes: 2048,
            framesRejectedOrEvicted: 7,
            outboundQueueWait: wait
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
        let waitJSON = result["outbound_queue_wait_ms"] as? [String: Any]
        XCTAssertNotNil(waitJSON, "queue wait aggregates must appear under connections")
        let priority = waitJSON?["priority"] as? [String: Any]
        XCTAssertEqual(jsonUInt64(priority?["count"]), 1)
        XCTAssertEqual(jsonDouble(priority?["total"]), 12)
        XCTAssertEqual(jsonDouble(priority?["max"]), 12)
        let normal = waitJSON?["normal"] as? [String: Any]
        XCTAssertEqual(jsonUInt64(normal?["count"]), 1)
        XCTAssertEqual(jsonDouble(normal?["max"]), 40)
        let bulk = waitJSON?["bulk"] as? [String: Any]
        XCTAssertEqual(jsonUInt64(bulk?["count"]), 1)
        XCTAssertEqual(jsonDouble(bulk?["max"]), 90)
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
        let waitJSON = result["outbound_queue_wait_ms"] as? [String: Any]
        for lane in ["priority", "normal", "bulk"] {
            let laneJSON = waitJSON?[lane] as? [String: Any]
            XCTAssertEqual(jsonUInt64(laneJSON?["count"]), 0, "\(lane) count zero at cold start")
            XCTAssertEqual(jsonDouble(laneJSON?["total"]), 0, "\(lane) total zero at cold start")
            XCTAssertEqual(jsonDouble(laneJSON?["max"]), 0, "\(lane) max zero at cold start")
        }
    }

    func test_connectionMetricsJSON_keysOnly_noExtraKeys() {
        // WHY: health response schema must be stable; unexpected keys
        // break iOS client decoding contracts. Additive wait aggregates are
        // the only intentional extension for queue-time diagnostics.
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
            "frames_rejected_or_evicted",
            "outbound_queue_wait_ms"
        ]
        XCTAssertEqual(Set(result.keys), expected,
                       "connectionMetricsJSON must return exactly the documented keys")
        let waitJSON = result["outbound_queue_wait_ms"] as? [String: Any]
        XCTAssertEqual(Set((waitJSON ?? [:]).keys), Set(["priority", "normal", "bulk"]),
                       "wait aggregates must use only existing application lane labels")
        for lane in ["priority", "normal", "bulk"] {
            let laneJSON = waitJSON?[lane] as? [String: Any]
            XCTAssertEqual(Set((laneJSON ?? [:]).keys), Set(["count", "total", "max"]),
                           "\(lane) wait object must stay count/total/max only")
        }
    }

    func test_connectionMetricsJSON_clampsNegativeInputs() {
        // WHY: health must never emit negative gauges even if a caller
        // passes a bad sample under race or bug — support tooling treats
        // negatives as corruption.
        var wait = OutboundQueueWaitMetricsSnapshot.zero
        wait.priority.record(waitMilliseconds: -5)
        wait.normal.record(waitMilliseconds: .nan)
        wait.bulk.record(waitMilliseconds: -1)
        // Force a negative total via direct construction for clamp coverage.
        wait.priority = OutboundQueueWaitLaneMetrics(count: 1, totalMilliseconds: -9, maxMilliseconds: -3)
        let result = connectionMetricsJSON(
            activeClients: -1,
            totalQueuedBytes: -100,
            slowClientDrops: -2,
            maxObservedOutboundQueuedBytes: -5,
            maxObservedFrameBytes: -9,
            framesRejectedOrEvicted: -3,
            outboundQueueWait: wait
        )
        for key in result.keys where key != "outbound_queue_wait_ms" {
            XCTAssertGreaterThanOrEqual(result[key] as? Int ?? -1, 0,
                                        "\(key) must be nonnegative in health JSON")
        }
        let waitJSON = result["outbound_queue_wait_ms"] as? [String: Any]
        for lane in ["priority", "normal", "bulk"] {
            let laneJSON = waitJSON?[lane] as? [String: Any]
            XCTAssertGreaterThanOrEqual(jsonDouble(laneJSON?["total"]) ?? -1, 0,
                                        "\(lane) total must clamp nonnegative")
            XCTAssertGreaterThanOrEqual(jsonDouble(laneJSON?["max"]) ?? -1, 0,
                                        "\(lane) max must clamp nonnegative")
        }
    }

    func test_connectionMetricsJSON_queueWait_isSecretFreeBoundedShape() {
        // WHY: diagnostics must never leak payloads/tokens/host identity into
        // /v1/health.connections — only fixed lane labels and numeric aggregates.
        var wait = OutboundQueueWaitMetricsSnapshot.zero
        wait.priority.record(waitMilliseconds: 5)
        wait.normal.record(waitMilliseconds: 15)
        wait.bulk.record(waitMilliseconds: 25)
        wait.bulk.record(waitMilliseconds: 50)
        let result = connectionMetricsJSON(
            activeClients: 1,
            totalQueuedBytes: 100,
            slowClientDrops: 0,
            outboundQueueWait: wait
        )
        guard let encoded = try? JSONSerialization.data(
            withJSONObject: result,
            options: [.sortedKeys]
        ),
              let text = String(data: encoded, encoding: .utf8) else {
            return XCTFail("connections JSON must be serializable")
        }
        for secretish in [
            "token", "Bearer", "password", "payload", "host",
            "127.0.0.1", "authorization", "secret", "device"
        ] {
            XCTAssertFalse(
                text.localizedCaseInsensitiveContains(secretish),
                "health connections JSON must not contain secret-like key/value \(secretish)"
            )
        }
        let waitJSON = result["outbound_queue_wait_ms"] as? [String: Any]
        let bulk = waitJSON?["bulk"] as? [String: Any]
        XCTAssertEqual(jsonUInt64(bulk?["count"]), 2)
        XCTAssertEqual(jsonDouble(bulk?["total"]), 75)
        XCTAssertEqual(jsonDouble(bulk?["max"]), 50)
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
        let wait = tracker.outboundQueueWaitMetrics
        XCTAssertEqual(wait.priority, .zero)
        XCTAssertEqual(wait.normal, .zero)
        XCTAssertEqual(wait.bulk, .zero)
    }

    func test_tracker_recordOutboundQueueWait_attributesLanesAndClamps() {
        // WHY: process-scoped wait aggregates must attribute the existing
        // application lanes only and stay nonnegative for health consumers.
        let tracker = WSConnectionTracker()
        tracker.recordOutboundQueueWait(priority: .priority, waitMilliseconds: 10)
        tracker.recordOutboundQueueWait(priority: .normal, waitMilliseconds: 20)
        tracker.recordOutboundQueueWait(priority: .bulk, waitMilliseconds: 30)
        tracker.recordOutboundQueueWait(priority: .bulk, waitMilliseconds: 50)
        tracker.recordOutboundQueueWait(priority: .normal, waitMilliseconds: -4)
        tracker.recordOutboundQueueWait(priority: .priority, waitMilliseconds: .infinity)

        let wait = tracker.outboundQueueWaitMetrics
        XCTAssertEqual(wait.priority.count, 2)
        XCTAssertEqual(wait.priority.totalMilliseconds, 10,
                       "non-finite wait must record as 0 and not poison totals")
        XCTAssertEqual(wait.priority.maxMilliseconds, 10)
        XCTAssertEqual(wait.normal.count, 2)
        XCTAssertEqual(wait.normal.totalMilliseconds, 20)
        XCTAssertEqual(wait.normal.maxMilliseconds, 20)
        XCTAssertEqual(wait.bulk.count, 2)
        XCTAssertEqual(wait.bulk.totalMilliseconds, 80)
        XCTAssertEqual(wait.bulk.maxMilliseconds, 50)
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
        tracker.recordOutboundQueueWait(priority: .bulk, waitMilliseconds: -100)
        XCTAssertGreaterThanOrEqual(tracker.activeClients, 0)
        XCTAssertGreaterThanOrEqual(tracker.totalQueuedBytes, 0)
        XCTAssertGreaterThanOrEqual(tracker.slowClientDrops, 0)
        XCTAssertGreaterThanOrEqual(tracker.maxObservedOutboundQueuedBytes, 0)
        XCTAssertGreaterThanOrEqual(tracker.maxObservedFrameBytes, 0)
        XCTAssertGreaterThanOrEqual(tracker.framesRejectedOrEvicted, 0)
        let wait = tracker.outboundQueueWaitMetrics
        XCTAssertGreaterThanOrEqual(wait.priority.totalMilliseconds, 0)
        XCTAssertGreaterThanOrEqual(wait.normal.totalMilliseconds, 0)
        XCTAssertGreaterThanOrEqual(wait.bulk.totalMilliseconds, 0)
    }
}
