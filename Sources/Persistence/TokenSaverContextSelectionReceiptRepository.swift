import Foundation
import CoreModel

public final class TokenSaverContextSelectionReceiptRepository: @unchecked Sendable {
    private let db: SQLiteDB

    public init(db: SQLiteDB) {
        self.db = db
    }

    public func persistPending(_ record: TokenSaverContextSelectionReceipt.Record) throws {
        let arms = TokenSaverBestOfThreeSelector.Format.allCases.compactMap { format in
            record.arm(format)
        }
        guard arms.count == 3 else {
            throw TokenSaverContextSelectionReceiptError.invalidArmSet
        }
        try db.performSync { database in
            try database.transaction {
                try Self.writeRecord(
                    TokenSaverContextSelectionReceipt.Record(winner: record.winner, arms: arms),
                    database: database
                )
            }
        }
    }

    public func persistPending(_ records: [TokenSaverContextSelectionReceipt.Record]) throws {
        for record in records {
            try persistPending(record)
        }
    }

    public func acknowledgeBatch(_ acks: [TokenSaverContextSelectionLifecycleAck]) throws {
        try db.performSync { database in
            try database.transaction {
                let now = iso.string(from: Date())
                for ack in acks {
                    guard let existing = try Self.loadRecord(
                        runId: ack.runId,
                        destinationProviderThreadId: ack.destinationProviderThreadId,
                        snapshotDigest: ack.snapshotDigest,
                        sourceMessageId: ack.sourceMessageId,
                        ordinal: ack.ordinal,
                        database: database
                    ) else {
                        throw TokenSaverContextSelectionReceiptError.missingReceipt(runId: ack.runId)
                    }
                    if existing.winner.lifecycle == ack.lifecycle {
                        continue
                    }
                    if existing.winner.lifecycle == .delivered
                        || existing.winner.lifecycle == .deliveryUnknown
                        || existing.winner.lifecycle == .notDelivered {
                        throw TokenSaverContextSelectionReceiptError.illegalLifecycleTransition(
                            runId: ack.runId,
                            from: existing.winner.lifecycle,
                            to: ack.lifecycle
                        )
                    }
                    let update = try database.prepare("""
                        UPDATE token_saver_context_slot_receipts
                        SET lifecycle = ?, updated_at = ?
                        WHERE run_id = ?
                          AND destination_provider_thread_id = ?
                          AND snapshot_digest = ?
                          AND source_message_id = ?
                          AND ordinal = ?;
                        """)
                    try update.bind(1, ack.lifecycle.rawValue)
                    try update.bind(2, now)
                    try update.bind(3, ack.runId)
                    try update.bind(4, ack.destinationProviderThreadId)
                    try update.bind(5, ack.snapshotDigest)
                    try update.bind(6, ack.sourceMessageId)
                    try update.bind(7, Int64(ack.ordinal))
                    _ = try update.step()
                }
            }
        }
    }

