import XCTest
@testable import Persistence
import CoreModel

/// QA-mac:72(b) -- multi-threaded persistence access.
///
/// WHY: the SQLite repos are called from the main thread, socket threads, and the
/// coordinator queue (T007), but every other persistence test is single-threaded.
/// SQLiteDB opens with SQLITE_OPEN_FULLMUTEX so one connection is safe to share
/// across threads; this hammers a SHARED connection concurrently to prove that
/// holds -- a Swift-level read-modify-write clobber or an unserialized handle touch
/// would surface here as a lost write or a failure, and trips ThreadSanitizer in
/// the dedicated CI lane (tsan-persistence-macos.yml).
final class PersistenceConcurrencyStressTests: XCTestCase {

    private func makeRepo() throws -> (NotificationRepository, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RC2PersistStress-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try SQLiteDB(path: dir.appendingPathComponent("stress.sqlite").path)
        try Schema.migrate(db)
        return (NotificationRepository(db: db), dir)
    }

    func test_concurrentInserts_allLandExactlyOnce_noClobber() throws {
        let (repo, dir) = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }

        let iterations = 500
        let lock = NSLock()
        var failures = 0

        DispatchQueue.concurrentPerform(iterations: iterations) { i in
            let n = AppNotification(id: "n-\(i)", title: "t\(i)", body: "b", category: "stress")
            do { try repo.insert(n) }
            catch { lock.lock(); failures += 1; lock.unlock() }
        }

        XCTAssertEqual(failures, 0,
            "no insert may fail under concurrent access -- FULLMUTEX must serialize the shared connection")
        let all = try repo.list(limit: iterations + 10)
        XCTAssertEqual(all.count, iterations,
            "every concurrent insert must persist exactly once; a lost row means a read-modify-write clobber slipped through the shared connection")
    }

    func test_concurrentReadsAndWrites_doNotCrashOrFail() throws {
        let (repo, dir) = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Seed so reads always have rows to scan while writes interleave.
        for i in 0..<50 { try repo.insert(AppNotification(id: "seed-\(i)", title: "s", category: "stress")) }

        let iterations = 400
        let lock = NSLock()
        var failures = 0

        // Even indices write, odd indices read -- read-while-write is the exact
        // T007 mixed-queue scenario (socket thread reading while main thread writes).
        DispatchQueue.concurrentPerform(iterations: iterations) { i in
            do {
                if i % 2 == 0 {
                    try repo.insert(AppNotification(id: "w-\(i)", title: "w", category: "stress"))
                } else {
                    _ = try repo.list(limit: 100)
                }
            } catch { lock.lock(); failures += 1; lock.unlock() }
        }

        XCTAssertEqual(failures, 0,
            "interleaved concurrent reads and writes on one FULLMUTEX connection must never fail or corrupt the handle")
        let all = try repo.list(limit: iterations + 100)
        XCTAssertEqual(all.count, 50 + iterations / 2,
            "the 50 seeds plus every even-index write must all be present after the read/write storm")
    }

    func test_providerDiagnosticsCache_isSafeAcrossConcurrentThreads() throws {
        // WHY: provider callbacks from simultaneous agent runs reach one
        // ProviderSessionRuntimeRepository on arbitrary executors. The
        // diagnostic cache must not race while different threads read/write it.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RC2DiagnosticsStress-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try SQLiteDB(path: dir.appendingPathComponent("diagnostics.sqlite").path)
        try Schema.migrate(db)
        let threadRepo = AgentThreadRepository(db: db)
        let repo = ProviderSessionRuntimeRepository(db: db)
        let threads = (0..<16).map { index in
            AgentThread(title: "diagnostics-\(index)", provider: .codex, model: "m")
        }
        for thread in threads {
            try threadRepo.upsert(thread)
            try repo.upsert(ProviderSessionRuntime(
                threadId: thread.id,
                provider: .codex,
                status: .running,
                lastEventKind: "itemDelta(0)"
            ))
        }

        let lock = NSLock()
        var failures = 0
        DispatchQueue.concurrentPerform(iterations: 512) { index in
            let thread = threads[index % threads.count]
            do {
                try repo.updateDiagnostics(
                    threadId: thread.id,
                    lastEventKind: "itemDelta(\(index % 4))",
                    lastErrorMessage: nil
                )
            } catch {
                lock.lock()
                failures += 1
                lock.unlock()
            }
        }

        XCTAssertEqual(failures, 0,
            "concurrent provider diagnostics must not race or fail")
        for thread in threads {
            XCTAssertNotNil(try repo.get(threadId: thread.id))
        }
    }
}
