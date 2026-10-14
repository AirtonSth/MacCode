import XCTest
import CoreModel
@testable import Persistence

/// Timing benches over a read-only copy of a real database. Skipped unless
/// `RC_PERF_DB_COPY` names one, so CI never depends on private data. Each bench
/// warms once, then prints the median of `RC_PERF_SAMPLES` (default 7) runs.
final class LiveDataPerfBenchTests: XCTestCase {
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

    func test_bench_scheduledTaskActivePoll() throws {
        let store = ScheduledTaskStore(db: try openCopy())
        // One tick of the Scheduled Tasks poll while a run is active.
        try bench("scheduled.activePollTick") {
            _ = try store.listActiveRuns()
            _ = try store.listRuns(taskID: nil, limit: 200)
            _ = try store.listActiveRuns()
        }
    }
}
