import Foundation
import CoreModel

public final class TokenSaverRequestSelectionReceiptRepository: @unchecked Sendable {
    private let db: SQLiteDB

    public init(db: SQLiteDB) {
        self.db = db
    }

    /// Atomically persist the pending agent_run parent, winner, and exactly
    /// three arms. Caller billing_claim is ignored and stored as 0.
    public func persistPendingRun(
        _ run: AgentRun,
        record: TokenSaverRequestSelectionReceipt.Record
    ) throws {
        guard record.winner.runId == run.id.value.uuidString,
              record.winner.threadId == run.threadId.value.uuidString else {
            throw TokenSaverRequestSelectionReceiptError.runIdentityMismatch
        }
        let arms = TokenSaverBestOfThreeSelector.Format.allCases.compactMap { format in
            record.arm(format)
        }
        guard arms.count == 3 else {
            throw TokenSaverRequestSelectionReceiptError.invalidArmSet
        }
        try db.performSync { database in
            try database.transaction {
                try AgentRunRepository(db: database).upsert(run)
                try Self.writeRecord(
                    TokenSaverRequestSelectionReceipt.Record(winner: record.winner, arms: arms),
                    database: database
                )
            }
        }
    }

    public func acknowledgeBatch(_ acks: [TokenSaverRequestSelectionLifecycleAck]) throws {
        try db.performSync { database in
            try database.transaction {
                let now = iso.string(from: Date())
                for ack in acks {
                    guard let existing = try Self.loadRecord(
                        runId: ack.runId,
                        database: database
                    ) else {
                        throw TokenSaverRequestSelectionReceiptError.missingReceipt(runId: ack.runId)
                    }
                    if existing.winner.lifecycle == ack.lifecycle {
                        continue
                    }
                    if existing.winner.lifecycle == .delivered
                        || existing.winner.lifecycle == .deliveryUnknown
                        || existing.winner.lifecycle == .notDelivered {
                        throw TokenSaverRequestSelectionReceiptError.illegalLifecycleTransition(
                            runId: ack.runId,
                            from: existing.winner.lifecycle,
                            to: ack.lifecycle
                        )
                    }
                    let update = try database.prepare("""
                        UPDATE token_saver_run_winner_receipts
                        SET lifecycle = ?, updated_at = ?
                        WHERE run_id = ?;
                        """)
                    try update.bind(1, ack.lifecycle.rawValue)
                    try update.bind(2, now)
                    try update.bind(3, ack.runId)
                    _ = try update.step()
                }
            }
        }
    }

    @discardableResult
    public func reconcileProvisionalOnRelaunch() throws -> Int {
        try db.performSync { database in
            try database.transaction {
                let update = try database.prepare("""
                    UPDATE token_saver_run_winner_receipts
                    SET lifecycle = ?, updated_at = ?
                    WHERE lifecycle = ?;
                    """)
                try update.bind(1, TokenSaverRequestSelectionReceipt.Lifecycle.deliveryUnknown.rawValue)
                try update.bind(2, iso.string(from: Date()))
                try update.bind(3, TokenSaverRequestSelectionReceipt.Lifecycle.provisional.rawValue)
                _ = try update.step()
                let count = try database.prepare("SELECT changes();")
                _ = try count.step()
                return Int(count.columnInt64(0))
            }
        }
    }

    public func load(runId: AgentRunID) throws -> TokenSaverRequestSelectionReceipt.Record? {
        try db.performSync { database in
            try Self.loadRecord(runId: runId.value.uuidString, database: database)
        }
    }

    public func list(threadId: AgentThreadID? = nil) throws -> [TokenSaverRequestSelectionReceipt.Record] {
        try report(threadId: threadId).records
    }

    public func report(threadId: AgentThreadID? = nil) throws -> TokenSaverRequestSelectionReceipt.Report {
        try db.performSync { database in
            let sql: String
            if threadId == nil {
                sql = """
                    SELECT run_id FROM token_saver_run_winner_receipts
                    ORDER BY created_at ASC, run_id ASC;
                    """
            } else {
                sql = """
                    SELECT run_id FROM token_saver_run_winner_receipts
                    WHERE thread_id = ?
                    ORDER BY created_at ASC, run_id ASC;
                    """
            }
            let statement = try database.prepare(sql)
            if let threadId {
                try statement.bind(1, threadId.value.uuidString)
            }
            var records: [TokenSaverRequestSelectionReceipt.Record] = []
            while try statement.step() {
                guard let runId = statement.columnText(0),
                      let record = try Self.loadRecord(runId: runId, database: database) else {
                    continue
                }
                records.append(record)
            }
            return TokenSaverRequestSelectionReceipt.Report(records: records)
        }
    }

