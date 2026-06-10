import XCTest
@testable import AppShell

/// Tests for ModelChecksumPolicy.needsRehash -- the pure cache-decision helper
/// that determines whether a SHA-256 re-hash is required for a model file.
///
/// WHY these tests matter (Rule 8):
/// - The entire point of the cache is to avoid the O(file-size) SHA-256 loop
///   on the main thread. A bug that always returns `false` would silently skip
///   re-validation after a file change, allowing a corrupted model to run.
/// - A bug that always returns `true` defeats the cache and re-introduces the
///   main-thread beachball the feature was built to eliminate.
/// - Each test encodes a distinct business rule: "same attrs -> trust cache",
///   "size changed -> rehash", "mtime changed -> rehash", "no entry -> rehash".
final class ModelChecksumCacheTests: XCTestCase {

    // MARK: - Shared fixtures

    private let referenceDate = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private let referenceSize: Int64 = 1_234_567_890
    private let referenceSHA = "abc123def456"

    private var matchingEntry: ModelChecksumCacheEntry {
        ModelChecksumCacheEntry(
            sizeBytes: referenceSize,
            mtime: referenceDate,
            sha256Hex: referenceSHA
        )
    }

    // MARK: - Cache hit: same size AND same mtime -> no rehash needed

    func test_needsRehash_returnsFalse_whenSizeAndMtimeMatchCachedEntry() {
        // WHY: when neither size nor mtime has changed, the file is assumed
        // identical; re-hashing wastes CPU/time and blocks the main thread.
        let result = ModelChecksumPolicy.needsRehash(
            size: referenceSize,
            mtime: referenceDate,
            cached: matchingEntry
        )
        XCTAssertFalse(result,
            "Unchanged size and mtime must return false so the cache is used and SHA-256 is skipped")
    }

    // MARK: - Cache miss: size changed -> must rehash

    func test_needsRehash_returnsTrue_whenSizeDiffers() {
        // WHY: a different file size means the content changed; accepting the
        // stale checksum would let a corrupted or partially-downloaded model
        // pass validation.
        let result = ModelChecksumPolicy.needsRehash(
            size: referenceSize + 1,
            mtime: referenceDate,
            cached: matchingEntry
        )
        XCTAssertTrue(result,
            "Changed size must invalidate the cache and trigger a full SHA-256 re-hash")
    }

    func test_needsRehash_returnsTrue_whenSizeIsSmaller() {
        // WHY: a shrunk file is equally suspect -- covers truncated writes.
        let result = ModelChecksumPolicy.needsRehash(
            size: referenceSize - 1,
            mtime: referenceDate,
            cached: matchingEntry
        )
        XCTAssertTrue(result,
            "Smaller file size must also invalidate the cache")
    }

    // MARK: - Cache miss: mtime changed -> must rehash

    func test_needsRehash_returnsTrue_whenMtimeDiffers() {
        // WHY: mtime is the second guard; even if size is identical a different
        // mtime means the file was replaced (e.g., re-downloaded or patched).
        let laterDate = referenceDate.addingTimeInterval(1)
        let result = ModelChecksumPolicy.needsRehash(
            size: referenceSize,
            mtime: laterDate,
            cached: matchingEntry
        )
        XCTAssertTrue(result,
            "Changed mtime must invalidate the cache and trigger a full SHA-256 re-hash")
    }

    func test_needsRehash_returnsTrue_whenMtimeIsEarlier() {
        // WHY: a rollback to an earlier mtime is also suspicious (e.g., file
        // restore); the cache must not be trusted in either direction.
        let earlierDate = referenceDate.addingTimeInterval(-1)
        let result = ModelChecksumPolicy.needsRehash(
            size: referenceSize,
            mtime: earlierDate,
            cached: matchingEntry
        )
        XCTAssertTrue(result,
            "Earlier mtime must also invalidate the cache")
    }

    // MARK: - Cache miss: no entry -> must rehash

    func test_needsRehash_returnsTrue_whenNoCachedEntry() {
        // WHY: on first run (or after cache eviction) there is no baseline to
        // compare against; a full hash is mandatory to establish ground truth.
        let result = ModelChecksumPolicy.needsRehash(
            size: referenceSize,
            mtime: referenceDate,
            cached: nil
        )
        XCTAssertTrue(result,
            "Absent cache entry must force a full SHA-256 hash to establish a baseline")
    }

    // MARK: - ModelChecksumCache store/retrieve round-trip

    func test_cache_storesAndRetrievesEntryByURL() {
        // WHY: the cache must correctly associate entries with their URLs so that
        // a hit for /Models/weights.bin does not incorrectly satisfy a lookup
        // for /Models/config.json.
        let cache = ModelChecksumCache()
        let url = URL(fileURLWithPath: "/tmp/test-model/weights.bin")
        XCTAssertNil(cache.entry(for: url),
            "Cache must be empty before any entry is stored")

        cache.store(matchingEntry, for: url)
        let retrieved = cache.entry(for: url)
        XCTAssertEqual(retrieved, matchingEntry,
            "Retrieved entry must equal the stored entry for the same URL")
    }

    func test_cache_returnsNilForUnknownURL() {
        // WHY: a lookup for a URL that was never stored must return nil, which
        // causes needsRehash to return true and force a hash -- no false hits.
        let cache = ModelChecksumCache()
        cache.store(matchingEntry, for: URL(fileURLWithPath: "/tmp/a.bin"))
        let result = cache.entry(for: URL(fileURLWithPath: "/tmp/b.bin"))
        XCTAssertNil(result,
            "Cache must not return an entry for a URL that was never stored")
    }

    func test_cache_updatesExistingEntry() {
        // WHY: after a re-hash the cache must accept the new entry so subsequent
        // lookups reflect the file's current checksum, not a stale one.
        let cache = ModelChecksumCache()
        let url = URL(fileURLWithPath: "/tmp/weights.bin")
        cache.store(matchingEntry, for: url)

        let updatedEntry = ModelChecksumCacheEntry(
            sizeBytes: referenceSize + 100,
            mtime: referenceDate.addingTimeInterval(60),
            sha256Hex: "updated-sha"
        )
        cache.store(updatedEntry, for: url)

        XCTAssertEqual(cache.entry(for: url), updatedEntry,
            "Storing a new entry for the same URL must overwrite the old one")
    }
}
