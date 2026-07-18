import XCTest
@testable import Persistence

final class TerminalHistoryDeleteCleanupTests: XCTestCase {
    func test_unconditionalDeleteClearsFileBackedFailureAnchorsAfterSQLiteCommit() throws {
        // WHY: ownerless SSH/router fallbacks have no runtime coordinator left
        // to clear C80 metadata. The repository's unconditional delete is the
        // last authoritative boundary and must remove both SQLite state and
        // every sidecar anchor for the surface.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
            "RC2TerminalDeleteCleanup-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try SQLiteDB(
            path: directory.appendingPathComponent("remote-code.sqlite").path
        )
        try Schema.migrate(database)
        let repository = TerminalOutputRepository(db: database)
        let surfaceID = UUID().uuidString
        let writerGeneration = UUID().uuidString
        try repository.append(
            surfaceID: surfaceID,
            workspaceID: nil,
            chunkIndex: 1,
            data: Data("OWNERLESS_DELETE\n".utf8)
        )
        try repository.recordFailureAnchor(
            surfaceID: surfaceID,
            writerGeneration: writerGeneration,
            reason: "ownerless_delete_fixture",
            minimumNextChunkIndex: 2
        )
        XCTAssertGreaterThan(try repository.totalBytes(surfaceID: surfaceID), 0)
        XCTAssertEqual(try repository.failureAnchors(surfaceID: surfaceID).count, 1)

        try repository.delete(surfaceID: surfaceID)

        XCTAssertEqual(try repository.totalBytes(surfaceID: surfaceID), 0)
        XCTAssertTrue(
            try repository.failureAnchors(surfaceID: surfaceID).isEmpty,
            "a confirmed SQLite delete must not leave a stale C80 anchor behind"
        )
    }

    func test_twoRepositoriesSharingLedgerRootCoalesceTheSamePendingDelete() throws {
        // WHY: POSIX record locks are process-scoped. Two repository instances
        // in one app process must also share an in-process root lock or both can
        // scan an empty ledger and commit duplicate tombstones.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
            "RC2TerminalLedgerProcessLock-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databasePath = directory.appendingPathComponent("remote-code.sqlite").path
        let firstDatabase = try SQLiteDB(path: databasePath)
        try Schema.migrate(firstDatabase)
        let secondDatabase = try SQLiteDB(path: databasePath)
        let ledgerRoot = directory.appendingPathComponent("ledger", isDirectory: true)
        let firstReachedAtomicWrite = DispatchSemaphore(value: 0)
        let releaseFirstAtomicWrite = DispatchSemaphore(value: 0)
        let first = TerminalOutputRepository(
            db: firstDatabase,
            terminalHistoryFailureLedgerRootForTesting: ledgerRoot,
            descriptorOpenedForTesting: { kind, _ in
                guard kind == "temp" else { return }
                firstReachedAtomicWrite.signal()
                _ = releaseFirstAtomicWrite.wait(timeout: .now() + 3)
            }
        )
        let second = TerminalOutputRepository(
            db: secondDatabase,
            terminalHistoryFailureLedgerRootForTesting: ledgerRoot
        )
        let surfaceID = UUID().uuidString
        let generation = UUID().uuidString
        let firstDone = DispatchSemaphore(value: 0)
        let secondDone = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "rc2.test.pending-delete-process-lock", attributes: .concurrent)
        queue.async {
            _ = try? first.recordPendingDelete(
                surfaceID: surfaceID,
                expectedWriterGeneration: generation
            )
            firstDone.signal()
        }
        XCTAssertEqual(firstReachedAtomicWrite.wait(timeout: .now() + 2), .success)
        queue.async {
            _ = try? second.recordPendingDelete(
                surfaceID: surfaceID,
                expectedWriterGeneration: generation
            )
            secondDone.signal()
        }
        XCTAssertEqual(
            secondDone.wait(timeout: .now() + 0.25),
            .timedOut,
            "a same-root repository must wait while another atomic ledger update is in flight"
        )
        releaseFirstAtomicWrite.signal()
        XCTAssertEqual(firstDone.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(secondDone.wait(timeout: .now() + 3), .success)

        XCTAssertEqual(
            try first.pendingDeletes().count,
            1,
            "same-root repositories must coalesce one durable ownership record"
        )
    }
}
