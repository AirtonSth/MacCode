import Foundation
import CoreModel

/// Durable seed-slot receipts for `ConversationContextSeed`.
///
/// Rows live in `token_saver_context_slot_receipts`, the table the removed
/// Token Saver created for these receipts (historical schema, renaming it needs
/// a migration). Every row is a Human slot: `selected_format` is `human`, no
/// counter, no billing claim. The per-arm audit table is no longer written.
public final class ConversationContextSeedReceiptRepository: @unchecked Sendable {
    private let db: SQLiteDB

    public init(db: SQLiteDB) {
        self.db = db
    }

    public func persistPending(_ receipt: ConversationContextSeedReceipt) throws {
        try db.performSync { database in
            try database.transaction {
                try Self.writePending(receipt, database: database)
            }
        }
    }

    public func persistPending(_ receipts: [ConversationContextSeedReceipt]) throws {
        for receipt in receipts {
            try persistPending(receipt)
        }
    }

    public func acknowledge(_ acks: [ConversationContextSeedAck]) throws {
        try db.performSync { database in
            try database.transaction {
                let now = iso.string(from: Date())
                for ack in acks {
                    guard let existing = try Self.loadReceipt(
                        runId: ack.runId,
                        destinationProviderThreadId: ack.destinationProviderThreadId,
                        snapshotDigest: ack.snapshotDigest,
                        sourceMessageId: ack.sourceMessageId,
                        ordinal: ack.ordinal,
                        database: database
                    ) else {
                        throw ConversationContextSeedReceiptError.missingReceipt(runId: ack.runId)
                    }
                    if existing.lifecycle == ack.lifecycle {
                        continue
                    }
                    if existing.lifecycle != .provisional {
                        throw ConversationContextSeedReceiptError.illegalLifecycleTransition(
                            runId: ack.runId,
                            from: existing.lifecycle,
                            to: ack.lifecycle
                        )
                    }
                    try Self.updateLifecycle(
                        ack.lifecycle,
                        runId: ack.runId,
                        destinationProviderThreadId: ack.destinationProviderThreadId,
                        snapshotDigest: ack.snapshotDigest,
                        sourceMessageId: ack.sourceMessageId,
                        ordinal: ack.ordinal,
                        now: now,
                        database: database
                    )
                }
            }
        }
    }

    public func hasDelivered(
        runId: String,
        destinationProviderThreadId: String,
        snapshotDigest: String
    ) throws -> Bool {
        try db.performSync { database in
            let statement = try database.prepare("""
                SELECT 1 FROM token_saver_context_slot_receipts
                WHERE run_id = ?
                  AND destination_provider_thread_id = ?
                  AND snapshot_digest = ?
                  AND lifecycle = ?
                LIMIT 1;
                """)
            try statement.bind(1, runId)
            try statement.bind(2, destinationProviderThreadId)
            try statement.bind(3, snapshotDigest)
            try statement.bind(4, ConversationContextSeedReceipt.Lifecycle.delivered.rawValue)
            return try statement.step()
        }
    }

    public func load(
        runId: String,
        destinationProviderThreadId: String,
        snapshotDigest: String,
        sourceMessageId: String,
        ordinal: Int
    ) throws -> ConversationContextSeedReceipt? {
        try db.performSync { database in
            try Self.loadReceipt(
                runId: runId,
                destinationProviderThreadId: destinationProviderThreadId,
                snapshotDigest: snapshotDigest,
                sourceMessageId: sourceMessageId,
                ordinal: ordinal,
                database: database
            )
        }
    }

    public func list(runId: AgentRunID) throws -> [ConversationContextSeedReceipt] {
        try db.performSync { database in
            let statement = try database.prepare("""
                SELECT \(Self.columns)
                FROM token_saver_context_slot_receipts
                WHERE run_id = ?
                ORDER BY ordinal ASC, source_message_id ASC;
                """)
            try statement.bind(1, runId.value.uuidString)
            var receipts: [ConversationContextSeedReceipt] = []
            while try statement.step() {
                if let receipt = Self.receipt(from: statement) {
                    receipts.append(receipt)
                }
            }
            return receipts
        }
    }

    private static let columns = """
        run_id, destination_provider_thread_id, snapshot_digest, source_message_id,
        role, ordinal, provider, resolved_model, lifecycle, created_at, updated_at
        """