    private static func writeRecord(
        _ record: TokenSaverRequestSelectionReceipt.Record,
        database: SQLiteDB
    ) throws {
        if let existing = try loadRecord(runId: record.winner.runId, database: database) {
            guard TokenSaverRequestSelectionReceipt.identityMatches(existing, record) else {
                throw TokenSaverRequestSelectionReceiptError.identityMismatch(runId: record.winner.runId)
            }
            if existing.winner.lifecycle == .notDelivered {
                let update = try database.prepare("""
                    UPDATE token_saver_run_winner_receipts
                    SET lifecycle = ?, updated_at = ?
                    WHERE run_id = ?;
                    """)
                try update.bind(1, TokenSaverRequestSelectionReceipt.Lifecycle.provisional.rawValue)
                try update.bind(2, iso.string(from: Date()))
                try update.bind(3, record.winner.runId)
                _ = try update.step()
            }
            return
        }
        let now = iso.string(from: Date())
        let insert = try database.prepare("""
            INSERT INTO token_saver_run_winner_receipts(
                run_id, thread_id, provider, resolved_model, selected_format, reason,
                modeled_context_delta, counter_id, counter_revision, encoding,
                counter_status, lifecycle, billing_claim, created_at, updated_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?);
            """)
        try insert.bind(1, record.winner.runId)
        try insert.bind(2, record.winner.threadId)
        try insert.bind(3, record.winner.provider)
        try insert.bind(4, record.winner.resolvedModel)
        try insert.bind(5, record.winner.selectedFormat.rawValue)
        try insert.bind(6, record.winner.reason.rawValue)
        try insert.bind(7, Int64(record.winner.modeledContextDelta))
        try insert.bind(8, record.winner.counterId)
        try insert.bind(9, record.winner.counterRevision)
        try insert.bind(10, record.winner.encoding)
        try insert.bind(11, record.winner.counterStatus.rawValue)
        try insert.bind(12, TokenSaverRequestSelectionReceipt.Lifecycle.provisional.rawValue)
        try insert.bind(13, now)
        try insert.bind(14, now)
        _ = try insert.step()

        let armInsert = try database.prepare("""
            INSERT INTO token_saver_run_arm_receipts(
                run_id, format, source_bound, producer_id, producer_revision,
                abi_revision, generation, structural, semantic, recovery,
                projection, availability, eligible, proven_effective_count
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """)
        for arm in record.arms {
            armInsert.reset()
            try armInsert.bind(1, arm.runId)
            try armInsert.bind(2, arm.format.rawValue)
            try armInsert.bind(3, Int64(arm.sourceBound ? 1 : 0))
            try armInsert.bind(4, arm.producerId)
            try armInsert.bind(5, arm.producerRevision)
            try armInsert.bind(6, arm.abiRevision)
            try armInsert.bind(7, arm.generation.rawValue)
            try armInsert.bind(8, arm.structural.rawValue)
            try armInsert.bind(9, arm.semantic.rawValue)
            try armInsert.bind(10, arm.recovery.rawValue)
            try armInsert.bind(11, arm.projection.rawValue)
            try armInsert.bind(12, arm.availability.rawValue)
            try armInsert.bind(13, Int64(arm.eligible ? 1 : 0))
            if let count = arm.provenEffectiveCount {
                try armInsert.bind(14, Int64(count))
            } else {
                try armInsert.bind(14, Optional<Int64>.none)
            }
            _ = try armInsert.step()
        }
    }

