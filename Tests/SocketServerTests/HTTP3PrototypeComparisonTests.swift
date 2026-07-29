import XCTest
@testable import SocketServer

/// Unit tests for the Phase 5 pure comparison report seam.
///
/// WHY: operators need a way to place externally collected HTTP/WebSocket
/// samples next to QUIC-prototype samples without the seam inventing live
/// I/O, interoperability, performance wins, TLS bypass, or health-schema
/// changes. These tests pin that contract, including tail-latency percentiles
/// when raw samples are supplied.
final class HTTP3PrototypeComparisonTests: XCTestCase {

    // MARK: - Defaults and non-claims

    func test_report_emptyAggregates_incompleteAndCarriesNonClaims() throws {
        // WHY: a cold report must not look like a completed comparison or a
        // performance verdict when neither side has evidence.
        let report = HTTP3PrototypeComparison.report(
            currentHTTPWebSocket: .zero,
            quicPrototype: .zero
        )
        XCTAssertEqual(report.evidenceStatus, .incompleteMissingBoth)
        XCTAssertEqual(report.nonClaims, HTTP3PrototypeComparisonReport.fixedNonClaims)
        XCTAssertEqual(
            Set(report.nonClaims),
            [
                "no_interoperability_claim",
                "no_performance_gain_claim",
                "no_tls_bypass_claim",
                "no_live_support_claim",
            ]
        )
        XCTAssertNil(report.currentHTTPWebSocket.meanMilliseconds)
        XCTAssertNil(report.quicPrototype.meanMilliseconds)
        XCTAssertEqual(report.currentHTTPWebSocket.p50Milliseconds, 0)
        XCTAssertEqual(report.currentHTTPWebSocket.p95Milliseconds, 0)
        XCTAssertEqual(report.currentHTTPWebSocket.p99Milliseconds, 0)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: report.exportJSON()) as? [String: Any]
        )
        XCTAssertNil(
            object["performance_gain"],
            "export must not invent a performance-gain claim field"
        )
    }

    func test_report_missingOneSide_isIncompleteNotWinner() {
        // WHY: one-sided evidence must stay incomplete; the seam must never
        // promote a single path into a winner or readiness claim.
        let currentOnly = HTTP3PrototypeComparison.report(
            currentHTTPWebSocket: ProtocolPathDurationAggregate(
                count: 2,
                totalMilliseconds: 40,
                maxMilliseconds: 30
            ),
            quicPrototype: .zero
        )
        XCTAssertEqual(currentOnly.evidenceStatus, .incompleteMissingPrototype)
        XCTAssertEqual(currentOnly.currentHTTPWebSocket.meanMilliseconds, 20)
        XCTAssertNil(currentOnly.quicPrototype.meanMilliseconds)

        let prototypeOnly = HTTP3PrototypeComparison.report(
            currentHTTPWebSocket: .zero,
            quicPrototype: ProtocolPathDurationAggregate(
                count: 1,
                totalMilliseconds: 5,
                maxMilliseconds: 5
            )
        )
        XCTAssertEqual(prototypeOnly.evidenceStatus, .incompleteMissingCurrent)
        XCTAssertEqual(
            prototypeOnly.nonClaims,
            HTTP3PrototypeComparisonReport.fixedNonClaims,
            "non-claims must remain even when one side has data"
        )
    }

    // MARK: - External samples fold into count/total/max + percentiles

    func test_report_fromExternalSamples_sideBySideAggregatesOnly() throws {
        // WHY: the comparison must restate externally collected numbers as
        // bounded aggregates — not invent thresholds or declare gain.
        // Nearest-rank on [10, 30]: n=2 → p50 rank 1 → 10; p95/p99 rank 2 → 30.
        let samples: [ProtocolPathDurationSample] = [
            ProtocolPathDurationSample(path: .currentHTTPWebSocket, durationMilliseconds: 10),
            ProtocolPathDurationSample(path: .currentHTTPWebSocket, durationMilliseconds: 30),
            ProtocolPathDurationSample(path: .quicPrototype, durationMilliseconds: 8),
            ProtocolPathDurationSample(path: .quicPrototype, durationMilliseconds: 12),
        ]
        let report = HTTP3PrototypeComparison.report(samples: samples)

        XCTAssertEqual(report.evidenceStatus, .sideBySideAggregatesOnly)
        XCTAssertEqual(report.currentHTTPWebSocket.count, 2)
        XCTAssertEqual(report.currentHTTPWebSocket.totalMilliseconds, 40)
        XCTAssertEqual(report.currentHTTPWebSocket.maxMilliseconds, 30)
        XCTAssertEqual(report.currentHTTPWebSocket.meanMilliseconds, 20)
        XCTAssertEqual(report.currentHTTPWebSocket.p50Milliseconds, 10)
        XCTAssertEqual(report.currentHTTPWebSocket.p95Milliseconds, 30)
        XCTAssertEqual(report.currentHTTPWebSocket.p99Milliseconds, 30)

        XCTAssertEqual(report.quicPrototype.count, 2)
        XCTAssertEqual(report.quicPrototype.totalMilliseconds, 20)
        XCTAssertEqual(report.quicPrototype.maxMilliseconds, 12)
        XCTAssertEqual(report.quicPrototype.meanMilliseconds, 10)
        XCTAssertEqual(report.quicPrototype.p50Milliseconds, 8)
        XCTAssertEqual(report.quicPrototype.p95Milliseconds, 12)
        XCTAssertEqual(report.quicPrototype.p99Milliseconds, 12)

        XCTAssertEqual(report.nonClaims, HTTP3PrototypeComparisonReport.fixedNonClaims)
        XCTAssertFalse(
            report.exportJSONString().contains("winner"),
            "side-by-side status must not encode a transport winner"
        )
    }

    func test_report_clampsNonFiniteAndNegativeSamples() {
        // WHY: tainted external inputs must not invent pressure or negative
        // duration totals that break offline tooling. Sanitized values also
        // feed nearest-rank percentiles (zeros for bad samples).
        let samples: [ProtocolPathDurationSample] = [
            ProtocolPathDurationSample(path: .currentHTTPWebSocket, durationMilliseconds: -4),
            ProtocolPathDurationSample(path: .currentHTTPWebSocket, durationMilliseconds: .infinity),
            ProtocolPathDurationSample(path: .currentHTTPWebSocket, durationMilliseconds: .nan),
            ProtocolPathDurationSample(path: .quicPrototype, durationMilliseconds: 7),
            ProtocolPathDurationSample(path: .quicPrototype, durationMilliseconds: -.infinity),
        ]
        let report = HTTP3PrototypeComparison.report(samples: samples)

        XCTAssertEqual(report.currentHTTPWebSocket.count, 3)
        XCTAssertEqual(report.currentHTTPWebSocket.totalMilliseconds, 0)
        XCTAssertEqual(report.currentHTTPWebSocket.maxMilliseconds, 0)
        XCTAssertEqual(report.currentHTTPWebSocket.p50Milliseconds, 0)
        XCTAssertEqual(report.currentHTTPWebSocket.p95Milliseconds, 0)
        XCTAssertEqual(report.currentHTTPWebSocket.p99Milliseconds, 0)
        XCTAssertEqual(report.quicPrototype.count, 2)
        XCTAssertEqual(report.quicPrototype.totalMilliseconds, 7)
        XCTAssertEqual(report.quicPrototype.maxMilliseconds, 7)
        // Sanitized series [7, 0] sorted [0, 7]: p50 rank 1 → 0; p95/p99 rank 2 → 7.
        XCTAssertEqual(report.quicPrototype.p50Milliseconds, 0)
        XCTAssertEqual(report.quicPrototype.p95Milliseconds, 7)
        XCTAssertEqual(report.quicPrototype.p99Milliseconds, 7)
        XCTAssertEqual(report.evidenceStatus, .sideBySideAggregatesOnly)
    }

    // MARK: - Nearest-rank percentile semantics

    func test_folding_emptySamples_percentilesAreZero() {
        // WHY: empty evidence must not invent tail latency; 0 matches the
        // aggregate-only / legacy decode safe default.
        let aggregate = ProtocolPathDurationAggregate.folding([])
        XCTAssertEqual(aggregate.count, 0)
        XCTAssertEqual(aggregate.p50Milliseconds, 0)
        XCTAssertEqual(aggregate.p95Milliseconds, 0)
        XCTAssertEqual(aggregate.p99Milliseconds, 0)
        XCTAssertNil(aggregate.meanMilliseconds)
    }

    func test_folding_singleSample_allPercentilesEqualThatSample() {
        // WHY: with n=1, nearest-rank rank is always 1 for p50/p95/p99 so the
        // sole observation is the entire tail picture — no interpolation.
        let aggregate = ProtocolPathDurationAggregate.folding([42])
        XCTAssertEqual(aggregate.count, 1)
        XCTAssertEqual(aggregate.totalMilliseconds, 42)
        XCTAssertEqual(aggregate.maxMilliseconds, 42)
        XCTAssertEqual(aggregate.p50Milliseconds, 42)
        XCTAssertEqual(aggregate.p95Milliseconds, 42)
        XCTAssertEqual(aggregate.p99Milliseconds, 42)
    }

    func test_folding_multipleSamples_nearestRankIsDeterministic() {
        // WHY: offline tooling must agree on ranks without floating interpolation.
        // Series 1...10 sorted; p50 → ceil(5)=5 → 5; p95 → ceil(9.5)=10 → 10;
        // p99 → ceil(9.9)=10 → 10.
        let aggregate = ProtocolPathDurationAggregate.folding(
            [10, 1, 9, 2, 8, 3, 7, 4, 6, 5]
        )
        XCTAssertEqual(aggregate.count, 10)
        XCTAssertEqual(aggregate.totalMilliseconds, 55)
        XCTAssertEqual(aggregate.maxMilliseconds, 10)
        XCTAssertEqual(aggregate.p50Milliseconds, 5)
        XCTAssertEqual(aggregate.p95Milliseconds, 10)
        XCTAssertEqual(aggregate.p99Milliseconds, 10)
    }

    func test_folding_outliers_raiseTailPercentilesNotP50() {
        // WHY: a single extreme must show up in p95/p99 evidence without
        // rewriting the median — that is the point of retaining tails.
        // [1, 2, 3, 1000]: p50 rank 2 → 2; p95/p99 rank 4 → 1000.
        let aggregate = ProtocolPathDurationAggregate.folding([1, 2, 3, 1000])
        XCTAssertEqual(aggregate.count, 4)
        XCTAssertEqual(aggregate.maxMilliseconds, 1000)
        XCTAssertEqual(aggregate.p50Milliseconds, 2)
        XCTAssertEqual(aggregate.p95Milliseconds, 1000)
        XCTAssertEqual(aggregate.p99Milliseconds, 1000)
    }

    func test_nearestRankPercentile_documentedSemantics() {
        // WHY: pin the 1-based ceil formula so a future rewrite cannot silently
        // switch to linear interpolation or exclusive ranking.
        let sorted = [1.0, 2.0, 3.0, 4.0]
        XCTAssertEqual(
            ProtocolPathDurationAggregate.nearestRankPercentile(
                sortedAscending: sorted,
                percentile: 50
            ),
            2
        )
        XCTAssertEqual(
            ProtocolPathDurationAggregate.nearestRankPercentile(
                sortedAscending: [],
                percentile: 99
            ),
            0
        )
    }

    // MARK: - Existing queue-metric shape reuse

    func test_report_fromOutboundQueueLane_reusesExistingCountTotalMaxShape() {
        // WHY: the current path already exposes count/total/max on connection
        // metrics; the comparison must accept that shape without inventing a
        // parallel metric vocabulary or changing /v1/health schemas.
        // Lane has no sample series → percentiles stay at the safe default 0.
        var lane = OutboundQueueWaitLaneMetrics.zero
        lane.record(waitMilliseconds: 12)
        lane.record(waitMilliseconds: 18)

        let report = HTTP3PrototypeComparison.report(
            currentLane: lane,
            quicPrototype: ProtocolPathDurationAggregate(
                count: 2,
                totalMilliseconds: 20,
                maxMilliseconds: 11
            )
        )

        XCTAssertEqual(report.currentHTTPWebSocket.count, 2)
        XCTAssertEqual(report.currentHTTPWebSocket.totalMilliseconds, 30)
        XCTAssertEqual(report.currentHTTPWebSocket.maxMilliseconds, 18)
        XCTAssertEqual(report.currentHTTPWebSocket.meanMilliseconds, 15)
        XCTAssertEqual(report.currentHTTPWebSocket.p50Milliseconds, 0)
        XCTAssertEqual(report.currentHTTPWebSocket.p95Milliseconds, 0)
        XCTAssertEqual(report.currentHTTPWebSocket.p99Milliseconds, 0)
        XCTAssertEqual(report.evidenceStatus, .sideBySideAggregatesOnly)
    }

    // MARK: - Codable compatibility

    func test_aggregate_decodesLegacyJSONWithoutPercentileFields() throws {
        // WHY: additive fields must not break offline tooling that still
        // stores count/total/max-only payloads from earlier report versions.
        let legacy = Data(
            #"""
            {
              "count": 2,
              "total_milliseconds": 40,
              "max_milliseconds": 30
            }
            """#.utf8
        )
        let decoded = try JSONDecoder().decode(ProtocolPathDurationAggregate.self, from: legacy)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded.totalMilliseconds, 40)
        XCTAssertEqual(decoded.maxMilliseconds, 30)
        XCTAssertEqual(decoded.p50Milliseconds, 0)
        XCTAssertEqual(decoded.p95Milliseconds, 0)
        XCTAssertEqual(decoded.p99Milliseconds, 0)
        XCTAssertEqual(decoded.meanMilliseconds, 20)
    }

    func test_aggregate_roundTripsPercentileFields() throws {
        // WHY: new exporters must re-read the tail fields they wrote.
        let original = ProtocolPathDurationAggregate.folding([1, 2, 3, 1000])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProtocolPathDurationAggregate.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.p50Milliseconds, 2)
        XCTAssertEqual(decoded.p95Milliseconds, 1000)
        XCTAssertEqual(decoded.p99Milliseconds, 1000)
    }

    // MARK: - Export contract

    func test_exportJSON_isDeterministicSecretFreeAndSchemaIsolated() throws {
        // WHY: offline tooling needs stable bytes; the report must stay free of
        // hosts/tokens and must not imply production health schema changes.
        let report = HTTP3PrototypeComparison.report(
            currentHTTPWebSocket: ProtocolPathDurationAggregate.folding([4, 10, 20]),
            quicPrototype: ProtocolPathDurationAggregate.folding([3, 9])
        )
        let first = report.exportJSON()
        let second = report.exportJSON()
        XCTAssertEqual(first, second, "export must be deterministic for fixed inputs")

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: first) as? [String: Any]
        )
        XCTAssertEqual(
            Set(object.keys),
            [
                "current_http_websocket",
                "quic_prototype",
                "evidence_status",
                "non_claims",
            ]
        )
        XCTAssertEqual(
            object["evidence_status"] as? String,
            ProtocolComparisonEvidenceStatus.sideBySideAggregatesOnly.rawValue
        )
        let nonClaims = try XCTUnwrap(object["non_claims"] as? [String])
        XCTAssertEqual(nonClaims, HTTP3PrototypeComparisonReport.fixedNonClaims)

        let current = try XCTUnwrap(object["current_http_websocket"] as? [String: Any])
        XCTAssertEqual(
            Set(current.keys),
            [
                "count",
                "total_milliseconds",
                "max_milliseconds",
                "p50_milliseconds",
                "p95_milliseconds",
                "p99_milliseconds",
            ]
        )
        // [4, 10, 20]: p50 rank 2 → 10; p95/p99 rank 3 → 20.
        XCTAssertEqual(current["p50_milliseconds"] as? Double, 10)
        XCTAssertEqual(current["p95_milliseconds"] as? Double, 20)
        XCTAssertEqual(current["p99_milliseconds"] as? Double, 20)

        let text = report.exportJSONString()
        XCTAssertFalse(text.contains("token"), "must not emit token material")
        XCTAssertFalse(text.contains("bearer"), "must not emit bearer material")
        XCTAssertFalse(text.contains("127.0.0.1"), "must not embed hosts")
        XCTAssertFalse(text.contains("active_clients"), "must not couple to /v1/health fields")
        XCTAssertFalse(text.contains("outbound_latency_pressure"), "must not rewrite health pressure schema")
        XCTAssertFalse(text.contains("winner"), "must not encode a transport winner")
        // Non-claims intentionally include the token "performance_gain"; assert no
        // affirmative claim *field* is invented (object already checked above).
        XCTAssertNil(object["performance_gain"], "must not invent a gain claim field")
        XCTAssertNil(object["ready"], "must not invent a readiness claim field")
        XCTAssertNil(object["winner"], "must not invent a winner claim field")
    }

    func test_exportJSON_fixedNonClaimsAreStable() {
        // WHY: consumers key off the fixed non-claim codes; regenerating a
        // report with samples must not drop or rename them.
        let empty = HTTP3PrototypeComparison.report(
            currentHTTPWebSocket: .zero,
            quicPrototype: .zero
        )
        let withSamples = HTTP3PrototypeComparison.report(
            samples: [
                ProtocolPathDurationSample(path: .currentHTTPWebSocket, durationMilliseconds: 1),
                ProtocolPathDurationSample(path: .quicPrototype, durationMilliseconds: 2),
            ]
        )
        XCTAssertEqual(empty.nonClaims, HTTP3PrototypeComparisonReport.fixedNonClaims)
        XCTAssertEqual(withSamples.nonClaims, HTTP3PrototypeComparisonReport.fixedNonClaims)
        XCTAssertEqual(empty.nonClaims, withSamples.nonClaims)
    }

    // MARK: - Isolation from production prototype defaults

    func test_comparison_doesNotEnableHTTP3Prototype() {
        // WHY: building a comparison report must not flip the default-off
        // HTTP3 prototype configuration or construct live protocol options.
        let before = HTTP3PrototypeConfiguration()
        XCTAssertFalse(before.enabled)

        _ = HTTP3PrototypeComparison.report(
            samples: [
                ProtocolPathDurationSample(path: .quicPrototype, durationMilliseconds: 1),
                ProtocolPathDurationSample(path: .currentHTTPWebSocket, durationMilliseconds: 2),
            ]
        )

        let after = HTTP3PrototypeConfiguration()
        XCTAssertFalse(after.enabled, "comparison must leave prototype default-off")
        XCTAssertEqual(HTTP3Prototype.assess(.disabled), .disabled)
        switch HTTP3Prototype.makeProtocolOptions(for: .disabled) {
        case .success:
            XCTFail("comparison path must not produce QUIC options from disabled config")
        case .failure(let error):
            XCTAssertEqual(error, .disabled)
        }
    }
}
