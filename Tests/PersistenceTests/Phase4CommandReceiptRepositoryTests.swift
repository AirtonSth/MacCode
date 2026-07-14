import XCTest
@testable import Persistence
import CoreModel

final class Phase4CommandReceiptRepositoryTests: XCTestCase {
    func test_finalizePrunesOldEventsAndLinksWithoutPruningPermanentReceipts() throws {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        let repository = CommandReceiptRepository(db: db, eventRetentionCap: 3)

        XCTAssertEqual(try repository.claim(
            method: "workspace.close",
            clientRequestId: "permanent-unknown",
            ownerFingerprint: "owner-a",
            paramsHash: "hash-unknown"
        ), .claimed)
        try repository.markUnknown(
            method: "workspace.close",
            clientRequestId: "permanent-unknown",
            ownerFingerprint: "owner-a",
            paramsHash: "hash-unknown"
        )

        for index in 0..<7 {
            let requestID = "bounded-\(index)"
            XCTAssertEqual(try repository.claim(
                method: "workspace.rename",
                clientRequestId: requestID,
                ownerFingerprint: "owner-a",
                paramsHash: "hash-\(index)"
            ), .claimed)
            _ = try repository.finalize(
                method: "workspace.rename",
                clientRequestId: requestID,
                ownerFingerprint: "owner-a",
                paramsHash: "hash-\(index)",
                resultJSON: "\(index)",
                events: [CommandReceiptEventIntent(
                    kind: "workspace.renamed",
                    payloadJSON: "{\"index\":\(index)}",
                    createdAt: Date(timeIntervalSince1970: TimeInterval(index))
                )]
            )
        }

        XCTAssertEqual(try scalar(db, "SELECT COUNT(*) FROM events;"), 3,
                       "receipt finalization must apply the same retained-event cap as ordinary persistence")
        XCTAssertEqual(try scalar(db, "SELECT COUNT(*) FROM command_receipt_events;"), 3,
                       "links to pruned event payloads have no retry role and must be removed")
        XCTAssertEqual(try scalar(db, """
            SELECT COUNT(*) FROM command_receipt_events cre
            WHERE NOT EXISTS (SELECT 1 FROM events e WHERE e.seq = cre.seq);
            """), 0, "retention must never leave orphan receipt-event links")
        XCTAssertEqual(try scalar(db, "SELECT COUNT(*) FROM command_receipts;"), 8,
                       "storage retention must not weaken permanent at-most-once tombstones or committed outcomes")
        XCTAssertEqual(try repository.claim(
            method: "workspace.rename",
            clientRequestId: "bounded-0",
            ownerFingerprint: "owner-a",
            paramsHash: "hash-0"
        ), .committed(resultJSON: "0"))
        XCTAssertEqual(try repository.status(
            method: "workspace.close",
            clientRequestId: "permanent-unknown",
            ownerFingerprint: "owner-a"
        ), .unknown)

        let replayedLatest = try repository.finalize(
            method: "workspace.rename",
            clientRequestId: "bounded-6",
            ownerFingerprint: "owner-a",
            paramsHash: "hash-6",
            resultJSON: "6",
            events: []
        )
        XCTAssertEqual(replayedLatest.map(\.kind), ["workspace.renamed"],
                       "the newest link must remain available for ambiguous-commit reread and post-commit fanout")
    }

    func test_claimCommitAndPermanentTerminalStates() throws {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        let repository = CommandReceiptRepository(db: db)

        XCTAssertEqual(try repository.claim(
            method: "workspace.rename",
            clientRequestId: "committed",
            ownerFingerprint: "owner-a",
            paramsHash: "hash-a"
        ), .claimed)
        try repository.commit(
            method: "workspace.rename",
            clientRequestId: "committed",
            ownerFingerprint: "owner-a",
            paramsHash: "hash-a",
            resultJSON: "true"
        )
        XCTAssertEqual(try repository.claim(
            method: "workspace.rename",
            clientRequestId: "committed",
            ownerFingerprint: "owner-a",
            paramsHash: "hash-a"
        ), .committed(resultJSON: "true"))
        XCTAssertEqual(try repository.claim(
            method: "workspace.rename",
            clientRequestId: "committed",
            ownerFingerprint: "owner-b",
            paramsHash: "hash-a"
        ), .ownerMismatch)
        XCTAssertEqual(try repository.claim(
            method: "workspace.rename",
            clientRequestId: "committed",
            ownerFingerprint: "owner-a",
            paramsHash: "hash-b"
        ), .requestMismatch)
    }

    func test_bootstrapConvertsResidualClaimToPermanentUnknownBeforeAdmission() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("phase4-receipt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databasePath = directory.appendingPathComponent("phase4.sqlite").path

        try seedClaim(databasePath: databasePath)

        let (_, database) = try Bootstrap(
            channel: .debug,
            dbPathOverride: databasePath,
            appSupportOverride: directory.path
        ).run()
        let repository = CommandReceiptRepository(db: database)
        XCTAssertEqual(try repository.status(
            method: "workspace.close",
            clientRequestId: "interrupted",
            ownerFingerprint: "owner-a"
        ), .unknown)
        XCTAssertEqual(try repository.claim(
            method: "workspace.close",
            clientRequestId: "interrupted",
            ownerFingerprint: "owner-a",
            paramsHash: "hash-a"
        ), .unknown)
    }