    public func acknowledge(_ acks: [TokenSaverContextSelectionLifecycleAck]) throws {
        try acknowledgeBatch(acks)
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
            try statement.bind(4, TokenSaverRequestSelectionReceipt.Lifecycle.delivered.rawValue)
            return try statement.step()
        }
    }

    public func load(
        runId: String,
        destinationProviderThreadId: String,
        snapshotDigest: String,
        sourceMessageId: String,
        ordinal: Int
    ) throws -> TokenSaverContextSelectionReceipt.Record? {
        try db.performSync { database in
            try Self.loadRecord(
                runId: runId,
                destinationProviderThreadId: destinationProviderThreadId,
                snapshotDigest: snapshotDigest,
                sourceMessageId: sourceMessageId,
                ordinal: ordinal,
                database: database
            )
        }
    }

    public func list(runId: AgentRunID) throws -> [TokenSaverContextSelectionReceipt.Record] {
        try db.performSync { database in
            let statement = try database.prepare("""
                SELECT run_id, destination_provider_thread_id, snapshot_digest,
                       source_message_id, ordinal
                FROM token_saver_context_slot_receipts
                WHERE run_id = ?
                ORDER BY ordinal ASC, source_message_id ASC;
                """)
            try statement.bind(1, runId.value.uuidString)
            var records: [TokenSaverContextSelectionReceipt.Record] = []
            while try statement.step() {
                guard let dest = statement.columnText(1),
                      let digest = statement.columnText(2),
                      let source = statement.columnText(3),
                      let record = try Self.loadRecord(
                        runId: runId.value.uuidString,
                        destinationProviderThreadId: dest,
                        snapshotDigest: digest,
                        sourceMessageId: source,
                        ordinal: Int(statement.columnInt64(4)),
                        database: database
                      ) else {
                    continue
                }
                records.append(record)
            }
            return records
        }
    }

    private static func writeRecord(
        _ record: TokenSaverContextSelectionReceipt.Record,
        database: SQLiteDB
    ) throws {
        if let existing = try loadRecord(
            runId: record.winner.runId,
            destinationProviderThreadId: record.winner.destinationProviderThreadId,
            snapshotDigest: record.winner.snapshotDigest,
            sourceMessageId: record.winner.sourceMessageId,
            ordinal: record.winner.ordinal,
            database: database
        ) {
            guard TokenSaverContextSelectionReceipt.identityMatches(existing, record) else {
                throw TokenSaverContextSelectionReceiptError.identityMismatch(runId: record.winner.runId)
            }
            if existing.winner.lifecycle == .notDelivered {
                let update = try database.prepare("""
                    UPDATE token_saver_context_slot_receipts
                    SET lifecycle = ?, updated_at = ?
                    WHERE run_id = ?
                      AND destination_provider_thread_id = ?
                      AND snapshot_digest = ?
                      AND source_message_id = ?
                      AND ordinal = ?;
                    """)
                try update.bind(1, TokenSaverRequestSelectionReceipt.Lifecycle.provisional.rawValue)
                try update.bind(2, iso.string(from: Date()))
                try update.bind(3, record.winner.runId)
                try update.bind(4, record.winner.destinationProviderThreadId)
                try update.bind(5, record.winner.snapshotDigest)
                try update.bind(6, record.winner.sourceMessageId)
                try update.bind(7, Int64(record.winner.ordinal))
                _ = try update.step()
            }
            return
        }
        let now = iso.string(from: Date())
        let insert = try database.prepare("""
            INSERT INTO token_saver_context_slot_receipts(
                run_id, destination_provider_thread_id, snapshot_digest, source_message_id,
                role, ordinal, provider, resolved_model, selected_format, reason,
                modeled_context_delta, counter_id, counter_revision, encoding,
                counter_status, lifecycle, billing_claim, created_at, updated_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?);
            """)
        try insert.bind(1, record.winner.runId)
        try insert.bind(2, record.winner.destinationProviderThreadId)
        try insert.bind(3, record.winner.snapshotDigest)
        try insert.bind(4, record.winner.sourceMessageId)
        try insert.bind(5, record.winner.role.rawValue)
        try insert.bind(6, Int64(record.winner.ordinal))
        try insert.bind(7, record.winner.provider)
        try insert.bind(8, record.winner.resolvedModel)
        try insert.bind(9, record.winner.selectedFormat.rawValue)
        try insert.bind(10, record.winner.reason.rawValue)
        try insert.bind(11, Int64(record.winner.modeledContextDelta))
        try insert.bind(12, record.winner.counterId)
        try insert.bind(13, record.winner.counterRevision)
        try insert.bind(14, record.winner.encoding)
        try insert.bind(15, record.winner.counterStatus.rawValue)
        try insert.bind(16, TokenSaverRequestSelectionReceipt.Lifecycle.provisional.rawValue)
        try insert.bind(17, now)
        try insert.bind(18, now)
        _ = try insert.step()

        let armInsert = try database.prepare("""
            INSERT INTO token_saver_context_slot_arm_receipts(
                run_id, destination_provider_thread_id, snapshot_digest, source_message_id,
                ordinal, format, source_bound, producer_id, producer_revision,
                abi_revision, generation, structural, semantic, recovery,
                projection, availability, eligible, proven_effective_count
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """)
        for arm in record.arms {
            armInsert.reset()
            try armInsert.bind(1, record.winner.runId)
            try armInsert.bind(2, record.winner.destinationProviderThreadId)
            try armInsert.bind(3, record.winner.snapshotDigest)
            try armInsert.bind(4, record.winner.sourceMessageId)
            try armInsert.bind(5, Int64(record.winner.ordinal))
            try armInsert.bind(6, arm.format.rawValue)
            try armInsert.bind(7, Int64(arm.sourceBound ? 1 : 0))
            try armInsert.bind(8, arm.producerId)
            try armInsert.bind(9, arm.producerRevision)
            try armInsert.bind(10, arm.abiRevision)
            try armInsert.bind(11, arm.generation.rawValue)
            try armInsert.bind(12, arm.structural.rawValue)
            try armInsert.bind(13, arm.semantic.rawValue)
            try armInsert.bind(14, arm.recovery.rawValue)
            try armInsert.bind(15, arm.projection.rawValue)
            try armInsert.bind(16, arm.availability.rawValue)
            try armInsert.bind(17, Int64(arm.eligible ? 1 : 0))
            if let count = arm.provenEffectiveCount {
                try armInsert.bind(18, Int64(count))
            } else {
                try armInsert.bind(18, Optional<Int64>.none)
            }
            _ = try armInsert.step()
        }
    }

    private static func loadRecord(
        runId: String,
        destinationProviderThreadId: String,
        snapshotDigest: String,
        sourceMessageId: String,
        ordinal: Int,
        database: SQLiteDB
    ) throws -> TokenSaverContextSelectionReceipt.Record? {
        let winnerSQL = try database.prepare("""
            SELECT run_id, destination_provider_thread_id, snapshot_digest, source_message_id,
                   role, ordinal, provider, resolved_model, selected_format, reason,
                   modeled_context_delta, counter_id, counter_revision, encoding,
                   counter_status, lifecycle, billing_claim, created_at, updated_at
            FROM token_saver_context_slot_receipts
            WHERE run_id = ?
              AND destination_provider_thread_id = ?
              AND snapshot_digest = ?
              AND source_message_id = ?
              AND ordinal = ?
            LIMIT 1;
            """)
        try winnerSQL.bind(1, runId)
        try winnerSQL.bind(2, destinationProviderThreadId)
        try winnerSQL.bind(3, snapshotDigest)
        try winnerSQL.bind(4, sourceMessageId)
        try winnerSQL.bind(5, Int64(ordinal))
        guard try winnerSQL.step() else { return nil }
        guard let role = TokenSaverContextSelectionReceipt.SlotRole(rawValue: winnerSQL.columnText(4) ?? ""),
              let selected = TokenSaverRequestSelectionReceipt.SelectedFormat(
                rawValue: winnerSQL.columnText(8) ?? ""
              ),
              let reason = TokenSaverBestOfThreeSelector.Reason(rawValue: winnerSQL.columnText(9) ?? ""),
              let counterStatus = TokenSaverRequestSelectionReceipt.CounterStatus(
                rawValue: winnerSQL.columnText(14) ?? ""
              ),
              let lifecycle = TokenSaverRequestSelectionReceipt.Lifecycle(
                rawValue: winnerSQL.columnText(15) ?? ""
              ) else {
            return nil
        }
        let winner = TokenSaverContextSelectionReceipt.Winner(
            runId: winnerSQL.columnText(0) ?? runId,
            destinationProviderThreadId: winnerSQL.columnText(1) ?? destinationProviderThreadId,
            snapshotDigest: winnerSQL.columnText(2) ?? snapshotDigest,
            sourceMessageId: winnerSQL.columnText(3) ?? sourceMessageId,
            role: role,
            ordinal: Int(winnerSQL.columnInt64(5)),
            provider: winnerSQL.columnText(6) ?? "",
            resolvedModel: winnerSQL.columnText(7) ?? "",
            selectedFormat: selected,
            reason: reason,
            modeledContextDelta: Int(winnerSQL.columnInt64(10)),
            counterId: winnerSQL.columnIsNull(11) ? nil : winnerSQL.columnText(11),
            counterRevision: winnerSQL.columnIsNull(12) ? nil : winnerSQL.columnText(12),
            encoding: winnerSQL.columnIsNull(13) ? nil : winnerSQL.columnText(13),
            counterStatus: counterStatus,
            lifecycle: lifecycle,
            billingClaim: false,
            createdAt: winnerSQL.columnText(17),
            updatedAt: winnerSQL.columnText(18)
        )
        let armsSQL = try database.prepare("""
            SELECT format, source_bound, producer_id, producer_revision,
                   abi_revision, generation, structural, semantic, recovery,
                   projection, availability, eligible, proven_effective_count
            FROM token_saver_context_slot_arm_receipts
            WHERE run_id = ?
              AND destination_provider_thread_id = ?
              AND snapshot_digest = ?
              AND source_message_id = ?
              AND ordinal = ?
            ORDER BY format ASC;
            """)
        try armsSQL.bind(1, runId)
        try armsSQL.bind(2, destinationProviderThreadId)
        try armsSQL.bind(3, snapshotDigest)
        try armsSQL.bind(4, sourceMessageId)
        try armsSQL.bind(5, Int64(ordinal))
        var arms: [TokenSaverRequestSelectionReceipt.Arm] = []
        while try armsSQL.step() {
            guard let format = TokenSaverBestOfThreeSelector.Format(rawValue: armsSQL.columnText(0) ?? ""),
                  let generation = TokenSaverBestOfThreeSelector.GateStatus(rawValue: armsSQL.columnText(5) ?? ""),
                  let structural = TokenSaverBestOfThreeSelector.GateStatus(rawValue: armsSQL.columnText(6) ?? ""),
                  let semantic = TokenSaverBestOfThreeSelector.GateStatus(rawValue: armsSQL.columnText(7) ?? ""),
                  let recovery = TokenSaverBestOfThreeSelector.GateStatus(rawValue: armsSQL.columnText(8) ?? ""),
                  let projection = TokenSaverRequestSelectionReceipt.ProjectionStatus(
                    rawValue: armsSQL.columnText(9) ?? ""
                  ),
                  let availability = TokenSaverRequestSelectionReceipt.AvailabilityStatus(
                    rawValue: armsSQL.columnText(10) ?? ""
                  ) else {
                continue
            }
            arms.append(TokenSaverRequestSelectionReceipt.Arm(
                runId: runId,
                format: format,
                sourceBound: armsSQL.columnInt64(1) != 0,
                producerId: armsSQL.columnText(2) ?? "",
                producerRevision: armsSQL.columnText(3) ?? "",
                abiRevision: armsSQL.columnText(4) ?? "",
                generation: generation,
                structural: structural,
                semantic: semantic,
                recovery: recovery,
                projection: projection,
                availability: availability,
                eligible: armsSQL.columnInt64(11) != 0,
                provenEffectiveCount: armsSQL.columnIsNull(12) ? nil : Int(armsSQL.columnInt64(12))
            ))
        }
        return TokenSaverContextSelectionReceipt.Record(winner: winner, arms: arms)
    }
}

public extension AgentRunRepository {
    func contextSelectionReceipts() -> TokenSaverContextSelectionReceiptRepository {
        TokenSaverContextSelectionReceiptRepository(db: db)
    }
}
