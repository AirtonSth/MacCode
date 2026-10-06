import XCTest
@testable import CoreModel
@testable import Persistence

/// WHY: seed-slot receipts keep a fresh provider session from being seeded
/// twice for the same run, destination and snapshot, also after a restart.
/// A receipt marked delivered before the provider accepted the turn, or a
/// failed slot that could not be handed out again, would either claim context
/// the session never got or block the retry that would give it.
final class ConversationContextSeedReceiptRepositoryTests: XCTestCase {
    func test_roundtripIsContentFreeAndIdempotent() throws {
        let db = try makeDB()
        let repo = ConversationContextSeedReceiptRepository(db: db)
        let parents = try seedParents(db)
        let receipt = makeReceipt(parents: parents, dest: "codex-dest-1", role: .assistant, ordinal: 1)

        try repo.persistPending(receipt)
        let loaded = try XCTUnwrap(load(repo, receipt))
        XCTAssertEqual(loaded.lifecycle, .provisional)
        XCTAssertEqual(loaded.role, .assistant)
        XCTAssertEqual(loaded.provider, "codex")
        XCTAssertEqual(loaded.resolvedModel, "gpt-test")

        try repo.persistPending(receipt)
        XCTAssertEqual(try repo.list(runId: parents.run.id).count, 1)
    }

    func test_duplicatePersistWithDifferentRoleFailsAndKeepsOneRow() throws {
        let db = try makeDB()
        let repo = ConversationContextSeedReceiptRepository(db: db)
        let parents = try seedParents(db)
        let receipt = makeReceipt(parents: parents, dest: "dest-a", role: .user, ordinal: 0)
        try repo.persistPending(receipt)
        var changed = receipt
        changed.role = .assistant
        XCTAssertThrowsError(try repo.persistPending(changed)) { error in
            guard case ConversationContextSeedReceiptError.identityMismatch = error else {
                return XCTFail("expected identity mismatch, got \(error)")
            }
        }
        XCTAssertEqual(try repo.list(runId: parents.run.id).count, 1)
    }

    func test_lifecycleProvisionalToDeliveredAndFailedIsTerminal() throws {
        let db = try makeDB()
        let repo = ConversationContextSeedReceiptRepository(db: db)
        let parents = try seedParents(db)
        let delivered = makeReceipt(parents: parents, dest: "dest-b", role: .user, ordinal: 1)
        try repo.persistPending(delivered)
        try repo.acknowledge([ack(delivered, .delivered)])
        XCTAssertEqual(try load(repo, delivered)?.lifecycle, .delivered)
        XCTAssertThrowsError(try repo.acknowledge([ack(delivered, .provisional)]))

        let failed = makeReceipt(parents: parents, dest: "dest-c", role: .user, ordinal: 2)
        try repo.persistPending(failed)
        try repo.acknowledge([ack(failed, .notDelivered)])
        XCTAssertEqual(try load(repo, failed)?.lifecycle, .notDelivered)
        XCTAssertFalse(try repo.hasDelivered(
            runId: failed.runId,
            destinationProviderThreadId: failed.destinationProviderThreadId,
            snapshotDigest: failed.snapshotDigest
        ))
        XCTAssertTrue(try repo.hasDelivered(
            runId: delivered.runId,
            destinationProviderThreadId: delivered.destinationProviderThreadId,
            snapshotDigest: delivered.snapshotDigest
        ))
    }

    func test_notDeliveredSlotCanBeHandedOutAgain() throws {
        let db = try makeDB()
        let repo = ConversationContextSeedReceiptRepository(db: db)
        let parents = try seedParents(db)
        let receipt = makeReceipt(parents: parents, dest: "dest-d", role: .assistant, ordinal: 0)
        try repo.persistPending(receipt)
        try repo.acknowledge([ack(receipt, .notDelivered)])

        try repo.persistPending(receipt)
        XCTAssertEqual(try load(repo, receipt)?.lifecycle, .provisional)
        try repo.acknowledge([ack(receipt, .delivered)])
        XCTAssertEqual(try load(repo, receipt)?.lifecycle, .delivered)
    }

    func test_acknowledgingAnUnknownSlotFails() throws {
        let db = try makeDB()
        let repo = ConversationContextSeedReceiptRepository(db: db)
        let parents = try seedParents(db)
        let receipt = makeReceipt(parents: parents, dest: "dest-e", role: .user, ordinal: 0)
        XCTAssertThrowsError(try repo.acknowledge([ack(receipt, .delivered)])) { error in
            guard case ConversationContextSeedReceiptError.missingReceipt = error else {
                return XCTFail("expected missing receipt, got \(error)")
            }
        }
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

    private func makeReceipt(
        parents: (thread: AgentThread, run: AgentRun),
        dest: String,
        role: ConversationContextSeed.Role,
        ordinal: Int
    ) -> ConversationContextSeedReceipt {
        ConversationContextSeedReceipt(
            runId: parents.run.id.value.uuidString,
            destinationProviderThreadId: dest,
            snapshotDigest: String(repeating: "a", count: 64),
            sourceMessageId: UUID().uuidString,
            role: role,
            ordinal: ordinal,
            provider: "codex",
            resolvedModel: "gpt-test"
        )
    }

    private func ack(
        _ receipt: ConversationContextSeedReceipt,
        _ lifecycle: ConversationContextSeedReceipt.Lifecycle
    ) -> ConversationContextSeedAck {
        ConversationContextSeedAck(
            runId: receipt.runId,
            destinationProviderThreadId: receipt.destinationProviderThreadId,
            snapshotDigest: receipt.snapshotDigest,
            sourceMessageId: receipt.sourceMessageId,
            ordinal: receipt.ordinal,
            lifecycle: lifecycle
        )
    }

    private func load(
        _ repo: ConversationContextSeedReceiptRepository,
        _ receipt: ConversationContextSeedReceipt
    ) throws -> ConversationContextSeedReceipt? {
        try repo.load(
            runId: receipt.runId,
            destinationProviderThreadId: receipt.destinationProviderThreadId,
            snapshotDigest: receipt.snapshotDigest,
            sourceMessageId: receipt.sourceMessageId,
            ordinal: receipt.ordinal
        )
    }
}