    func test_fullDurabilityEnablesSynchronousFullAndFullFsync() throws {
        let db = try SQLiteDB(path: ":memory:")
        try db.enableFullDurability()

        let synchronous = try db.prepare("PRAGMA synchronous;")
        XCTAssertTrue(try synchronous.step())
        XCTAssertEqual(synchronous.columnInt64(0), 2)

        let fullFsync = try db.prepare("PRAGMA fullfsync;")
        XCTAssertTrue(try fullFsync.step())
        XCTAssertEqual(fullFsync.columnInt64(0), 1)
    }

    func test_finalizeAtomicallyPersistsOrderedEventsOutcomeAndReceiptRange() throws {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        let repository = CommandReceiptRepository(db: db)
        XCTAssertEqual(try repository.claim(
            method: "workspace.rename",
            clientRequestId: "atomic",
            ownerFingerprint: "owner-a",
            paramsHash: "hash-a"
        ), .claimed)
        let intents = [
            CommandReceiptEventIntent(
                kind: "workspace.renamed",
                payloadJSON: "{\"name\":\"one\"}",
                createdAt: Date(timeIntervalSince1970: 10)
            ),
            CommandReceiptEventIntent(
                kind: "workspace.reordered",
                payloadJSON: "{\"position\":1}",
                createdAt: Date(timeIntervalSince1970: 11)
            ),
        ]

        let persisted = try repository.finalize(
            method: "workspace.rename",
            clientRequestId: "atomic",
            ownerFingerprint: "owner-a",
            paramsHash: "hash-a",
            resultJSON: "true",
            events: intents
        )
        XCTAssertEqual(persisted.map(\.seq), [1, 2])
        XCTAssertEqual(persisted.map(\.ordinal), [0, 1])
        XCTAssertEqual(try repository.claim(
            method: "workspace.rename",
            clientRequestId: "atomic",
            ownerFingerprint: "owner-a",
            paramsHash: "hash-a"
        ), .committed(resultJSON: "true"))

        let replayedFinalization = try repository.finalize(
            method: "workspace.rename",
            clientRequestId: "atomic",
            ownerFingerprint: "owner-a",
            paramsHash: "hash-a",
            resultJSON: "true",
            events: intents
        )
        XCTAssertEqual(replayedFinalization.map(\.seq), [1, 2])
        XCTAssertEqual(try EventLogRepository(db: db).read(since: 0).map(\.seq), [1, 2])

        let range = try db.prepare("""
            SELECT event_start_seq, event_end_seq FROM command_receipts
            WHERE method = 'workspace.rename' AND client_request_id = 'atomic';
        """)
        XCTAssertTrue(try range.step())
        XCTAssertEqual(range.columnInt64(0), 1)
        XCTAssertEqual(range.columnInt64(1), 2)
    }

    func test_finalizeFailureRollsBackEventsSequenceOutcomeAndCanRetryWithoutEffect() throws {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        let repository = CommandReceiptRepository(db: db)
        XCTAssertEqual(try repository.claim(
            method: "workspace.set_pinned",
            clientRequestId: "fault",
            ownerFingerprint: "owner-a",
            paramsHash: "hash-a"
        ), .claimed)
        try db.execute("""
            CREATE TRIGGER fail_second_receipt_event
            BEFORE INSERT ON command_receipt_events
            WHEN NEW.ordinal = 1
            BEGIN
                SELECT RAISE(ABORT, 'phase4 injected finalization fault');
            END;
        """)
        let intents = [
            CommandReceiptEventIntent(kind: "workspace.updated", payloadJSON: "{}", createdAt: Date()),
            CommandReceiptEventIntent(kind: "workspace.reordered", payloadJSON: "{}", createdAt: Date()),
        ]

        XCTAssertThrowsError(try repository.finalize(
            method: "workspace.set_pinned",
            clientRequestId: "fault",
            ownerFingerprint: "owner-a",
            paramsHash: "hash-a",
            resultJSON: "true",
            events: intents
        ))
        XCTAssertEqual(try repository.status(
            method: "workspace.set_pinned",
            clientRequestId: "fault",
            ownerFingerprint: "owner-a"
        ), .inProgress)
        XCTAssertEqual(try EventLogRepository(db: db).lastSeq(), 0)
        let sequence = try db.prepare("SELECT last_seq FROM event_sequence WHERE singleton = 1;")
        XCTAssertTrue(try sequence.step())
        XCTAssertEqual(sequence.columnInt64(0), 0)

        try db.execute("DROP TRIGGER fail_second_receipt_event;")
        let persisted = try repository.finalize(
            method: "workspace.set_pinned",
            clientRequestId: "fault",
            ownerFingerprint: "owner-a",
            paramsHash: "hash-a",
            resultJSON: "true",
            events: intents
        )
        XCTAssertEqual(persisted.map(\.seq), [1, 2])
    }

    private func seedClaim(databasePath: String) throws {
        let database = try SQLiteDB(path: databasePath)
        try Schema.migrate(database)
        let repository = CommandReceiptRepository(db: database)
        XCTAssertEqual(try repository.claim(
            method: "workspace.close",
            clientRequestId: "interrupted",
            ownerFingerprint: "owner-a",
            paramsHash: "hash-a"
        ), .claimed)
    }

    private func scalar(_ db: SQLiteDB, _ sql: String) throws -> Int64 {
        let statement = try db.prepare(sql)
        XCTAssertTrue(try statement.step())
        return statement.columnInt64(0)
    }
}
