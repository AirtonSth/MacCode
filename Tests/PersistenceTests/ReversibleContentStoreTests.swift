import XCTest
@testable import Persistence
import CryptoKit
import Foundation

final class ReversibleContentStoreTests: XCTestCase {
    private func makeDB() throws -> SQLiteDB {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        return db
    }

    func test_reversibleContentSchemaStepLanded() {
        // P1-T3 introduced SchemaStep(27) (rc_reversible_content); later phases append 28+,
        // so assert the floor rather than an exact version that keeps climbing.
        XCTAssertGreaterThanOrEqual(Schema.currentVersion, 27)
    }

    func test_storeThenRetrieveByteIdentical_small() throws {
        let store = ReversibleContentStore(db: try makeDB())
        let original = "the exact original tool output\nline 2\n{\"k\":1}"
        let handle = try store.store(original)
        XCTAssertEqual(try store.retrieveText(handle), original)
    }

    func test_storeThenRetrieveByteIdentical_over24kAnd260KB() throws {
        let store = ReversibleContentStore(db: try makeDB())

        let big = String(repeating: "abcdefghij\n", count: 3_000) // ~33k chars > 24k truncation point
        XCTAssertGreaterThan(big.count, 24_000)
        let h1 = try store.store(big)
        XCTAssertEqual(try store.retrieveText(h1), big, "the >24k original is recovered byte-for-byte")

        var blob = Data()
        for i in 0..<270_000 { blob.append(UInt8(i & 0xFF)) } // > 260KB binary
        XCTAssertGreaterThan(blob.count, 260 * 1024)
        let h2 = try store.store(blob)
        XCTAssertEqual(try store.retrieve(h2), blob, "the >260KB original is recovered byte-for-byte")
    }

    func test_contentAddressedDedup() throws {
        let store = ReversibleContentStore(db: try makeDB())
        let payload = "identical block repeated across turns"
        let h1 = try store.store(payload)
        let h2 = try store.store(payload)
        XCTAssertEqual(h1, h2, "same bytes => same handle (content-addressed)")
        XCTAssertEqual(try store.count(), 1, "storing identical bytes twice keeps one row")
    }

    func test_handleIsDeterministicSha256Hex() {
        let h = ReversibleContentStore.handle(for: "hello")
        // SHA-256("hello") well-known vector.
        XCTAssertEqual(h, "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }

    /// WHY: String and Data entry points must stay byte-identical after the
    /// contiguous-UTF-8 + nibble-table path; CAS / [[rc:handle]] recovery keys
    /// on a stable content-addressed digest across both call sites.
    func test_handle_stringAndDataPathsMatchCryptoKit() {
        let samples = ["", "hello", "plan-notes-v1-✅-", String(repeating: "N", count: 8192)]
        for sample in samples {
            let data = Data(sample.utf8)
            let expected = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
            XCTAssertEqual(ReversibleContentStore.handle(for: sample), expected,
                           "String handle must match CryptoKit for \(sample.prefix(20))…")
            XCTAssertEqual(ReversibleContentStore.handle(for: data), expected,
                           "Data handle must match CryptoKit for \(sample.prefix(20))…")
            XCTAssertEqual(
                ReversibleContentStore.handle(for: sample),
                ReversibleContentStore.handle(for: data)
            )
        }
    }

    func test_retrieveUnknownHandleReturnsNil() throws {
        let store = ReversibleContentStore(db: try makeDB())
        XCTAssertNil(try store.retrieve("deadbeef"), "missing handle => typed nil, never empty/hang")
        XCTAssertNil(try store.retrieve(""))
    }

    func test_retrieveAcceptsEmbeddedMarker() throws {
        let store = ReversibleContentStore(db: try makeDB())
        let original = "recoverable via marker"
        let handle = try store.store(original)
        let marker = ReversibleContentStore.marker(for: handle) // "[[rc:<handle>]]"
        XCTAssertEqual(try store.retrieveText(marker), original)
    }

    func test_pruneUnreferencedRespectsProtectedHandlesAndAge() throws {
        let store = ReversibleContentStore(db: try makeDB())
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let stale = try store.store("stale unreferenced", at: t0)
        let pinned = try store.store("stale but referenced", at: t0)

        let cutoff = Int64(t0.addingTimeInterval(60).timeIntervalSince1970 * 1000)
        // plan-final W3: protection is by durable handle set, not ref_count.
        let removed = try store.pruneUnreferenced(
            olderThanMs: cutoff,
            protectedHandles: [pinned]
        )
        XCTAssertEqual(removed, 1, "only the unprotected stale block is pruned")
        XCTAssertNil(try store.retrieve(stale))
        XCTAssertNotNil(try store.retrieve(pinned), "protected handle survives")
    }

    func test_migrationIsIdempotentAndAdditive() throws {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        // Pre-existing token_saver_savings (v25) row survives a re-migrate.
        try db.execute("""
            INSERT INTO token_saver_savings (provider, mode, input_tokens, output_tokens, saved_tokens, created_at, created_at_ms)
            VALUES ('claude','longText',100,10,90,'2026-06-08T00:00:00Z',1000);
        """)
        try Schema.migrate(db) // re-run: must be a no-op, not throw
        let stmt = try db.prepare("SELECT COUNT(*) FROM token_saver_savings;")
        defer { stmt.reset() }
        _ = try stmt.step()
        XCTAssertEqual(Int(stmt.columnInt64(0)), 1, "existing rows preserved across additive migration")
    }
}
