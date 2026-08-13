import XCTest
@testable import AgentRuntime

// PERF-MAC_AGENT-008 / R7: verifies eviction + fingerprint policy for the
// lastPersistedAssistantContent dedup cache. WHY: without thread-close eviction,
// every thread that ever ran retains a map entry indefinitely. R7 stores a
// fixed-size AssistantContentFingerprint (utf8 count + digest) instead of the
// full final-answer String, so per-entry memory is bounded without size-cap
// refusal of large responses.
final class LastPersistedAssistantContentEvictionTests: XCTestCase {

    // A closed thread must always be evicted regardless of entry size. WHY: the
    // cache is a dedup optimisation for the ACTIVE run on a thread. Once the
    // thread is done the entry is dead weight and must be freed.
    func test_closedThread_evicts() {
        let evict = AgentRunCoordinator.shouldEvictLastPersistedContent(
            threadClosed: true,
            entryByteCount: 0,
            sizeCapBytes: 32_768
        )
        XCTAssertTrue(evict, "a closed thread must evict its cache entry to release dead final-answer memory")
    }

    // A closed thread with a large entry must still evict. WHY: confirms thread-
    // close takes precedence and is not short-circuited by the size branch.
    func test_closedThread_largeEntry_evicts() {
        let evict = AgentRunCoordinator.shouldEvictLastPersistedContent(
            threadClosed: true,
            entryByteCount: 1_000_000,
            sizeCapBytes: 32_768
        )
        XCTAssertTrue(evict, "thread-close eviction must not be gated on entry size")
    }

    // An active thread keeps its fingerprint entry even for large source text.
    // WHY: fingerprints are fixed-size; refusing large finals would re-introduce
    // full-history scans on the common turnCompleted+finished duplicate path.
    func test_activeThread_smallEntry_keeps() {
        let evict = AgentRunCoordinator.shouldEvictLastPersistedContent(
            threadClosed: false,
            entryByteCount: 100,
            sizeCapBytes: 32_768
        )
        XCTAssertFalse(evict, "an active thread must keep the fingerprint so dedup works without a full-history scan")
    }

    func test_activeThread_entryExactlyAtHistoricalCap_keeps() {
        let cap = 32_768
        let evict = AgentRunCoordinator.shouldEvictLastPersistedContent(
            threadClosed: false,
            entryByteCount: cap,
            sizeCapBytes: cap
        )
        XCTAssertFalse(evict, "fingerprint cache keeps entries at the historical String cap")
    }

    // R7: oversized source text still keeps the fingerprint. WHY: fixed-size
    // fingerprints remove the need to refuse large finals for memory bounding.
    func test_activeThread_oversizedSourceText_keepsFingerprint() {
        let cap = 32_768
        let evict = AgentRunCoordinator.shouldEvictLastPersistedContent(
            threadClosed: false,
            entryByteCount: cap + 1,
            sizeCapBytes: cap
        )
        XCTAssertFalse(evict, "large finals still fingerprint-cache; size alone must not evict")
    }

    func test_fingerprint_sameContent_equal() {
        let a = AssistantContentFingerprint.of("hello final answer")
        let b = AssistantContentFingerprint.of("hello final answer")
        XCTAssertEqual(a, b, "identical UTF-8 content must fingerprint equal for dedup")
        XCTAssertEqual(a.utf8Count, "hello final answer".utf8.count)
    }

    func test_fingerprint_differentContent_notEqual() {
        let a = AssistantContentFingerprint.of("answer A")
        let b = AssistantContentFingerprint.of("answer B")
        XCTAssertNotEqual(a, b, "distinct finals must not share a fingerprint")
    }

    func test_fingerprint_storedSize_isFixedAndTiny() {
        // Historical per-entry ceiling retained full UTF-8 up to 32 KiB.
        let priorStringCap = AgentRunCoordinator.lastPersistedAssistantContentSizeCap
        let fingerprintBytes = AssistantContentFingerprint.storedByteSize
        XCTAssertEqual(fingerprintBytes, 16, "two 64-bit words on this platform")
        let reduction = Double(priorStringCap - fingerprintBytes) / Double(priorStringCap)
        XCTAssertGreaterThan(reduction, 0.99, "fingerprint must cut per-entry retained bytes by >99% vs 32 KiB String")
    }

    // The built-in historical cap constant stays in a reasonable range so
    // evidence/docs that cite 32 KiB remain meaningful.
    func test_builtInSizeCap_isReasonable() {
        let cap = AgentRunCoordinator.lastPersistedAssistantContentSizeCap
        XCTAssertGreaterThan(cap, 4_096, "historical cap too small to be a meaningful baseline")
        XCTAssertLessThan(cap, 1_048_576, "historical cap too large for evidence baselines")
    }
}
