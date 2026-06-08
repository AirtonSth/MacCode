import XCTest
@testable import Persistence

/// Proves the sound core of P4 (SharedContext): a content-addressed block shared across
/// threads/agents is retained until the UNION of all referencing threads has released it
/// — never the single introducing thread — so a deduped reference can never dangle.
final class ReversibleStoreRetentionTests: XCTestCase {
    private func makeStore() throws -> ReversibleContentStore {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        return ReversibleContentStore(db: db)
    }

    // Far-future cutoff: age is always satisfied, so ref-count alone gates pruning.
    private let farFutureCutoffMs: Int64 = 4_000_000_000_000

    func test_blockOutlivesUnionOfReferencingThreads() throws {
        let store = try makeStore()
        let handle = try store.store("a file block re-read by both a Claude run and a Codex run")

        // Two threads (cross-agent) reference the same content-addressed block.
        try store.retain(handle)
        try store.retain(handle)
        XCTAssertEqual(try store.pruneUnreferenced(olderThanMs: farFutureCutoffMs), 0, "ref=2 => never pruned")
        XCTAssertNotNil(try store.retrieve(handle))

        // Thread A closes.
        try store.release(handle)
        XCTAssertEqual(try store.pruneUnreferenced(olderThanMs: farFutureCutoffMs), 0, "still held by B (ref=1) => survives")
        XCTAssertNotNil(try store.retrieve(handle), "resuming B can still recover the block")

        // Thread B closes — now unreferenced by the whole union.
        try store.release(handle)
        XCTAssertEqual(try store.pruneUnreferenced(olderThanMs: farFutureCutoffMs), 1, "last reference gone => prunable")
        XCTAssertNil(try store.retrieve(handle))
    }

    func test_refCountClampsAtZero() throws {
        let store = try makeStore()
        let handle = try store.store("x")
        try store.release(handle)
        try store.release(handle) // over-release must not drive ref below 0
        try store.retain(handle)  // => ref should be 1, not 0
        XCTAssertEqual(try store.pruneUnreferenced(olderThanMs: farFutureCutoffMs), 0, "ref clamped then +1 => referenced, survives")
        XCTAssertNotNil(try store.retrieve(handle))
    }
}
