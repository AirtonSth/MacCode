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

    /// Launch/24 h storage retention against a fresh APFS clone of the copy per
    /// sample (cleanup deletes, so the read-only copy is never opened writable).
    /// A probe thread keeps taking the connection gate the way a main-thread
    /// `SettingsRepository.get` does; its longest wait is the longest single
    /// lock hold the pass imposes on everyone else.
    func test_bench_launchStorageRetention() throws {
        try benchStorageRetention(name: "storage.retention", seedOrphan: false)
    }

    /// Same pass when it actually deletes an original: one expired,
    /// unreferenced `rc_reversible_content` row is seeded into each clone, so
    /// the delete transaction runs (the real copy alone never reaches it).
    func test_bench_launchStorageRetentionDeletingAnOrphan() throws {
        try benchStorageRetention(name: "storage.retention.orphan", seedOrphan: true)
    }

    private func benchStorageRetention(name: String, seedOrphan: Bool) throws {
        guard let source = ProcessInfo.processInfo.environment["RC_PERF_DB_COPY"], !source.isEmpty,
              let workDir = ProcessInfo.processInfo.environment["RC_PERF_WORK_DIR"], !workDir.isEmpty else {
            throw XCTSkip("RC_PERF_DB_COPY / RC_PERF_WORK_DIR are not set")
        }
        let count = Int(ProcessInfo.processInfo.environment["RC_PERF_SAMPLES"] ?? "") ?? 7
        var totals: [Double] = []
        var holds: [Double] = []
        var writeHolds: [Double] = []
        for sample in 0...count {
            let clone = (workDir as NSString).appendingPathComponent("retention-clone.sqlite")
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: clone + suffix) }
            // FileManager.copyItem clones on APFS (copy-on-write, no 1.5 GB write).
            try FileManager.default.copyItem(atPath: source, toPath: clone)
            let db = try SQLiteDB(path: clone)
            if seedOrphan {
                _ = try ReversibleContentStore(db: db).store("perf bench orphan \(sample)", at: Date(timeIntervalSince1970: 1))
            }
            // Longest BEGIN IMMEDIATE…COMMIT span: the writer-lock part of the
            // probe's wait, free of scheduling noise on a loaded host.
            let maxWriteTransaction = LockedMax()
            var transactionStart: UInt64?
            db.beforeExecuteForTesting = { sql in
                let now = DispatchTime.now().uptimeNanoseconds
                if sql.hasPrefix("BEGIN IMMEDIATE") {
                    transactionStart = now
                } else if sql.hasPrefix("COMMIT") || sql.hasPrefix("ROLLBACK"), let begin = transactionStart {
                    maxWriteTransaction.record(Double(now - begin) / 1_000_000)
                    transactionStart = nil
                }
            }
            let stop = DispatchSemaphore(value: 0)
            let probeDone = DispatchSemaphore(value: 0)
            let maxWait = LockedMax()
            // The probe runs at main-thread QoS, as the readers it stands in for do.
            let probe = Thread {
                while stop.wait(timeout: .now()) == .timedOut {
                    let start = DispatchTime.now().uptimeNanoseconds
                    _ = try? db.performSync { database in try database.prepare("SELECT 1;").step() }
                    maxWait.record(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
                    usleep(200)
                }
                probeDone.signal()
            }
            probe.qualityOfService = .userInteractive
            probe.start()
            // Off main, like production (backgroundWriterQueue).
            let start = DispatchTime.now().uptimeNanoseconds
            var outcome: Result<LocalStorageCleanupResult, Error>!
            let cleanupDone = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .utility).async {
                outcome = Result { try LocalStorageBudgetManager(db: db).cleanupExpired(compact: false) }
                cleanupDone.signal()
            }
            cleanupDone.wait()
            let total = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            let result = try outcome.get()
            stop.signal()
            probeDone.wait()
            db.beforeExecuteForTesting = nil
            let removed = LocalStorageClass.allCases.map { "\($0.rawValue)=\(result.removedRows[$0] ?? 0)" }
            print("PERF_SAMPLE name=\(name) sample=\(sample) total_ms=\(String(format: "%.2f", total)) max_lock_wait_ms=\(String(format: "%.2f", maxWait.value)) max_write_txn_ms=\(String(format: "%.2f", maxWriteTransaction.value)) removed=[\(removed.joined(separator: ","))]")
            // Sample 0 is a warm-up and is not counted.
            if sample > 0 {
                totals.append(total)
                holds.append(maxWait.value)
                writeHolds.append(maxWriteTransaction.value)
            }
        }
        func median(_ values: [Double]) -> String { String(format: "%.2f", values.sorted()[values.count / 2]) }
        print("PERF_BENCH name=\(name).total median_ms=\(median(totals)) samples_ms=[\(totals.map { String(format: "%.2f", $0) }.joined(separator: ","))]")
        print("PERF_BENCH name=\(name).max_lock_wait median_ms=\(median(holds)) samples_ms=[\(holds.map { String(format: "%.2f", $0) }.joined(separator: ","))]")
        print("PERF_BENCH name=\(name).max_write_txn median_ms=\(median(writeHolds)) samples_ms=[\(writeHolds.map { String(format: "%.2f", $0) }.joined(separator: ","))]")
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

private final class LockedMax: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0.0
    var value: Double { lock.lock(); defer { lock.unlock() }; return current }
    func record(_ sample: Double) { lock.lock(); current = max(current, sample); lock.unlock() }
}
