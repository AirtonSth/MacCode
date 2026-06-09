import XCTest
@testable import SocketServer
import CoreModel

// BoundedReceiptCache is a value type (struct) with no actor isolation,
// so these tests run on the default executor without @MainActor.
final class VolatileCommandReceiptsTests: XCTestCase {

    // MARK: - LRU cap eviction

    /// Inserting > cap entries must evict the oldest entries so that count
    /// never exceeds cap. The evicted key must no longer be present.
    func testCapEvictsOldestEntry() {
        var cache = BoundedReceiptCache(cap: 3, ttl: 300)
        cache.insert(key: "a", value: .string("1"))
        cache.insert(key: "b", value: .string("2"))
        cache.insert(key: "c", value: .string("3"))
        // At cap — adding one more must drop "a" (oldest)
        cache.insert(key: "d", value: .string("4"))

        XCTAssertEqual(cache.count, 3, "count must stay at cap after eviction")
        XCTAssertNil(cache.value(for: "a"), "oldest entry 'a' must be evicted")
        XCTAssertNotNil(cache.value(for: "b"), "second-oldest 'b' must survive first eviction")
        XCTAssertNotNil(cache.value(for: "c"))
        XCTAssertNotNil(cache.value(for: "d"))
    }

    /// Multiple insertions beyond cap must evict multiple oldest entries
    /// in insertion order.
    func testCapEvictsMultipleOldestEntries() {
        var cache = BoundedReceiptCache(cap: 2, ttl: 300)
        cache.insert(key: "x", value: .string("x"))
        cache.insert(key: "y", value: .string("y"))
        cache.insert(key: "z", value: .string("z"))

        XCTAssertNil(cache.value(for: "x"), "'x' (oldest) must be evicted")
        XCTAssertNotNil(cache.value(for: "y"))
        XCTAssertNotNil(cache.value(for: "z"))
        XCTAssertEqual(cache.count, 2)
    }

    // MARK: - TTL eviction

    /// An entry inserted with a TTL of 0 must be treated as absent on the
    /// very next lookup — this guarantees re-execution is allowed once the
    /// TTL window closes.
    func testExpiredEntryTreatedAsAbsent() {
        var cache = BoundedReceiptCache(cap: 256, ttl: 0)
        cache.insert(key: "req-1", value: .bool(true))
        // TTL=0: every lookup is already past the deadline.
        XCTAssertNil(cache.value(for: "req-1"),
                     "entry past TTL must return nil so re-execution is allowed")
    }

    /// An entry inserted with a generous TTL must still be deduped.
    func testFreshEntryDedupesWithinTTL() {
        var cache = BoundedReceiptCache(cap: 256, ttl: 300)
        let payload = JSONValue.string("result-payload")
        cache.insert(key: "method:req-abc", value: payload)
        XCTAssertEqual(cache.value(for: "method:req-abc"), payload,
                       "fresh entry within TTL must be returned for deduplication")
    }

    // MARK: - Idempotency semantics preserved

    /// Inserting the same key twice must not grow count (update-in-place).
    func testDuplicateInsertDoesNotGrowCount() {
        var cache = BoundedReceiptCache(cap: 256, ttl: 300)
        cache.insert(key: "dup", value: .string("v1"))
        cache.insert(key: "dup", value: .string("v2"))
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.value(for: "dup"), .string("v2"))
    }

    /// A key absent from the cache must return nil (no phantom dedup).
    func testMissingKeyReturnsNil() {
        let cache = BoundedReceiptCache(cap: 256, ttl: 300)
        XCTAssertNil(cache.value(for: "nonexistent"))
    }
}
