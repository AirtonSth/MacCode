import XCTest
@testable import DistillCore

/// Wave 5 — M6 latency percentiles, M8 seeded-corruption canaries, V5 embedding cache.
final class Wave5TelemetryTests: XCTestCase {

    // M6: nearest-rank p50/p95 + bounded ring.
    func test_latencyPercentiles() {
        var t = LatencyPercentileTracker(capacity: 1000)
        for ms in 1...100 { t.record(milliseconds: ms) }
        XCTAssertEqual(t.count, 100)
        XCTAssertTrue((50...51).contains(t.p50), "median of 1...100 (nearest-rank) is 50 or 51, got \(t.p50)")
        XCTAssertEqual(t.p95, 95)
        XCTAssertEqual(t.percentile(1.0), 100)
        XCTAssertEqual(t.percentile(0.0), 1)
    }

    func test_latencyRingIsBounded() {
        var t = LatencyPercentileTracker(capacity: 10)
        for ms in 1...1000 { t.record(milliseconds: ms) }
        XCTAssertEqual(t.count, 10, "ring must stay bounded")
        XCTAssertEqual(t.p95, 1000, "only the most recent samples remain")
    }

    func test_recorderExposesGateLatencyPercentiles() async {
        let recorder = DistillServiceMetricsRecorder()
        for ms in [5, 10, 15, 20, 25, 30, 200] { await recorder.recordLatency(milliseconds: ms) }
        let m = await recorder.snapshot(activeRequests: 0, maxConcurrentRequests: 4)
        XCTAssertGreaterThan(m.gateP95Millis, m.gateP50Millis)
        XCTAssertEqual(m.gateP95Millis, 200)
        let json = String(data: try! JSONEncoder().encode(m), encoding: .utf8)!
        XCTAssertTrue(json.contains("gate_p95_millis"))
    }

    /// The full deterministic faithfulness stack: omission (LiteralPreservation) AND
    /// hallucination + salient-word coverage (FaithfulnessGate). Both must accept.
    private func fullGate(_ original: String, _ compressed: String) -> Bool {
        LiteralPreservation.preservesLiterals(original: original, compressed: compressed)
            && FaithfulnessGate.validate(original: original, compressed: compressed).accepted
    }

    // M8: the full deterministic faithfulness stack catches every seeded corruption.
    func test_seededCorruptionCanaryOmissionRecall() {
        let original = """
        Build summary
        ERROR: linker failed for module Auth with code 1234
        the cache is not enabled in this run
        3 tests passed, 0 failed
        """
        let report = SeededCorruptionCanary.run(original: original, gate: fullGate)
        XCTAssertGreaterThanOrEqual(report.applicable, 3, "negation, removed-error, fake-path, dropped-number should apply")
        XCTAssertEqual(report.omissionRecall, 1.0, "every seeded corruption must be rejected by the stack (M8)")
    }

    func test_individualCorruptionsAreCaught() {
        // Negation is on a line whose ONLY salient word is "not" — the deterministic gate
        // catches it via salient-word coverage. (When a negation co-occurs with another
        // salient word on the same line, only the NLI gate I8.2 can catch it — a known,
        // documented limit of the deterministic stack.)
        let original = "ERROR: disk full at /var/log/app.log\nretries are not allowed beyond 5000"
        for corruption in SeededCorruption.allCases {
            guard let corrupted = corruption.apply(to: original), corrupted != original else { continue }
            XCTAssertFalse(fullGate(original, corrupted), "\(corruption.rawValue) must be rejected")
        }
    }

    // V5: keyed cache hits/misses + model-bump invalidation.
    func test_embeddingCacheKeyingAndLRU() async {
        let cache = EmbeddingCache(capacity: 2)
        let k1 = EmbeddingCache.key(text: "alpha", modelID: "bge", chunkerVersion: "v1")
        let k1Other = EmbeddingCache.key(text: "alpha", modelID: "bge", chunkerVersion: "v2")
        XCTAssertNotEqual(k1, k1Other, "chunker-version is part of the key")

        await cache.put(k1, [1, 0, 0])
        let hit = await cache.get(k1)
        XCTAssertEqual(hit, [1, 0, 0])
        let miss = await cache.get(k1Other)
        XCTAssertNil(miss, "a different model/chunker version is a cache miss (no stale vectors)")

        // LRU eviction at capacity 2.
        await cache.put(EmbeddingCache.key(text: "b", modelID: "m", chunkerVersion: "v"), [2])
        await cache.put(EmbeddingCache.key(text: "c", modelID: "m", chunkerVersion: "v"), [3])
        let evicted = await cache.count
        XCTAssertLessThanOrEqual(evicted, 2)
    }
}
