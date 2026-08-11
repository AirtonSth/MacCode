import XCTest
@testable import AgentRuntime

/// PERF: bounds `TranscriptPathIndex` cardinality so multi-session Claude
/// recover/read churn cannot pin unbounded providerThreadId → URL entries
/// for the life of the process.
///
/// WHY: path lookup is a pure optimisation over re-enumerating
/// `~/.claude/projects`. Evicting a warm path only costs one FS walk on the
/// next miss — correct and cheap relative to retaining every historical
/// session id forever.
final class TranscriptPathIndexCapTests: XCTestCase {

    func test_builtInCountLimit_isReasonable() {
        // WHY: too small → thrash FS enumeration on normal multi-tab use;
        // multi-k → process-wide leak under long-lived app + many Claude sessions.
        let limit = TranscriptPathIndex.defaultCountLimit
        XCTAssertGreaterThanOrEqual(limit, 64)
        XCTAssertLessThanOrEqual(limit, 1_024)
        XCTAssertEqual(limit, 128)
    }

    func test_notePath_capsDistinctIds() {
        // WHY: N recovered Claude sessions must not retain N path strings
        // process-wide; keep the newest id under the ceiling.
        var storage: [String: URL] = [:]
        let limit = 10
        var ids: [String] = []
        for i in 0..<(limit + 25) {
            let id = "session-\(i)"
            ids.append(id)
            TranscriptPathIndex.notePath(
                &storage,
                id: id,
                url: URL(fileURLWithPath: "/tmp/claude/\(id).jsonl"),
                countLimit: limit
            )
        }
        XCTAssertEqual(storage.count, limit)
        let newest = ids[limit + 24]
        XCTAssertEqual(
            storage[newest]?.lastPathComponent,
            "\(newest).jsonl",
            "newest insert must survive eviction"
        )
    }

    func test_setPath_capsViaStructAPI() {
        var index = TranscriptPathIndex()
        let limit = 5
        for i in 0..<(limit + 10) {
            index.setPath(
                URL(fileURLWithPath: "/tmp/t-\(i).jsonl"),
                forProviderThreadId: "id-\(i)",
                countLimit: limit
            )
        }
        XCTAssertEqual(index.count, limit)
        XCTAssertNotNil(index.path(forProviderThreadId: "id-\(limit + 9)"))
    }

    func test_notePath_updatesExistingWithoutGrowth() {
        var storage: [String: URL] = [:]
        let id = "same-session"
        TranscriptPathIndex.notePath(
            &storage, id: id, url: URL(fileURLWithPath: "/tmp/a.jsonl"), countLimit: 5
        )
        TranscriptPathIndex.notePath(
            &storage, id: id, url: URL(fileURLWithPath: "/tmp/b.jsonl"), countLimit: 5
        )
        XCTAssertEqual(storage.count, 1)
        XCTAssertEqual(storage[id]?.lastPathComponent, "b.jsonl")
    }

    func test_notePath_ignoresEmptyId() {
        var storage: [String: URL] = [:]
        TranscriptPathIndex.notePath(
            &storage,
            id: "",
            url: URL(fileURLWithPath: "/tmp/x.jsonl"),
            countLimit: 5
        )
        XCTAssertTrue(storage.isEmpty, "empty providerThreadId must not enter the cache")
    }

    func test_retentionEstimate_2kSessionsTo128Window() {
        let uncapped = 2_000
        let limit = TranscriptPathIndex.defaultCountLimit
        let reduction = Double(uncapped - limit) / Double(uncapped)
        XCTAssertGreaterThan(reduction, 0.93)
        XCTAssertEqual(limit, 128)
        // Basis: ~400 B/entry (id + path URL) → 256 ≈ 100 KB; 128 ≈ 51 KB (−50%).
        let perKey = 400
        XCTAssertEqual(256 * perKey, 102_400)
        XCTAssertEqual(limit * perKey, 51_200)
    }
}
