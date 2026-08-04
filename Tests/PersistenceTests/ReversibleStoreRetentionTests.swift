import XCTest
@testable import Persistence

/// Proves handle-protected retention (plan-final W3): prune never deletes
/// marker-reachable originals. ref_count alone is NOT a production gate.
final class ReversibleStoreRetentionTests: XCTestCase {
    private func makeStore() throws -> ReversibleContentStore {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        return ReversibleContentStore(db: db)
    }

    private let farFutureCutoffMs: Int64 = 4_000_000_000_000

    func test_pruneWithoutProtectedHandlesIsNoOp() throws {
        let store = try makeStore()
        let handle = try store.store("must survive fail-closed prune")
        XCTAssertEqual(
            try store.pruneUnreferenced(olderThanMs: farFutureCutoffMs, protectedHandles: nil),
            0,
            "nil protectedHandles must never delete (ref_count is untrusted in prod)"
        )
        XCTAssertNotNil(try store.retrieve(handle))
    }

    func test_blockOutlivesProtectedHandleSet() throws {
        let store = try makeStore()
        let shared = try store.store("shared by two threads")
        let orphan = try store.store("orphan old content")

        // Protected set models durableReferencedHandles (marker-reachable).
        let protected: Set<String> = [shared]
        XCTAssertEqual(
            try store.pruneUnreferenced(olderThanMs: farFutureCutoffMs, protectedHandles: protected),
            1,
            "only unprotected orphan is removed"
        )
        XCTAssertNotNil(try store.retrieve(shared), "protected handle survives")
        XCTAssertNil(try store.retrieve(orphan))
    }

    func test_emptyProtectedSetRemovesAllAgedRows() throws {
        let store = try makeStore()
        let a = try store.store("a")
        let b = try store.store("b")
        XCTAssertEqual(
            try store.pruneUnreferenced(olderThanMs: farFutureCutoffMs, protectedHandles: []),
            2
        )
        XCTAssertNil(try store.retrieve(a))
        XCTAssertNil(try store.retrieve(b))
    }
}
