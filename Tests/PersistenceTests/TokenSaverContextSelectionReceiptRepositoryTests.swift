import CryptoKit
import SQLite3
import XCTest
@testable import CoreModel
@testable import Persistence

/// WHY: context-slot receipts must be content-free, keyed by the fresh
/// destination, and retry-safe. A row that stored Human/RCS1 bytes or a
/// delivered lifecycle before send acceptance would either leak transport
/// or claim a seed that Codex never accepted.
final class TokenSaverContextSelectionReceiptRepositoryTests: XCTestCase {
    func test_roundtripPersistsIdentityWithoutPayloadsAndIsIdempotent() async throws {
        let db = try makeDB()
        let repo = TokenSaverContextSelectionReceiptRepository(db: db)
        let parents = try seedParents(db)
        let record = try await makeAssistantRecord(parents: parents, dest: "codex-dest-1")

        try repo.persistPending(record)
        let loaded = try XCTUnwrap(repo.load(
            runId: record.winner.runId,
            destinationProviderThreadId: record.winner.destinationProviderThreadId,
            snapshotDigest: record.winner.snapshotDigest,
            sourceMessageId: record.winner.sourceMessageId,
            ordinal: record.winner.ordinal
        ))
        XCTAssertEqual(loaded.winner.selectedFormat, .rcs1)
        XCTAssertEqual(loaded.winner.lifecycle, .provisional)
        XCTAssertFalse(loaded.winner.billingClaim)
        XCTAssertEqual(loaded.arms.count, 3)
        XCTAssertEqual(try XCTUnwrap(loaded.arm(.rcs1)).eligible, true)

        try repo.persistPending(record)
        XCTAssertEqual(try repo.list(runId: parents.run.id).count, 1)

        let encoded = String(
            data: try JSONEncoder().encode(loaded),
            encoding: .utf8
        )
        let haystack = try XCTUnwrap(encoded)
        XCTAssertFalse(haystack.contains("ABCDEFGH"))
        XCTAssertFalse(haystack.contains("RCS1/1"))
        XCTAssertFalse(haystack.contains("[[rc:"))
        XCTAssertFalse(haystack.contains("selectedPayload"))
    }

    func test_duplicatePersistWithDifferentIdentityFailsAndDoesNotCreateSecondDelivered() throws {
        let db = try makeDB()
        let repo = TokenSaverContextSelectionReceiptRepository(db: db)
        let parents = try seedParents(db)
        var record = TokenSaverContextSelectionReceipt.humanUserSlot(
            runId: parents.run.id.value.uuidString,
            destinationProviderThreadId: "dest-a",
            snapshotDigest: String(repeating: "a", count: 64),
            sourceMessageId: UUID().uuidString,
            ordinal: 0,
            provider: "codex",
            resolvedModel: "gpt-test"
        )
        try repo.persistPending(record)
        var changed = record
        changed.winner.selectedFormat = .rcs1
        XCTAssertThrowsError(try repo.persistPending(changed)) { error in
            guard case TokenSaverContextSelectionReceiptError.identityMismatch = error else {
                return XCTFail("expected identity mismatch, got \(error)")
            }
        }
        XCTAssertEqual(try repo.list(runId: parents.run.id).count, 1)
    }

    func test_lifecycleProvisionalToDeliveredAndFailedIsTerminal() throws {
        let db = try makeDB()
        let repo = TokenSaverContextSelectionReceiptRepository(db: db)
        let parents = try seedParents(db)
        let record = TokenSaverContextSelectionReceipt.humanUserSlot(
            runId: parents.run.id.value.uuidString,
            destinationProviderThreadId: "dest-b",
            snapshotDigest: String(repeating: "b", count: 64),
            sourceMessageId: UUID().uuidString,
            ordinal: 1,
            provider: "codex",
            resolvedModel: "gpt-test"
        )
        try repo.persistPending(record)
        try repo.acknowledge([
            TokenSaverContextSelectionLifecycleAck(
                runId: record.winner.runId,
                destinationProviderThreadId: record.winner.destinationProviderThreadId,
                snapshotDigest: record.winner.snapshotDigest,
                sourceMessageId: record.winner.sourceMessageId,
                ordinal: record.winner.ordinal,
                lifecycle: .delivered
            )
        ])
        XCTAssertEqual(
            try repo.load(
                runId: record.winner.runId,
                destinationProviderThreadId: record.winner.destinationProviderThreadId,
                snapshotDigest: record.winner.snapshotDigest,
                sourceMessageId: record.winner.sourceMessageId,
                ordinal: record.winner.ordinal
            )?.winner.lifecycle,
            .delivered
        )
        XCTAssertThrowsError(try repo.acknowledge([
            TokenSaverContextSelectionLifecycleAck(
                runId: record.winner.runId,
                destinationProviderThreadId: record.winner.destinationProviderThreadId,
                snapshotDigest: record.winner.snapshotDigest,
                sourceMessageId: record.winner.sourceMessageId,
                ordinal: record.winner.ordinal,
                lifecycle: .provisional
            )
        ]))

        let failed = TokenSaverContextSelectionReceipt.humanUserSlot(
            runId: parents.run.id.value.uuidString,
            destinationProviderThreadId: "dest-c",
            snapshotDigest: String(repeating: "c", count: 64),
            sourceMessageId: UUID().uuidString,
            ordinal: 2,
            provider: "codex",
            resolvedModel: "gpt-test"
        )
        try repo.persistPending(failed)
        try repo.acknowledge([
            TokenSaverContextSelectionLifecycleAck(
                runId: failed.winner.runId,
                destinationProviderThreadId: failed.winner.destinationProviderThreadId,
                snapshotDigest: failed.winner.snapshotDigest,
                sourceMessageId: failed.winner.sourceMessageId,
                ordinal: failed.winner.ordinal,
                lifecycle: .notDelivered
            )
        ])
        XCTAssertEqual(
            try repo.load(
                runId: failed.winner.runId,
                destinationProviderThreadId: failed.winner.destinationProviderThreadId,
                snapshotDigest: failed.winner.snapshotDigest,
                sourceMessageId: failed.winner.sourceMessageId,
                ordinal: failed.winner.ordinal
            )?.winner.lifecycle,
            .notDelivered
        )
        XCTAssertFalse(try repo.hasDelivered(
            runId: failed.winner.runId,
            destinationProviderThreadId: failed.winner.destinationProviderThreadId,
            snapshotDigest: failed.winner.snapshotDigest
        ))
        XCTAssertTrue(try repo.hasDelivered(
            runId: record.winner.runId,
            destinationProviderThreadId: record.winner.destinationProviderThreadId,
            snapshotDigest: record.winner.snapshotDigest
        ))
    }

