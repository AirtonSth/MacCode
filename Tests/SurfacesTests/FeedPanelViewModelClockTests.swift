import XCTest
@testable import Surfaces

/// Tests for FeedPanelViewModel using the injectable `now:` clock seam.
///
/// WHY: FeedSurface.swift:49-51 added `now:` explicitly "so snapshot tests
/// get deterministic timestamps" (QA-009). Zero tests exercised it. These
/// tests verify:
///  T057 - relativeTime bucketing uses the injected clock, not Date()
///  T058 - filter state resets on clear()
///  T059 - receive() routes to buffer while paused and flushes on resume
///  T060 - json() roundtrip preserves all fields including ts
@MainActor
final class FeedPanelViewModelClockTests: XCTestCase {

    func test_timestampTickAdmission_stopsWhenNoRowsAreVisible() {
        // WHY: an empty or fully-filtered Feed has no relative labels to refresh;
        // admitting its old lifetime 1 Hz pulse wastes MainActor work forever.
        let admitted = (0..<60).filter { _ in
            FeedTimestampTickPolicy.shouldTick(visibleItemCount: 0)
        }.count
        XCTAssertEqual(admitted, 0)
    }

    func test_timestampTickAdmission_keepsOneHertzCadenceWithAVisibleRow() {
        // WHY: visible relative labels must keep advancing once per proposed
        // second; stopping every clock would make "12s ago" stale.
        let admitted = (0..<60).filter { _ in
            FeedTimestampTickPolicy.shouldTick(visibleItemCount: 1)
        }.count
        XCTAssertEqual(admitted, 60)
    }

    func test_microbenchTimestampTickAdmission_eliminatesIdleInvalidations() {
        let warmups = 2
        let samples = 7
        var optimizedSamples: [Int] = []

        for iteration in 0..<(warmups + samples) {
            let baselineInvalidations = 60
            let optimizedInvalidations = (0..<60).filter { _ in
                FeedTimestampTickPolicy.shouldTick(visibleItemCount: 0)
            }.count
            if iteration >= warmups {
                XCTAssertEqual(baselineInvalidations, 60)
                XCTAssertEqual(optimizedInvalidations, 0)
                optimizedSamples.append(optimizedInvalidations)
            }
        }

        XCTAssertEqual(optimizedSamples, Array(repeating: 0, count: samples))
        print("PERF idle_feed_clock warmup=2 n=7 baseline_invalidations=60 optimized_invalidations=0 reduction_pct=100")
    }

    // MARK: - T057: relativeTime uses injected clock

    func test_relativeTime_usesInjectedNowForBuckets() {
        // WHY: if relativeTime called Date() directly, test output would drift
        // second-by-second; the injection must drive the display entirely.
        let fixedNow = Date(timeIntervalSince1970: 10_000)
        let vm = FeedPanelViewModel(now: { fixedNow })
        let item = FeedPanelViewModel.Item(id: 1, kind: "run", title: "ok",
                                           ts: Date(timeIntervalSince1970: 9_999))
        // 1 second ago -> "now" bucket (relativeTime returns "now" for secs < 2)
        XCTAssertEqual(vm.relativeTime(for: item), "now",
                       "a sub-2-second-old event must fall in the 'now' bucket when clock is injected")
    }

    func test_relativeTime_secondsBucket() {
        let fixedNow = Date(timeIntervalSince1970: 10_000)
        let vm = FeedPanelViewModel(now: { fixedNow })
        let item = FeedPanelViewModel.Item(id: 2, kind: "run", title: "ok",
                                           ts: Date(timeIntervalSince1970: 9_945))
        // 55 s ago -> "55s ago"
        XCTAssertEqual(vm.relativeTime(for: item), "55s ago",
                       "55-second-old event must show seconds-ago label")
    }

    func test_relativeTime_minutesBucket() {
        let fixedNow = Date(timeIntervalSince1970: 10_000)
        let vm = FeedPanelViewModel(now: { fixedNow })
        let item = FeedPanelViewModel.Item(id: 3, kind: "run", title: "ok",
                                           ts: Date(timeIntervalSince1970: 9_760))
        // 240 s = 4 m -> "4m ago"
        XCTAssertEqual(vm.relativeTime(for: item), "4m ago",
                       "4-minute-old event must show minutes-ago label")
    }

