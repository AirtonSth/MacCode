import XCTest
@testable import Persistence

final class PerfSwitchMetricsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        PerfSwitchMetrics.resetForTesting()
    }

    override func tearDown() {
        PerfSwitchMetrics.resetForTesting()
        super.tearDown()
    }

    func test_tabSwitchInterval_recordsInstallAndCommitted() {
        // WHY: PF-00 (a) must produce a measurable tab-switch interval so later
        // PF-10/11 claims have a comparable instrument, not a log line.
        PerfSwitchMetrics.beginTabSwitch(surfaceID: "surface-a")
        PerfSwitchMetrics.endTabSwitchInstall()
        PerfSwitchMetrics.endTabSwitchCommitted()
        let names = PerfSwitchMetrics.recordedIntervalsForTesting().map(\.name)
        XCTAssertTrue(
            names.contains("tab_switch"),
            "committed-frame end must record the tab_switch interval for Instruments + the sample script"
        )
    }

    func test_conversationSwitch_recordsFirstPublishThenHydrate() {
        // WHY: PF-00 (b) is click → first objectWillChange → open bundle apply.
        // The first-publish mark must be a distinct recorded interval so we can
        // see acknowledgement vs settled hydrate.
        PerfSwitchMetrics.beginConversationSwitch(threadID: "thread-a")
        PerfSwitchMetrics.markConversationFirstPublish()
        PerfSwitchMetrics.endConversationHydrate()
        let names = Set(PerfSwitchMetrics.recordedIntervalsForTesting().map(\.name))
        XCTAssertTrue(names.contains("conversation_first_publish"))
        XCTAssertTrue(names.contains("conversation_switch"))
        XCTAssertEqual(
            PerfSwitchMetrics.recordedIntervalsForTesting().filter { $0.name == "conversation_first_publish" }.count,
            1,
            "duplicate objectWillChange marks on the same open must not invent extra publishes"
        )
        PerfSwitchMetrics.markConversationFirstPublish()
        XCTAssertEqual(
            PerfSwitchMetrics.recordedIntervalsForTesting().filter { $0.name == "conversation_first_publish" }.count,
            1
        )
    }

    func test_percentileHelper_p50AndP95() {
        let values: [UInt64] = [1_000_000, 2_000_000, 3_000_000, 4_000_000, 100_000_000]
        XCTAssertEqual(PerfSwitchMetrics.percentileMilliseconds(values, percentile: 50), 3.0)
        XCTAssertEqual(PerfSwitchMetrics.percentileMilliseconds(values, percentile: 95), 100.0)
        XCTAssertNil(PerfSwitchMetrics.percentileMilliseconds([], percentile: 50))
    }

    func test_performSyncOnMain_recordsWaitWhenWriterHoldsTheQueue() throws {
        // WHY: PF-00 (c) must see main-thread SQLite waits — the 13 NSRecursiveLock
        // samples in the 2026-09-02 idle capture were exactly this path.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RC2PerfSwitch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try SQLiteDB(path: dir.appendingPathComponent("perf.sqlite").path)
        try db.execute("CREATE TABLE t(id INTEGER PRIMARY KEY);")

        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            db.performSync { _ in
                started.signal()
                Thread.sleep(forTimeInterval: 0.025)
            }
            finished.signal()
        }
        started.wait()
        PerfSwitchMetrics.resetForTesting()
        _ = db.performSync { _ in 1 }
        finished.wait()

        XCTAssertGreaterThan(
            PerfSwitchMetrics.mainThreadSyncCountForTesting(),
            0,
            "a main-thread performSync behind a writer must record sqlite_main_sync"
        )
        let maxWait = PerfSwitchMetrics.mainThreadSyncNanosecondsForTesting().max() ?? 0
        XCTAssertGreaterThan(
            maxWait,
            2_000_000,
            "the held writer must produce a >2ms main wait so DEBUG stack logging is exercised"
        )
        XCTAssertGreaterThan(
            PerfSwitchMetrics.slowMainSyncLogCountForTesting(),
            0,
            "DEBUG builds must keep a stack when main-thread SQLite waits exceed 2ms"
        )
        XCTAssertGreaterThan(PerfSwitchMetrics.queueOccupiedNanosecondsForTesting(), 0)
        XCTAssertTrue(
            PerfSwitchMetrics.recordedIntervalsForTesting().contains { $0.name == "sqlite_main_sync" }
        )
    }
}
