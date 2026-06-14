import XCTest
@testable import DistillCore

/// Wave 4 — adversarial safety corpus proving existing invariants.
/// I9.7: deduper golden corpus — ZERO false merges across PASS/FAIL flips, count
/// changes, negations, version bumps, SHA/hex/line-drift. I4.2: cache never stores
/// handle-bearing output (so a stale handle can never be served from a hit).
final class Wave4SafetyCorpusTests: XCTestCase {

    /// Each pair is two blocks that LOOK similar but differ in a load-bearing way.
    /// The deterministic diff must REFUSE to collapse every one (nearDedupedBlocks == 0).
    func test_dedupeGoldenCorpusZeroFalseMerges() {
        let stem = (1...6).map { "worker \($0) drained the queue and committed the batch to disk" }
            .joined(separator: "\n")
        let adversarialPairs: [(String, String, String)] = [
            ("PASS/FAIL flip",      "RESULT: all tests PASSED\n" + stem,    "RESULT: some tests FAILED\n" + stem),
            ("count change",        stem + "\nprocessed 412 records",        stem + "\nprocessed 987 records"),
            ("negation",            "the cache is enabled\n" + stem,         "the cache is not enabled\n" + stem),
            ("version bump",        "running v1.2.3 build\n" + stem,         "running v1.2.4 build\n" + stem),
            ("git SHA",             "HEAD 5c38ec7c405ec4b44b94cc5a9bb96e735b38267a\n" + stem,
                                    "HEAD 3edf6d7de0faa426b09780416fe61009f26ae589\n" + stem),
            ("line-number drift",   "at src/app.swift:120\n" + stem,         "at src/app.swift:121\n" + stem),
            ("error-code change",   "exited with code 1\n" + stem,           "exited with code 2\n" + stem),
            ("only/never word",     "only admins may write\n" + stem,        "all users may write\n" + stem),
        ]
        for (name, a, b) in adversarialPairs {
            let text = a + "\n\n" + b
            let result = DistillBlockDeduper.dedupe(text, minBlockChars: 80)
            XCTAssertEqual(result.nearDedupedBlocks, 0, "FALSE MERGE on '\(name)' — load-bearing difference collapsed")
            XCTAssertEqual(result.output, text, "'\(name)' must pass through unchanged")
        }
    }

    /// Positive control: a genuinely safe volatile-only difference DOES collapse, so
    /// the corpus above is meaningful (the deduper isn't just refusing everything).
    func test_dedupeStillCollapsesVolatileOnlyDifference() {
        let body = (1...6).map { "worker \($0) drained the queue and committed the batch" }.joined(separator: "\n")
        let text = "ts 2026-06-14T01:00:00Z\n" + body + "\n\nts 2026-06-14T09:30:00Z\n" + body
        let result = DistillBlockDeduper.dedupe(text, minBlockChars: 80)
        XCTAssertEqual(result.nearDedupedBlocks, 1, "a timestamp-only diff is safe to collapse")
    }

    /// I4.2: an output that references a reversible handle must never be cached, so a
    /// later hit can never serve a placeholder whose backing store may have changed.
    func test_resultCacheNeverStoresHandleBearingOutput() async throws {
        let runtime = StubHandleRuntime()
        let scheduler = DistillScheduler(runtime: runtime, resultCacheTTLSeconds: 1_800, resultCacheCapacity: 16)
        let request = DistillRequest(mode: .commandOutput, input: String(repeating: "some long tool output line\n", count: 40))

        _ = try await scheduler.submit(request)
        let countAfterFirst = await scheduler.resultCacheCount
        XCTAssertEqual(countAfterFirst, 0, "handle-bearing output must not be cached (I4.2)")

        // Second identical submit is a fresh miss (no poisoned hit), runtime called again.
        _ = try await scheduler.submit(request)
        let calls = await runtime.callCount
        XCTAssertEqual(calls, 2, "no cache hit on handle-bearing output")
    }

    /// Control: a handle-FREE output IS cached and served on the second hit.
    func test_resultCacheStoresAndServesHandleFreeOutput() async throws {
        let runtime = StubPlainRuntime()
        let scheduler = DistillScheduler(runtime: runtime, resultCacheTTLSeconds: 1_800, resultCacheCapacity: 16)
        let request = DistillRequest(mode: .commandOutput, input: String(repeating: "compressible line\n", count: 40))
        _ = try await scheduler.submit(request)
        _ = try await scheduler.submit(request)
        let calls = await runtime.callCount
        let hits = await scheduler.resultCacheHitCount
        XCTAssertEqual(calls, 1, "second identical request served from cache")
        XCTAssertEqual(hits, 1)
    }
}

private actor StubHandleRuntime: DistillRuntime {
    private(set) var callCount = 0
    func distill(_ request: DistillRequest) async throws -> String {
        callCount += 1
        return "summary of output [[rc:deadbeef01]]"
    }
}

private actor StubPlainRuntime: DistillRuntime {
    private(set) var callCount = 0
    func distill(_ request: DistillRequest) async throws -> String {
        callCount += 1
        return "compressed summary"
    }
}
