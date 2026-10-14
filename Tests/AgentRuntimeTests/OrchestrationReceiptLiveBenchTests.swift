import XCTest
import CoreModel
@testable import Persistence
@testable import AgentRuntime

/// Timing benches for the Subagents receipt reads over a copy of a real
/// database. Skipped unless `RC_PERF_DB_COPY` names one, so CI never depends
/// on private data. Each bench warms once, then prints the median of
/// `RC_PERF_SAMPLES` (default 7) runs. Only timings and counts are printed.
final class OrchestrationReceiptLiveBenchTests: XCTestCase {
    private func openCopy() throws -> SQLiteDB {
        guard let path = ProcessInfo.processInfo.environment["RC_PERF_DB_COPY"], !path.isEmpty else {
            throw XCTSkip("RC_PERF_DB_COPY is not set")
        }
        return try SQLiteDB(path: path, readonly: true)
    }

    private func bench(_ name: String, _ body: () throws -> Void) rethrows {
        let count = Int(ProcessInfo.processInfo.environment["RC_PERF_SAMPLES"] ?? "") ?? 7
        try body()
        var samples: [Double] = []
        for _ in 0..<count {
            let start = DispatchTime.now().uptimeNanoseconds
            try body()
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        let median = samples.sorted()[samples.count / 2]
        let rendered = samples.map { String(format: "%.2f", $0) }.joined(separator: ",")
        print("PERF_BENCH name=\(name) median_ms=\(String(format: "%.2f", median)) samples_ms=[\(rendered)]")
    }

    private func runtime(_ db: SQLiteDB) -> AgentOrchestrationRuntime {
        AgentOrchestrationRuntime(
            repository: AgentOrchestrationRepository(db: db),
            packageVerification: { true },
            killSwitch: { false },
            processIsAlive: { _ in true }
        )
    }

    /// One Subagents badge poll tick for the newest receipt's thread, with the
    /// same limits `AgentAppViewModel.loadSubagentActivitySnapshotsOffMainActor`
    /// passes (128 thread rows, 16 child rows, read-only reconciliation).
    func test_bench_subagentBadgePoll() throws {
        let db = try openCopy()
        let steady = runtime(db)
        let newest = try XCTUnwrap(try steady.recentReceipts(limit: 1).first)
        let threadIds: Set<AgentThreadID> = [newest.threadId]
        func poll(_ runtime: AgentOrchestrationRuntime) throws -> Int {
            try runtime.activityReceipts(
                threadIds: threadIds,
                limit: 128,
                childRecordLimit: 16,
                persistLifecycleReconciliation: false
            ).count
        }
        // Steady state: the same runtime polls repeatedly with no receipt writes.
        try bench("subagents.badgePoll.steady") { _ = try poll(steady) }
        // Cold: a fresh repository per tick (empty caches), like a receipt append.
        try bench("subagents.badgePoll.cold") { _ = try poll(runtime(db)) }

        var stepped: [String] = []
        db.beforeStatementStepForTesting = { stepped.append($0) }
        defer { db.beforeStatementStepForTesting = nil }
        let count = try poll(steady)
        let unfiltered = stepped.filter {
            $0.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                == "SELECT detail FROM audit_log WHERE action IN (?, ?) ORDER BY id ASC;"
        }.count
        print("PERF_COUNT name=subagents.badgePoll.steady receipts=\(count) "
              + "steps=\(stepped.count) unfiltered_receipt_scan_steps=\(unfiltered)")
    }

    /// The receipt lookup `isNestedAgentWorker` runs at every run finish. The
    /// memo is keyed on the receipt-set signature, so at run end it misses.
    func test_bench_runFinishedNestedLookup() throws {
        let db = try openCopy()
        let newest = try XCTUnwrap(try runtime(db).recentReceipts(limit: 1).first)
        let runId = try XCTUnwrap(newest.runId)
        try bench("subagents.runFinished.receiptLookup.cold") {
            _ = try runtime(db).admissionReceipt(for: runId)
        }
    }
}
