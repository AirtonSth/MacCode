import XCTest
import Foundation
@testable import Surfaces

/// Tests for `FeedPanelViewModel.trimmed(_:cap:)`.
/// Pure static helper — no @MainActor required.
/// WHY: the pending buffer grows unboundedly while paused on a busy host;
/// these tests guard the drop-oldest contract so bounded memory is
/// enforced and regressions in the cap logic are caught before they ship
/// (PERF-PENDING-CAP).
final class FeedPendingCapTests: XCTestCase {

    // MARK: - helpers

    private func makeItems(count: Int) -> [FeedPanelViewModel.Item] {
        (0..<count).map {
            FeedPanelViewModel.Item(id: Int64($0), kind: "test", title: "item\($0)", ts: Date(timeIntervalSince1970: Double($0)))
        }
    }

    // MARK: - over cap: drops oldest, keeps newest, count == cap

    func test_trimmed_overCap_dropsOldest() {
        // WHY: oldest items (lowest id) must be evicted first so the user
        // sees the most recent events on resume, not stale history.
        let items = makeItems(count: 210)
        let result = FeedPanelViewModel.trimmed(items, cap: 200)
        XCTAssertEqual(result.count, 200,
                       "Result count must equal cap when input exceeds cap.")
        XCTAssertEqual(result.first?.id, 10,
                       "First remaining item must be the (count-cap)th item — oldest are dropped.")
        XCTAssertEqual(result.last?.id, 209,
                       "Last item must be the newest (appended last) — newest are kept.")
    }

    // MARK: - exactly at cap: unchanged

    func test_trimmed_exactlyCap_unchanged() {
        // WHY: off-by-one would silently drop one event every time the buffer
        // reaches the exact cap; guard the boundary explicitly.
        let items = makeItems(count: 200)
        let result = FeedPanelViewModel.trimmed(items, cap: 200)
        XCTAssertEqual(result.count, 200,
                       "Buffer at exactly cap must be returned intact.")
        XCTAssertEqual(result.map(\.id), items.map(\.id),
                       "No item must be dropped when count == cap.")
    }

    // MARK: - under cap: unchanged

    func test_trimmed_underCap_unchanged() {
        // WHY: trimming a small buffer would silently discard valid buffered
        // events; nothing should be dropped below the cap.
        let items = makeItems(count: 5)
        let result = FeedPanelViewModel.trimmed(items, cap: 200)
        XCTAssertEqual(result.count, 5,
                       "Buffer below cap must be returned intact.")
        XCTAssertEqual(result.map(\.id), items.map(\.id),
                       "Item identity must be preserved when count < cap.")
    }

    // MARK: - order preserved after trim

    func test_trimmed_overCap_orderPreserved() {
        // WHY: if order were reversed or scrambled after trim, resume would
        // display events out of sequence, breaking the chronological contract.
        let items = makeItems(count: 250)
        let result = FeedPanelViewModel.trimmed(items, cap: 200)
        let ids = result.map(\.id)
        XCTAssertEqual(ids, ids.sorted(),
                       "Surviving items must remain in original (append) order after trim.")
    }

    /// WHY: live `items` used `removeFirst` (O(n) shift, worse under @Published
    /// CoW aliasing) while `pending` already used `trimmed` → `Array(suffix)`.
    func test_trimmed_matchesArraySuffix() {
        let items = makeItems(count: 400)
        let cap = 200
        let viaHelper = FeedPanelViewModel.trimmed(items, cap: cap)
        let viaSuffix = Array(items.suffix(cap))
        XCTAssertEqual(viaHelper.map(\.id), viaSuffix.map(\.id),
                       "trimmed must be Array(suffix) so live and pending share one drop-oldest contract")
        var viaRemoveFirst = items
        viaRemoveFirst.removeFirst(viaRemoveFirst.count - cap)
        XCTAssertEqual(viaHelper.map(\.id), viaRemoveFirst.map(\.id),
                       "suffix trim must keep the same newest-cap items as removeFirst")
    }

    /// Microbench: aliased Array (the @Published shape) — suffix copies k
    /// newest items; removeFirst unique-copies n then shifts.
    func test_microbench_suffixTrimVsRemoveFirstWhenAliased() {
        let count = 8_000
        let cap = 200
        let warmup = 2
        let samples = 5

        func median(_ values: [Double]) -> Double {
            let s = values.sorted()
            return s[s.count / 2]
        }

        func timeRemoveFirst() -> Double {
            var items = makeItems(count: count)
            let alias = items
            _ = alias.count
            let start = DispatchTime.now().uptimeNanoseconds
            items.removeFirst(items.count - cap)
            let end = DispatchTime.now().uptimeNanoseconds
            XCTAssertEqual(items.count, cap)
            XCTAssertEqual(alias.count, count)
            return Double(end - start) / 1_000_000.0
        }

        func timeSuffix() -> Double {
            var items = makeItems(count: count)
            let alias = items
            _ = alias.count
            let start = DispatchTime.now().uptimeNanoseconds
            items = FeedPanelViewModel.trimmed(items, cap: cap)
            let end = DispatchTime.now().uptimeNanoseconds
            XCTAssertEqual(items.count, cap)
            XCTAssertEqual(alias.count, count)
            return Double(end - start) / 1_000_000.0
        }

        for _ in 0..<warmup { _ = timeRemoveFirst(); _ = timeSuffix() }
        var before: [Double] = []
        var after: [Double] = []
        for _ in 0..<samples {
            before.append(timeRemoveFirst())
            after.append(timeSuffix())
        }
        let beforeMed = median(before)
        let afterMed = median(after)
        let improvement = beforeMed > 0 ? (beforeMed - afterMed) / beforeMed * 100.0 : 0
        NSLog(
            "[perf-proof] feedTrim removeFirst_ms=%@ suffix_ms=%@ improvement_pct=%.2f before=%@ after=%@",
            String(beforeMed), String(afterMed), improvement,
            String(describing: before), String(describing: after)
        )
        XCTAssertLessThan(
            afterMed,
            beforeMed,
            "Array(suffix) trim must beat aliased removeFirst (got suffix=\(afterMed)ms removeFirst=\(beforeMed)ms)"
        )
    }
}