    private static func writePending(
        _ receipt: ConversationContextSeedReceipt,
        database: SQLiteDB
    ) throws {
        let now = iso.string(from: Date())
        if let existing = try loadReceipt(
            runId: receipt.runId,
            destinationProviderThreadId: receipt.destinationProviderThreadId,
            snapshotDigest: receipt.snapshotDigest,
            sourceMessageId: receipt.sourceMessageId,
            ordinal: receipt.ordinal,
            database: database
        ) {
            guard existing.role == receipt.role else {
                throw ConversationContextSeedReceiptError.identityMismatch(runId: receipt.runId)
            }
            // A slot the provider did not take may be handed out again.
            if existing.lifecycle == .notDelivered {
                try updateLifecycle(
                    .provisional,
                    runId: receipt.runId,
                    destinationProviderThreadId: receipt.destinationProviderThreadId,
                    snapshotDigest: receipt.snapshotDigest,
                    sourceMessageId: receipt.sourceMessageId,
                    ordinal: receipt.ordinal,
                    now: now,
                    database: database
                )
            }
            return
        }
        // `reason` keeps the values the Human-only path always recorded.
        let insert = try database.prepare("""
            INSERT INTO token_saver_context_slot_receipts(
                run_id, destination_provider_thread_id, snapshot_digest, source_message_id,
                role, ordinal, provider, resolved_model, selected_format, reason,
                modeled_context_delta, counter_id, counter_revision, encoding,
                counter_status, lifecycle, billing_claim, created_at, updated_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, 'human', ?, 0, NULL, NULL, NULL,
                     'unavailable', ?, 0, ?, ?);
            """)
        try insert.bind(1, receipt.runId)
        try insert.bind(2, receipt.destinationProviderThreadId)
        try insert.bind(3, receipt.snapshotDigest)
        try insert.bind(4, receipt.sourceMessageId)
        try insert.bind(5, receipt.role.rawValue)
        try insert.bind(6, Int64(receipt.ordinal))
        try insert.bind(7, receipt.provider)
        try insert.bind(8, receipt.resolvedModel)
        try insert.bind(9, receipt.role == .user ? "no_eligible_optimized_candidate" : "counter_unavailable")
        try insert.bind(10, ConversationContextSeedReceipt.Lifecycle.provisional.rawValue)
        try insert.bind(11, now)
        try insert.bind(12, now)
        _ = try insert.step()
    }

    private static func updateLifecycle(
        _ lifecycle: ConversationContextSeedReceipt.Lifecycle,
        runId: String,
        destinationProviderThreadId: String,
        snapshotDigest: String,
        sourceMessageId: String,
        ordinal: Int,
        now: String,
        database: SQLiteDB
    ) throws {
        let update = try database.prepare("""
            UPDATE token_saver_context_slot_receipts
            SET lifecycle = ?, updated_at = ?
            WHERE run_id = ?
              AND destination_provider_thread_id = ?
              AND snapshot_digest = ?
              AND source_message_id = ?
              AND ordinal = ?;
            """)
        try update.bind(1, lifecycle.rawValue)
        try update.bind(2, now)
        try update.bind(3, runId)
        try update.bind(4, destinationProviderThreadId)
        try update.bind(5, snapshotDigest)
        try update.bind(6, sourceMessageId)
        try update.bind(7, Int64(ordinal))
        _ = try update.step()
    }

    private static func loadReceipt(
        runId: String,
        destinationProviderThreadId: String,
        snapshotDigest: String,
        sourceMessageId: String,
        ordinal: Int,
        database: SQLiteDB
    ) throws -> ConversationContextSeedReceipt? {
        let statement = try database.prepare("""
            SELECT \(columns)
            FROM token_saver_context_slot_receipts
            WHERE run_id = ?
              AND destination_provider_thread_id = ?
              AND snapshot_digest = ?
              AND source_message_id = ?
              AND ordinal = ?
            LIMIT 1;
            """)
        try statement.bind(1, runId)
        try statement.bind(2, destinationProviderThreadId)
        try statement.bind(3, snapshotDigest)
        try statement.bind(4, sourceMessageId)
        try statement.bind(5, Int64(ordinal))
        guard try statement.step() else { return nil }
        return receipt(from: statement)
    }

    private static func receipt(from statement: SQLiteStatement) -> ConversationContextSeedReceipt? {
        guard let runId = statement.columnText(0),
              let destination = statement.columnText(1),
              let digest = statement.columnText(2),
              let source = statement.columnText(3),
              let role = ConversationContextSeed.Role(rawValue: statement.columnText(4) ?? ""),
              let lifecycle = ConversationContextSeedReceipt.Lifecycle(
                rawValue: statement.columnText(8) ?? ""
              ) else {
            return nil
        }
        return ConversationContextSeedReceipt(
            runId: runId,
            destinationProviderThreadId: destination,
            snapshotDigest: digest,
            sourceMessageId: source,
            role: role,
            ordinal: Int(statement.columnInt64(5)),
            provider: statement.columnText(6) ?? "",
            resolvedModel: statement.columnText(7) ?? "",
            lifecycle: lifecycle,
            createdAt: statement.columnText(9),
            updatedAt: statement.columnText(10)
        )
    }
}

public extension AgentRunRepository {
    func contextSeedReceipts() -> ConversationContextSeedReceiptRepository {
        ConversationContextSeedReceiptRepository(db: db)
    }
}