    func test_requestReceiptTablesRemainCompatibleAfterContextMigration() async throws {
        let db = try makeDB()
        let requestRepo = TokenSaverRequestSelectionReceiptRepository(db: db)
        let parents = try seedParents(db)
        let human = "request selector still works"
        let decision = await TokenSaverBestOfThreeSelector.select(
            canonicalHuman: human,
            humanOutboundPrompt: human,
            humanEffectiveEnvelope: human,
            target: .init(
                provider: "codex",
                resolvedModel: "gpt-test",
                counterID: "c",
                counterRevision: "1",
                encoding: "e"
            ),
            candidates: [],
            counter: nil
        )
        let record = TokenSaverRequestSelectionReceipt.project(
            decision: decision,
            runId: parents.run.id.value.uuidString,
            threadId: parents.thread.id.value.uuidString,
            provider: "codex",
            resolvedModel: "gpt-test"
        )
        try requestRepo.persistPendingRun(parents.run, record: record)
        XCTAssertEqual(try requestRepo.load(runId: parents.run.id)?.winner.selectedFormat, .human)
        XCTAssertEqual(try requestRepo.load(runId: parents.run.id)?.winner.lifecycle, .provisional)
    }

    private func makeDB() throws -> SQLiteDB {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        return db
    }

    private func seedParents(_ db: SQLiteDB) throws -> (thread: AgentThread, run: AgentRun) {
        let thread = AgentThread(title: "context-receipts", provider: .codex, model: "gpt-test")
        try AgentThreadRepository(db: db).upsert(thread)
        let run = AgentRun(threadId: thread.id, provider: .codex, model: "gpt-test", status: .pending)
        try AgentRunRepository(db: db).upsert(run)
        return (thread, run)
    }

    private func makeAssistantRecord(
        parents: (thread: AgentThread, run: AgentRun),
        dest: String
    ) async throws -> TokenSaverContextSelectionReceipt.Record {
        let human = String(repeating: "ABCDEFGH", count: 16)
        let rcs1 = TokenSaverContextItemSelector.rcs1Candidate(
            canonicalHuman: human,
            abi: "RCS1 ABI",
            effectiveEnvelope: "RCS1 ABI\n" + (RemoteCodeCompactSpan.encode(human) ?? "")
        )
        let rcw1 = TokenSaverContextItemSelector.ineligibleRCW1Candidate(
            sourceSHA256: SHA256.hash(data: Data(human.utf8)).map { String(format: "%02x", $0) }.joined()
        )
        let decision = await TokenSaverContextItemSelector.select(
            canonicalHuman: human,
            humanEnvelope: "HUMAN ABI\n\(human)",
            rcw1: rcw1,
            rcs1: rcs1,
            target: .init(
                provider: "codex",
                resolvedModel: "gpt-test",
                counterID: "fixture-counter",
                counterRevision: "1",
                encoding: "fixture-exact"
            ),
            counter: .init(
                counter: .init(
                    id: "fixture-counter",
                    revision: "1",
                    encoding: "fixture-exact",
                    provider: "codex",
                    resolvedModel: "gpt-test",
                    quality: .exactLocalTokenizer
                )
            ) { text in
                if text.hasPrefix("HUMAN") { return 100 }
                if text.hasPrefix("RCS1 ABI\n") { return 30 }
                return 20
            }
        )
        return TokenSaverContextSelectionReceipt.project(
            decision: decision,
            runId: parents.run.id.value.uuidString,
            destinationProviderThreadId: dest,
            snapshotDigest: String(repeating: "d", count: 64),
            sourceMessageId: UUID().uuidString,
            role: .assistant,
            ordinal: 1,
            provider: "codex",
            resolvedModel: "gpt-test"
        )
    }
}