    private static func loadRecord(
        runId: String,
        database: SQLiteDB
    ) throws -> TokenSaverRequestSelectionReceipt.Record? {
        let winnerSQL = try database.prepare("""
            SELECT run_id, thread_id, provider, resolved_model, selected_format, reason,
                   modeled_context_delta, counter_id, counter_revision, encoding,
                   counter_status, lifecycle, billing_claim, created_at, updated_at
            FROM token_saver_run_winner_receipts
            WHERE run_id = ?
            LIMIT 1;
            """)
        try winnerSQL.bind(1, runId)
        guard try winnerSQL.step() else { return nil }
        guard let selected = TokenSaverRequestSelectionReceipt.SelectedFormat(
            rawValue: winnerSQL.columnText(4) ?? ""
        ),
              let reason = TokenSaverBestOfThreeSelector.Reason(rawValue: winnerSQL.columnText(5) ?? ""),
              let counterStatus = TokenSaverRequestSelectionReceipt.CounterStatus(
                rawValue: winnerSQL.columnText(10) ?? ""
              ),
              let lifecycle = TokenSaverRequestSelectionReceipt.Lifecycle(
                rawValue: winnerSQL.columnText(11) ?? ""
              ) else {
            return nil
        }
        let winner = TokenSaverRequestSelectionReceipt.Winner(
            runId: winnerSQL.columnText(0) ?? runId,
            threadId: winnerSQL.columnText(1) ?? "",
            provider: winnerSQL.columnText(2) ?? "",
            resolvedModel: winnerSQL.columnText(3) ?? "",
            selectedFormat: selected,
            reason: reason,
            modeledContextDelta: Int(winnerSQL.columnInt64(6)),
            counterId: winnerSQL.columnIsNull(7) ? nil : winnerSQL.columnText(7),
            counterRevision: winnerSQL.columnIsNull(8) ? nil : winnerSQL.columnText(8),
            encoding: winnerSQL.columnIsNull(9) ? nil : winnerSQL.columnText(9),
            counterStatus: counterStatus,
            lifecycle: lifecycle,
            billingClaim: false,
            createdAt: winnerSQL.columnText(13),
            updatedAt: winnerSQL.columnText(14)
        )
        let armsSQL = try database.prepare("""
            SELECT run_id, format, source_bound, producer_id, producer_revision,
                   abi_revision, generation, structural, semantic, recovery,
                   projection, availability, eligible, proven_effective_count
            FROM token_saver_run_arm_receipts
            WHERE run_id = ?
            ORDER BY format ASC;
            """)
        try armsSQL.bind(1, runId)
        var arms: [TokenSaverRequestSelectionReceipt.Arm] = []
        while try armsSQL.step() {
            guard let format = TokenSaverBestOfThreeSelector.Format(rawValue: armsSQL.columnText(1) ?? ""),
                  let generation = TokenSaverBestOfThreeSelector.GateStatus(rawValue: armsSQL.columnText(6) ?? ""),
                  let structural = TokenSaverBestOfThreeSelector.GateStatus(rawValue: armsSQL.columnText(7) ?? ""),
                  let semantic = TokenSaverBestOfThreeSelector.GateStatus(rawValue: armsSQL.columnText(8) ?? ""),
                  let recovery = TokenSaverBestOfThreeSelector.GateStatus(rawValue: armsSQL.columnText(9) ?? ""),
                  let projection = TokenSaverRequestSelectionReceipt.ProjectionStatus(
                    rawValue: armsSQL.columnText(10) ?? ""
                  ),
                  let availability = TokenSaverRequestSelectionReceipt.AvailabilityStatus(
                    rawValue: armsSQL.columnText(11) ?? ""
                  ) else {
                continue
            }
            arms.append(TokenSaverRequestSelectionReceipt.Arm(
                runId: armsSQL.columnText(0) ?? runId,
                format: format,
                sourceBound: armsSQL.columnInt64(2) != 0,
                producerId: armsSQL.columnText(3) ?? "",
                producerRevision: armsSQL.columnText(4) ?? "",
                abiRevision: armsSQL.columnText(5) ?? "",
                generation: generation,
                structural: structural,
                semantic: semantic,
                recovery: recovery,
                projection: projection,
                availability: availability,
                eligible: armsSQL.columnInt64(12) != 0,
                provenEffectiveCount: armsSQL.columnIsNull(13) ? nil : Int(armsSQL.columnInt64(13))
            ))
        }
        return TokenSaverRequestSelectionReceipt.Record(winner: winner, arms: arms)
    }
}

public extension AgentRunRepository {
    func selectionReceipts() -> TokenSaverRequestSelectionReceiptRepository {
        TokenSaverRequestSelectionReceiptRepository(db: db)
    }
}