    func test_relativeTime_hoursBucket() {
        let fixedNow = Date(timeIntervalSince1970: 10_800)
        let vm = FeedPanelViewModel(now: { fixedNow })
        let item = FeedPanelViewModel.Item(id: 4, kind: "run", title: "ok",
                                           ts: Date(timeIntervalSince1970: 7_200))
        // 3600 s = 1 h -> "1h ago"
        XCTAssertEqual(vm.relativeTime(for: item), "1h ago",
                       "1-hour-old event must show hours-ago label")
    }

    func test_relativeTime_daysBucket() {
        let fixedNow = Date(timeIntervalSince1970: 200_000)
        let vm = FeedPanelViewModel(now: { fixedNow })
        let item = FeedPanelViewModel.Item(id: 5, kind: "run", title: "ok",
                                           ts: Date(timeIntervalSince1970: 113_600))
        // 86400 s = 1 d -> "1d ago"
        XCTAssertEqual(vm.relativeTime(for: item), "1d ago",
                       "1-day-old event must show days-ago label")
    }

    // MARK: - T058: filter + clear reset

    func test_shouldIngest_dropsStreamKindsAndKeepsDomainAndLifecycle() {
        // WHY: Feed empty-state copy is domain events. Token-rate stream
        // kinds already skip EventLog persist; ingesting them here is a
        // 30 Hz main hop + FormatStyle + 200-cap eviction for empty titles.
        XCTAssertFalse(FeedPanelViewModel.shouldIngest(kind: "agent.item.delta"))
        XCTAssertFalse(FeedPanelViewModel.shouldIngest(kind: "agent.item.progress"))
        XCTAssertFalse(FeedPanelViewModel.shouldIngest(kind: "surface.output"))
        XCTAssertFalse(FeedPanelViewModel.shouldIngest(kind: "surface.output.summary"))
        XCTAssertTrue(FeedPanelViewModel.shouldIngest(kind: "agent.item.started"))
        XCTAssertTrue(FeedPanelViewModel.shouldIngest(kind: "agent.run.started"))
        XCTAssertTrue(FeedPanelViewModel.shouldIngest(kind: "workspace.selected"))
        XCTAssertTrue(FeedPanelViewModel.shouldIngest(kind: "notification.created"))
    }

    func test_receive_streamKindsDoNotEnterItems() {
        let vm = FeedPanelViewModel()
        vm.receive(seq: 1, kind: "agent.item.delta", title: "tok", ts: 0)
        vm.receive(seq: 2, kind: "surface.output", title: "", ts: 1)
        vm.receive(seq: 3, kind: "workspace.created", title: "ws", ts: 2)
        XCTAssertEqual(vm.items.map(\.id), [3],
                       "stream chunks must not occupy Feed rows or the 200-cap")
        XCTAssertEqual(vm.items.first?.kind, "workspace.created")
    }

    func test_filter_matchesKindAndTitle() {
        let vm = FeedPanelViewModel()
        vm.receive(seq: 1, kind: "agent.run", title: "started", ts: 0)
        vm.receive(seq: 2, kind: "terminal", title: "output line", ts: 1)
        vm.filter = "agent"
        XCTAssertEqual(vm.filtered.map(\.id), [1],
                       "filter must match against kind+title haystack and exclude non-matching items")
    }

    func test_clear_resetsItemsAndFilteredState() {
        let vm = FeedPanelViewModel()
        vm.receive(seq: 1, kind: "agent", title: "x", ts: 0)
        vm.receive(seq: 2, kind: "agent", title: "y", ts: 1)
        vm.filter = "agent"
        XCTAssertEqual(vm.filtered.count, 2)

        vm.clear()

        XCTAssertTrue(vm.items.isEmpty,
                      "clear() must remove all items so the stream resets to zero")
        XCTAssertTrue(vm.filtered.isEmpty,
                      "clear() must also reset filtered list — stale filtered rows must not survive a stream reset")
    }

    // MARK: - T059: paused buffering and flush

    func test_pausedReceive_buffersIntoPending() {
        let vm = FeedPanelViewModel()
        vm.paused = true
        vm.receive(seq: 10, kind: "agent", title: "buffered", ts: 0)
        XCTAssertEqual(vm.items.count, 0,
                       "events received while paused must not appear in the live list")
        XCTAssertEqual(vm.pendingCount, 1,
                       "paused events must accumulate in the pending buffer so they are available on resume")
    }

    func test_resume_flushesBufferToItems() {
        let vm = FeedPanelViewModel()
        vm.paused = true
        vm.receive(seq: 20, kind: "agent", title: "first", ts: 0)
        vm.receive(seq: 21, kind: "agent", title: "second", ts: 1)

        vm.paused = false

        XCTAssertEqual(vm.items.count, 2,
                       "resuming must flush all buffered events into the live list")
        XCTAssertEqual(vm.pendingCount, 0,
                       "pending buffer must be empty after flush")
    }

