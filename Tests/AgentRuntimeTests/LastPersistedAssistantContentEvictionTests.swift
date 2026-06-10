import XCTest
@testable import AgentRuntime

// PERF-MAC_AGENT-008: verifies the eviction policy for the
// lastPersistedAssistantContent dedup cache. WHY: without eviction, every thread
// that ever ran in a session retains its full final-answer string indefinitely.
// Multi-thread sessions can accumulate MBs of dead final-answer text that is
// never freed until the process exits. These tests pin the pure eviction decision
// (shouldEvictLastPersistedContent) that guards all three eviction sites:
// thread-close (finished/cancelled) and oversized-entry (store path).
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

    // An active thread with a small entry must NOT be evicted. WHY: this is the
    // hot path (normal dedup of turnCompleted+finished on the same turn). Evicting
    // here would defeat the dedup and re-introduce the full-history scan on every
    // duplicate event.
    func test_activeThread_smallEntry_keeps() {
        let evict = AgentRunCoordinator.shouldEvictLastPersistedContent(
            threadClosed: false,
            entryByteCount: 100,
            sizeCapBytes: 32_768
        )
        XCTAssertFalse(evict, "an active thread with a small entry must keep the cache so dedup works without a full-history scan")
    }

    // An active thread with an entry exactly at the cap must NOT be evicted. WHY:
    // the boundary is inclusive on the keep side; an off-by-one here would drop
    // cache entries for legitimate same-size responses.
    func test_activeThread_entryExactlyAtCap_keeps() {
        let cap = 32_768
        let evict = AgentRunCoordinator.shouldEvictLastPersistedContent(
            threadClosed: false,
            entryByteCount: cap,
            sizeCapBytes: cap
        )
        XCTAssertFalse(evict, "an entry at exactly the cap must be kept; evicting at-cap would break dedup for normal-length responses")
    }

    // An active thread with an oversized entry must be evicted. WHY: caching very
    // long responses (e.g. 200 KB final answer) wastes memory. Skipping the cache
    // forces a full-history scan on the next duplicate event, which is correct and
    // acceptable because large responses are rare.
    func test_activeThread_oversizedEntry_evicts() {
        let cap = 32_768
        let evict = AgentRunCoordinator.shouldEvictLastPersistedContent(
            threadClosed: false,
            entryByteCount: cap + 1,
            sizeCapBytes: cap
        )
        XCTAssertTrue(evict, "an entry exceeding the cap must be evicted to bound per-entry memory for very long responses")
    }

    // Two different entries one byte apart straddle the cap boundary correctly.
    // WHY: off-by-one errors at the cap are a common source of silent regressions
    // where the cache is either always bypassed (too eager) or retains oversized
    // entries (too lenient).
    func test_capBoundary_keepsBelowEvictsAbove() {
        let cap = 1_024
        let keepDecision = AgentRunCoordinator.shouldEvictLastPersistedContent(
            threadClosed: false,
            entryByteCount: cap,
            sizeCapBytes: cap
        )
        let evictDecision = AgentRunCoordinator.shouldEvictLastPersistedContent(
            threadClosed: false,
            entryByteCount: cap + 1,
            sizeCapBytes: cap
        )
        XCTAssertFalse(keepDecision, "entry at cap must be kept (boundary is inclusive)")
        XCTAssertTrue(evictDecision,  "entry one byte over cap must be evicted")
    }

    // The built-in cap constant is within a reasonable range so accidental
    // changes (e.g. a zero or a negative value from a typo) are caught. WHY: a
    // zero cap would evict every entry and break dedup; a multi-MB cap would
    // defeat the whole point of the guard.
    func test_builtInSizeCap_isReasonable() {
        let cap = AgentRunCoordinator.lastPersistedAssistantContentSizeCap
        XCTAssertGreaterThan(cap, 4_096,    "cap too small: would evict normal-length responses and break dedup")
        XCTAssertLessThan(cap, 1_048_576,   "cap too large: would retain MBs of final-answer text per thread")
    }
}
