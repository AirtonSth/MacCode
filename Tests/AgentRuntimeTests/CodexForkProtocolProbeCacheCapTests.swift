import XCTest
@testable import AgentRuntime

/// PERF: bounds the process-wide Codex fork-protocol probe cache so binary
/// path/identity churn cannot pin unbounded probe results process-wide.
///
/// WHY: each entry retains a reason string and support flag keyed by resolved
/// path + file size + mtime. Without a ceiling, long-lived apps that try many
/// Codex install locations retain every historical probe forever. Misses only
/// re-run the short schema probe (same as cold start).
final class CodexForkProtocolProbeCacheCapTests: XCTestCase {

    func test_builtInCountLimit_matchesDiscoveryCacheOrder() {
        XCTAssertEqual(CodexForkProtocolSupport.probeCacheCountLimit, 32)
    }

    func test_noteProbeCacheEntry_capsDistinctKeys() {
        var values: [String: CodexForkProtocolSupport] = [:]
        let limit = 8
        var newest = ""
        for i in 0..<(limit + 20) {
            newest = "/opt/codex-\(i)"
            CodexForkProtocolSupport.noteProbeCacheEntry(
                &values,
                key: newest,
                value: CodexForkProtocolSupport(
                    isSupported: i % 2 == 0,
                    reason: "probe-\(i)"
                ),
                countLimit: limit
            )
        }
        XCTAssertEqual(values.count, limit)
        XCTAssertEqual(values[newest]?.reason, "probe-\(limit + 19)")
    }

    func test_noteProbeCacheEntry_updatesExistingWithoutGrowth() {
        var values: [String: CodexForkProtocolSupport] = [:]
        let key = "/usr/local/bin/codex"
        CodexForkProtocolSupport.noteProbeCacheEntry(
            &values,
            key: key,
            value: CodexForkProtocolSupport(isSupported: false, reason: "v1"),
            countLimit: 5
        )
        CodexForkProtocolSupport.noteProbeCacheEntry(
            &values,
            key: key,
            value: CodexForkProtocolSupport(isSupported: true, reason: "v2"),
            countLimit: 5
        )
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values[key]?.reason, "v2")
        XCTAssertEqual(values[key]?.isSupported, true)
    }

    func test_noteProbeCacheEntry_keepsNewestUnderPressure() {
        var values: [String: CodexForkProtocolSupport] = [:]
        CodexForkProtocolSupport.noteProbeCacheEntry(
            &values,
            key: "old",
            value: CodexForkProtocolSupport(isSupported: false, reason: "old"),
            countLimit: 1
        )
        CodexForkProtocolSupport.noteProbeCacheEntry(
            &values,
            key: "new",
            value: CodexForkProtocolSupport(isSupported: true, reason: "new"),
            countLimit: 1
        )
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values["new"]?.reason, "new")
        XCTAssertNil(values["old"])
    }

    func test_retentionEstimate_2kKeysTo32Window() {
        let uncapped = 2_000
        let limit = CodexForkProtocolSupport.probeCacheCountLimit
        let reduction = Double(uncapped - limit) / Double(uncapped)
        XCTAssertGreaterThan(reduction, 0.98)
        XCTAssertEqual(limit, 32)
        // Basis: ~200 B/entry (path + reason) → 2k ≈ 400 KB; 32 ≈ 6.4 KB (−98%).
        let perKey = 200
        let before = uncapped * perKey
        let after = limit * perKey
        XCTAssertEqual(before, 400_000)
        XCTAssertEqual(after, 6_400)
        XCTAssertLessThan(Double(after) / Double(before), 0.02)
    }
}