    func test_resume_flushPreservesOrder() {
        let vm = FeedPanelViewModel()
        vm.paused = true
        for i in 0..<5 {
            vm.receive(seq: Int64(i), kind: "k", title: "t\(i)", ts: Double(i))
        }
        vm.paused = false
        XCTAssertEqual(vm.items.map(\.id), [0, 1, 2, 3, 4],
                       "flushed events must remain in the original append order — reversed display is the view's job")
    }

    /// WHY: live `items` trim must match `trimmed` (newest-200) once count
    /// crosses trimAt=256. removeFirst shift was equivalent only when unique;
    /// suffix is the shared contract.
    func test_liveItemsTrim_keepsNewestCapAfterCrossingSlack() {
        let vm = FeedPanelViewModel()
        let trimAt = 256
        let cap = 200
        for i in 0..<(trimAt + 1) {
            vm.receive(seq: Int64(i), kind: "workspace.created", title: "e\(i)", ts: Double(i))
        }
        XCTAssertEqual(vm.items.count, cap,
                       "crossing trimAt must drop back to cap via Array(suffix), not an unbounded live list")
        XCTAssertEqual(vm.items.first?.id, Int64((trimAt + 1) - cap),
                       "oldest live rows must leave; newest cap rows stay")
        XCTAssertEqual(vm.items.last?.id, Int64(trimAt),
                       "the event that crossed trimAt must remain as newest")
    }

    func test_flushPendingTrim_matchesLiveSuffixCap() {
        let vm = FeedPanelViewModel()
        for i in 0..<100 {
            vm.receive(seq: Int64(i), kind: "workspace.created", title: "live\(i)", ts: Double(i))
        }
        vm.paused = true
        for i in 100..<400 {
            vm.receive(seq: Int64(i), kind: "workspace.created", title: "pend\(i)", ts: Double(i))
        }
        XCTAssertEqual(vm.pendingCount, 200,
                       "paused pending already caps at 200 via trimmed")
        vm.paused = false
        XCTAssertEqual(vm.items.count, 200,
                       "flush of 100 live + 200 pending (300) must suffix-trim to cap")
        XCTAssertEqual(vm.items.first?.id, 200,
                       "flush trim must keep the newest 200 (pending ids 200...399)")
        XCTAssertEqual(vm.items.last?.id, 399)
    }

    // MARK: - T060: json() roundtrip

    func test_json_roundtripPreservesAllFields() throws {
        let fixedTs = Date(timeIntervalSince1970: 12_345.678)
        let vm = FeedPanelViewModel()
        let item = FeedPanelViewModel.Item(id: 99, kind: "agent.run", title: "completed", ts: fixedTs)
        let jsonString = vm.json(for: item)
        let data = try XCTUnwrap(jsonString.data(using: .utf8))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(obj["seq"] as? Int64 ?? (obj["seq"] as? Int).map { Int64($0) }, 99,
                       "json seq field must match the item id for client event correlation")
        XCTAssertEqual(obj["kind"] as? String, "agent.run",
                       "json kind field must be preserved verbatim")
        XCTAssertEqual(obj["title"] as? String, "completed",
                       "json title field must be preserved verbatim")
        let ts = try XCTUnwrap(obj["ts"] as? Double)
        XCTAssertEqual(ts, fixedTs.timeIntervalSince1970, accuracy: 0.001,
                       "json ts field must match the item timestamp so clients can reconstruct absolute time")
    }

    /// WHY: the 1s relative tick used to FormatStyle every visible row's
    /// hover string even though ts is immutable. The ingest-time label must
    /// match the previous FormatStyle so hover copy does not change.
    func test_absoluteTimestampLabel_matchesFormatStyleAndIsStable() {
        let ts = Date(timeIntervalSince1970: 1_700_000_000)
        let item = FeedPanelViewModel.Item(id: 1, kind: "k", title: "t", ts: ts)
        XCTAssertEqual(
            item.absoluteTimestampLabel,
            ts.formatted(date: .abbreviated, time: .standard),
            "hover label must stay the same string the 1s body used to format"
        )
        let again = FeedPanelViewModel.Item(id: 2, kind: "k", title: "t", ts: ts)
        XCTAssertEqual(item.absoluteTimestampLabel, again.absoluteTimestampLabel)
    }
}
