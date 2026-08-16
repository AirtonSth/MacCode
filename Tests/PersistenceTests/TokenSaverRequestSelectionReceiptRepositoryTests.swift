import CryptoKit
import SQLite3
import XCTest
@testable import CoreModel
@testable import Persistence

/// Durable C10 request-selection receipts: content-free rows, all three arms,
/// honest identity/lifecycle, and independence from savings / message prune.
final class TokenSaverRequestSelectionReceiptRepositoryTests: XCTestCase {
    private let human = "C10 Human canonical prompt."
    private let rcw1Handle = "rcv1.c10"
    private let rcs1Handle = "rcs1.c10"

    private func makeDB() throws -> SQLiteDB {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        return db
    }

    private func seedParents(_ db: SQLiteDB) throws -> (thread: AgentThread, run: AgentRun) {
        let thread = AgentThread(title: "c10-receipts", provider: .codex, model: "gpt-test")
        try AgentThreadRepository(db: db).upsert(thread)
        let run = AgentRun(
            threadId: thread.id,
            provider: .codex,
            model: "gpt-test",
            status: .pending
        )
        return (thread, run)
    }

    func test_realSelectorDecisionsProjectExactlyThreeArmsWithoutForbiddenContent() async throws {
        let db = try makeDB()
        let repo = TokenSaverRequestSelectionReceiptRepository(db: db)
        let rcw1 = try await persistRealDecision(db: db, repo: repo, winner: .rcw1)
        let humanWin = try await persistRealDecision(db: db, repo: repo, winner: .human)

        for record in [rcw1.record, humanWin.record] {
            XCTAssertEqual(record.arms.map(\.format), TokenSaverBestOfThreeSelector.Format.allCases)
            XCTAssertEqual(record.arms.count, 3)
            XCTAssertTrue(
                record.winner.selectedFormat == .human
                    || record.winner.selectedFormat == .rcw1
                    || record.winner.selectedFormat == .rcs1
            )
            XCTAssertFalse(record.winner.billingClaim)
            let rcs1 = try XCTUnwrap(record.arm(.rcs1))
            XCTAssertEqual(rcs1.producerId, TokenSaverRequestSelectionReceipt.rcs1ProducerID)
            XCTAssertEqual(rcs1.availability, .available)
            XCTAssertTrue(rcs1.sourceBound)
            XCTAssertEqual(rcs1.generation, .passed)
            XCTAssertEqual(rcs1.structural, .passed)
            XCTAssertEqual(rcs1.semantic, .passed)
            XCTAssertEqual(rcs1.recovery, .passed)
            XCTAssertTrue(rcs1.eligible)
            XCTAssertNotNil(rcs1.provenEffectiveCount)
        }

        XCTAssertEqual(rcw1.record.winner.selectedFormat, .rcw1)
        XCTAssertEqual(humanWin.record.winner.selectedFormat, .human)
        XCTAssertEqual(try XCTUnwrap(rcw1.record.arm(.rcw1)).provenEffectiveCount, 40)
        XCTAssertEqual(try XCTUnwrap(humanWin.record.arm(.human)).provenEffectiveCount, 50)

        let report = try repo.report()
        XCTAssertEqual(report.records.count, 2)
        XCTAssertTrue(report.records.contains { $0.winner.lifecycle == .provisional })
        XCTAssertTrue(report.records.contains { $0.winner.selectedFormat == .human })
        XCTAssertTrue(report.records.allSatisfy {
            $0.arm(.human) != nil && $0.arm(.rcw1) != nil && $0.arm(.rcs1) != nil
        })
        let encoded = String(
            data: try TokenSaverRequestSelectionReceipt.encodeReport(report),
            encoding: .utf8
        )
        XCTAssertTrue(try XCTUnwrap(encoded).contains("\"human\""))
        XCTAssertTrue(try XCTUnwrap(encoded).contains("\"rcw1\""))
        XCTAssertTrue(try XCTUnwrap(encoded).contains("\"rcs1\""))
        assertNoForbiddenContent(
            db: db,
            report: report,
            secrets: [
                human,
                rcw1Payload,
                rcs1Payload,
                "RCW1 ABI",
                "RCS1 ABI",
                rcw1Handle,
                rcs1Handle,
                "selectedPayload",
                "sourceSHA256",
                "DecisionReceipt",
                "licensed",
                rcw1.decision.sourceSHA256,
            ]
        )
        XCTAssertEqual(try scalar(db, "SELECT COUNT(*) FROM token_saver_savings;"), 0)
    }

    func test_rcs1SelectorWinnerIsPersistedAsSelectedFormatWithoutCoercion() async throws {
        let db = try makeDB()
        let repo = TokenSaverRequestSelectionReceiptRepository(db: db)
        let persisted = try await persistRealDecision(db: db, repo: repo, winner: .rcs1)
        XCTAssertEqual(persisted.decision.selectedFormat, .rcs1)
        XCTAssertEqual(persisted.record.winner.selectedFormat, .rcs1)
        XCTAssertEqual(persisted.record.winner.reason, .uniqueStrictMinimum)
        XCTAssertEqual(persisted.record.winner.modeledContextDelta, 70)
        XCTAssertFalse(persisted.record.winner.billingClaim)
        let rcs1 = try XCTUnwrap(persisted.record.arm(.rcs1))
        XCTAssertEqual(rcs1.producerId, TokenSaverRequestSelectionReceipt.rcs1ProducerID)
        XCTAssertEqual(rcs1.availability, .available)
        XCTAssertTrue(rcs1.eligible)
        XCTAssertEqual(rcs1.provenEffectiveCount, 30)
        XCTAssertEqual(rcs1.generation, .passed)
        XCTAssertEqual(rcs1.structural, .passed)
        XCTAssertEqual(rcs1.semantic, .passed)
        XCTAssertEqual(rcs1.recovery, .passed)
    }

    func test_rcs1WinnerLifecycleAndContentFreeJSON() async throws {
        let db = try makeDB()
        let repo = TokenSaverRequestSelectionReceiptRepository(db: db)
        let persisted = try await persistRealDecision(db: db, repo: repo, winner: .rcs1)
        XCTAssertEqual(persisted.record.winner.lifecycle, .provisional)
        try repo.acknowledgeBatch([
            TokenSaverRequestSelectionLifecycleAck(
                runId: persisted.run.id.value.uuidString,
                lifecycle: .delivered
            )
        ])
        XCTAssertEqual(try repo.load(runId: persisted.run.id)?.winner.lifecycle, .delivered)

        let notDelivered = try await persistRealDecision(db: db, repo: repo, winner: .rcs1)
        try repo.acknowledgeBatch([
            TokenSaverRequestSelectionLifecycleAck(
                runId: notDelivered.run.id.value.uuidString,
                lifecycle: .notDelivered
            )
        ])
        XCTAssertEqual(try repo.load(runId: notDelivered.run.id)?.winner.lifecycle, .notDelivered)

        let unknown = try await persistRealDecision(db: db, repo: repo, winner: .rcs1)
        try repo.acknowledgeBatch([
            TokenSaverRequestSelectionLifecycleAck(
                runId: unknown.run.id.value.uuidString,
                lifecycle: .deliveryUnknown
            )
        ])
        XCTAssertEqual(try repo.load(runId: unknown.run.id)?.winner.lifecycle, .deliveryUnknown)

        let report = try repo.report()
        let encoded = String(
            data: try TokenSaverRequestSelectionReceipt.encodeReport(report),
            encoding: .utf8
        )
        let json = try XCTUnwrap(encoded)
        XCTAssertTrue(json.contains("\"rcs1\""))
        XCTAssertFalse(json.contains(human))
        XCTAssertFalse(json.contains(rcs1Payload))
        XCTAssertFalse(json.contains("RCS1 ABI"))
        XCTAssertFalse(json.contains("selectedPayload"))
        XCTAssertTrue(report.records.allSatisfy { !$0.winner.billingClaim })
    }

    func test_billingClaimIsForcedZeroRegardlessOfCallerInput() async throws {
        let db = try makeDB()
        let repo = TokenSaverRequestSelectionReceiptRepository(db: db)
        let parents = try seedParents(db)
        var record = TokenSaverRequestSelectionReceipt.project(
            decision: await realDecision(.human),
            runId: parents.run.id.value.uuidString,
            threadId: parents.thread.id.value.uuidString,
            provider: "codex",
            resolvedModel: "gpt-test"
        )
        record = record.withBillingClaimForTest(true)
        try repo.persistPendingRun(parents.run, record: record)
        let stored = try XCTUnwrap(repo.load(runId: parents.run.id))
        XCTAssertFalse(stored.winner.billingClaim)
        XCTAssertEqual(
            try scalar(db, "SELECT billing_claim FROM token_saver_run_winner_receipts WHERE run_id = '\(parents.run.id.value.uuidString)';"),
            0
        )
    }

    func test_atomicRunWinnerArmsRollbackWhenLaterArmInsertFails() async throws {
        let db = try makeDB()
        let repo = TokenSaverRequestSelectionReceiptRepository(db: db)
        let parents = try seedParents(db)
        try db.execute("""
            CREATE TRIGGER fail_third_receipt_arm
            BEFORE INSERT ON token_saver_run_arm_receipts
            WHEN NEW.format = 'rcs1'
            BEGIN
                SELECT RAISE(ABORT, 'injected third-arm failure');
            END;
            """)
        let record = TokenSaverRequestSelectionReceipt.project(
            decision: await realDecision(.rcw1),
            runId: parents.run.id.value.uuidString,
            threadId: parents.thread.id.value.uuidString,
            provider: "codex",
            resolvedModel: "gpt-test"
        )
        XCTAssertThrowsError(try repo.persistPendingRun(parents.run, record: record))
        XCTAssertNil(try AgentRunRepository(db: db).get(id: parents.run.id))
        XCTAssertEqual(try rowCount(db, "token_saver_run_winner_receipts"), 0)
        XCTAssertEqual(try rowCount(db, "token_saver_run_arm_receipts"), 0)
    }

    func test_identicalRetrySucceedsAndMutatedIdentityThrowsWithoutMutation() async throws {
        let db = try makeDB()
        let repo = TokenSaverRequestSelectionReceiptRepository(db: db)
        let first = try await persistRealDecision(db: db, repo: repo, winner: .rcw1)
        XCTAssertNoThrow(try repo.persistPendingRun(first.run, record: first.record))
        let afterSame = try XCTUnwrap(repo.load(runId: first.run.id))
        XCTAssertEqual(afterSame.winner.reason, first.record.winner.reason)
        XCTAssertEqual(afterSame.winner.lifecycle, .provisional)

        var mutated = first.record
        mutated = mutated.withReasonForTest(.tie)
        XCTAssertThrowsError(try repo.persistPendingRun(first.run, record: mutated)) { error in
            guard case TokenSaverRequestSelectionReceiptError.identityMismatch = error else {
                return XCTFail("expected identity mismatch, got \(error)")
            }
        }
        let unchanged = try XCTUnwrap(repo.load(runId: first.run.id))
        XCTAssertEqual(unchanged.winner.reason, first.record.winner.reason)
        XCTAssertEqual(unchanged.winner.lifecycle, .provisional)
        XCTAssertEqual(unchanged.arms, first.record.arms)
    }

    func test_notDeliveredRetryReopensProvisionalOnlyForByteEqualIdentity() async throws {
        let db = try makeDB()
        let repo = TokenSaverRequestSelectionReceiptRepository(db: db)
        let first = try await persistRealDecision(db: db, repo: repo, winner: .human)
        try repo.acknowledgeBatch([
            TokenSaverRequestSelectionLifecycleAck(
                runId: first.run.id.value.uuidString,
                lifecycle: .notDelivered
            )
        ])
        try repo.persistPendingRun(first.run, record: first.record)
        XCTAssertEqual(try repo.load(runId: first.run.id)?.winner.lifecycle, .provisional)

        try repo.acknowledgeBatch([
            TokenSaverRequestSelectionLifecycleAck(
                runId: first.run.id.value.uuidString,
                lifecycle: .delivered
            )
        ])
        XCTAssertNoThrow(try repo.persistPendingRun(first.run, record: first.record))
        XCTAssertEqual(try repo.load(runId: first.run.id)?.winner.lifecycle, .delivered)
    }

    func test_batchAckRollsBackWhenALaterRowIsMissingOrIllegal() async throws {
        let db = try makeDB()
        let repo = TokenSaverRequestSelectionReceiptRepository(db: db)
        let first = try await persistRealDecision(db: db, repo: repo, winner: .human)
        let second = try await persistRealDecision(db: db, repo: repo, winner: .rcw1)
        XCTAssertThrowsError(try repo.acknowledgeBatch([
            TokenSaverRequestSelectionLifecycleAck(
                runId: first.run.id.value.uuidString,
                lifecycle: .delivered
            ),
            TokenSaverRequestSelectionLifecycleAck(
                runId: UUID().uuidString,
                lifecycle: .delivered
            )
        ]))
        XCTAssertEqual(try repo.load(runId: first.run.id)?.winner.lifecycle, .provisional)
        XCTAssertEqual(try repo.load(runId: second.run.id)?.winner.lifecycle, .provisional)

        try repo.acknowledgeBatch([
            TokenSaverRequestSelectionLifecycleAck(
                runId: second.run.id.value.uuidString,
                lifecycle: .delivered
            )
        ])
        XCTAssertThrowsError(try repo.acknowledgeBatch([
            TokenSaverRequestSelectionLifecycleAck(
                runId: first.run.id.value.uuidString,
                lifecycle: .notDelivered
            ),
            TokenSaverRequestSelectionLifecycleAck(
                runId: second.run.id.value.uuidString,
                lifecycle: .notDelivered
            )
        ]))
        XCTAssertEqual(try repo.load(runId: first.run.id)?.winner.lifecycle, .provisional)
        XCTAssertEqual(try repo.load(runId: second.run.id)?.winner.lifecycle, .delivered)
        try repo.acknowledgeBatch([
            TokenSaverRequestSelectionLifecycleAck(
                runId: second.run.id.value.uuidString,
                lifecycle: .delivered
            )
        ])
        XCTAssertEqual(try repo.load(runId: second.run.id)?.winner.lifecycle, .delivered)
    }

    func test_relaunchSweepMovesOnlyProvisionalToDeliveryUnknown() async throws {
        let db = try makeDB()
        let repo = TokenSaverRequestSelectionReceiptRepository(db: db)
        let leftover = try await persistRealDecision(db: db, repo: repo, winner: .human)
        let delivered = try await persistRealDecision(db: db, repo: repo, winner: .rcw1)
        try repo.acknowledgeBatch([
            TokenSaverRequestSelectionLifecycleAck(
                runId: delivered.run.id.value.uuidString,
                lifecycle: .delivered
            )
        ])
        XCTAssertEqual(try repo.reconcileProvisionalOnRelaunch(), 1)
        XCTAssertEqual(try repo.load(runId: leftover.run.id)?.winner.lifecycle, .deliveryUnknown)
        XCTAssertEqual(try repo.load(runId: delivered.run.id)?.winner.lifecycle, .delivered)
        XCTAssertEqual(try repo.reconcileProvisionalOnRelaunch(), 0)
    }

    func test_reportIncludesEveryLifecycleAndHumanFallbackByDefault() async throws {
        let db = try makeDB()
        let repo = TokenSaverRequestSelectionReceiptRepository(db: db)
        let humanRow = try await persistRealDecision(db: db, repo: repo, winner: .human)
        let rcw1Row = try await persistRealDecision(db: db, repo: repo, winner: .rcw1)
        let unknown = try await persistRealDecision(db: db, repo: repo, winner: .human)
        try repo.acknowledgeBatch([
            TokenSaverRequestSelectionLifecycleAck(
                runId: rcw1Row.run.id.value.uuidString,
                lifecycle: .delivered
            ),
            TokenSaverRequestSelectionLifecycleAck(
                runId: unknown.run.id.value.uuidString,
                lifecycle: .deliveryUnknown
            )
        ])
        let report = try repo.report()
        XCTAssertEqual(report.records.count, 3)
        let lifecycles = Set(report.records.map(\.winner.lifecycle))
        XCTAssertEqual(lifecycles, [.provisional, .delivered, .deliveryUnknown])
        XCTAssertTrue(report.records.contains { $0.winner.runId == humanRow.run.id.value.uuidString })
        XCTAssertTrue(report.records.allSatisfy { $0.arm(.human) != nil })
    }

    func test_snapshotRestoreCascadeAndMessagePruneLeaveRunOwnedReceipts() async throws {
        let db = try makeDB()
        let repo = TokenSaverRequestSelectionReceiptRepository(db: db)
        let persisted = try await persistRealDecision(db: db, repo: repo, winner: .rcw1)
        let messages = AgentMessageRepository(db: db)
        for index in 0..<(AgentMessageRepository.maxMessagesPerThread + 5) {
            try messages.append(AgentMessage(
                threadId: persisted.thread.id,
                role: .user,
                content: "prune-\(index)"
            ))
        }
        try messages.pruneMessagesKeepingLatest(threadId: persisted.thread.id)
        XCTAssertNotNil(try repo.load(runId: persisted.run.id),
                        "message prune must not delete run-owned receipts")

        let threads = AgentThreadRepository(db: db)
        let snapshot = try threads.deleteWithRelationalSnapshot(ids: [persisted.thread.id])
        XCTAssertNil(try repo.load(runId: persisted.run.id))
        XCTAssertEqual(try rowCount(db, "token_saver_run_winner_receipts"), 0)
        XCTAssertEqual(try rowCount(db, "token_saver_run_arm_receipts"), 0)
        let names = snapshot.tables.map(\.name)
        let runIndex = try XCTUnwrap(names.firstIndex(of: "agent_runs"))
        let winnerIndex = try XCTUnwrap(names.firstIndex(of: "token_saver_run_winner_receipts"))
        let armIndex = try XCTUnwrap(names.firstIndex(of: "token_saver_run_arm_receipts"))
        XCTAssertLessThan(runIndex, winnerIndex)
        XCTAssertLessThan(winnerIndex, armIndex)
        try threads.restore(snapshot)
        let restored = try XCTUnwrap(repo.load(runId: persisted.run.id))
        XCTAssertEqual(restored.winner.selectedFormat, .rcw1)
        XCTAssertEqual(restored.arms.count, 3)

        let rcs1Persisted = try await persistRealDecision(db: db, repo: repo, winner: .rcs1)
        let rcs1Snapshot = try threads.deleteWithRelationalSnapshot(ids: [rcs1Persisted.thread.id])
        XCTAssertNil(try repo.load(runId: rcs1Persisted.run.id))
        try threads.restore(rcs1Snapshot)
        let restoredRCS1 = try XCTUnwrap(repo.load(runId: rcs1Persisted.run.id))
        XCTAssertEqual(restoredRCS1.winner.selectedFormat, .rcs1)
        XCTAssertEqual(restoredRCS1.winner.reason, .uniqueStrictMinimum)
        XCTAssertFalse(restoredRCS1.winner.billingClaim)
        XCTAssertEqual(restoredRCS1.arms.count, 3)

        try threads.deleteWithRelationalSnapshot(ids: [persisted.thread.id, rcs1Persisted.thread.id])
        XCTAssertEqual(try rowCount(db, "token_saver_run_winner_receipts"), 0)
        XCTAssertEqual(try rowCount(db, "token_saver_run_arm_receipts"), 0)
    }

    func test_exactCounterIdentityIsPersistedOnlyForExactStatuses() async throws {
        let db = try makeDB()
        let repo = TokenSaverRequestSelectionReceiptRepository(db: db)
        let exact = try await persistRealDecision(db: db, repo: repo, winner: .rcw1)
        XCTAssertEqual(exact.record.winner.counterStatus, .exactLocalTokenizer)
        XCTAssertEqual(exact.record.winner.counterId, "fixture-counter")
        XCTAssertEqual(exact.record.winner.counterRevision, "1")
        XCTAssertEqual(exact.record.winner.encoding, "fixture-exact")

        let parents = try seedParents(db)
        let missing = await TokenSaverBestOfThreeSelector.select(
            canonicalHuman: human,
            humanOutboundPrompt: human,
            humanEffectiveEnvelope: human,
            target: target,
            candidates: [candidate(.rcw1), candidate(.rcs1)],
            counter: nil
        )
        let record = TokenSaverRequestSelectionReceipt.project(
            decision: missing,
            runId: parents.run.id.value.uuidString,
            threadId: parents.thread.id.value.uuidString,
            provider: "codex",
            resolvedModel: "gpt-test"
        )
        try repo.persistPendingRun(parents.run, record: record)
        let stored = try XCTUnwrap(repo.load(runId: parents.run.id))
        XCTAssertEqual(stored.winner.counterStatus, .unavailable)
        XCTAssertNil(stored.winner.counterId)
        XCTAssertNil(stored.winner.counterRevision)
        XCTAssertNil(stored.winner.encoding)
    }

    // MARK: - Fixtures

    private enum Winner { case human, rcw1, rcs1 }

    private struct Persisted {
        let thread: AgentThread
        let run: AgentRun
        let decision: TokenSaverBestOfThreeSelector.Decision
        let record: TokenSaverRequestSelectionReceipt.Record
    }

    private func persistRealDecision(
        db: SQLiteDB,
        repo: TokenSaverRequestSelectionReceiptRepository,
        winner: Winner
    ) async throws -> Persisted {
        let thread = AgentThread(title: "c10-\(winner)", provider: .codex, model: "gpt-test")
        try AgentThreadRepository(db: db).upsert(thread)
        let run = AgentRun(threadId: thread.id, provider: .codex, model: "gpt-test", status: .pending)
        let decision = await realDecision(winner)
        let record = TokenSaverRequestSelectionReceipt.project(
            decision: decision,
            runId: run.id.value.uuidString,
            threadId: thread.id.value.uuidString,
            provider: "codex",
            resolvedModel: "gpt-test"
        )
        try repo.persistPendingRun(run, record: record)
        return Persisted(
            thread: thread,
            run: run,
            decision: decision,
            record: try XCTUnwrap(repo.load(runId: run.id))
        )
    }

    private var rcw1Payload: String { "RCW1 candidate [[rc:\(rcw1Handle)]]" }
    private var rcs1Payload: String { "RCS1 candidate [[rc:\(rcs1Handle)]]" }

    private func realDecision(_ winner: Winner) async -> TokenSaverBestOfThreeSelector.Decision {
        let rcw1 = candidate(.rcw1)
        let rcs1 = candidate(.rcs1)
        let envelopes: (Int, Int, Int)
        switch winner {
        case .rcw1: envelopes = (100, 40, 80)
        case .rcs1: envelopes = (100, 80, 30)
        case .human: envelopes = (50, 70, 75)
        }
        var counts = [human: envelopes.0]
        counts[rcw1.payload] = 20
        counts[rcw1.handle!] = 7
        counts[rcw1.abi] = 10
        counts[rcw1.effectiveEnvelope] = envelopes.1
        counts[rcs1.payload] = 20
        counts[rcs1.handle!] = 6
        counts[rcs1.abi] = 10
        counts[rcs1.effectiveEnvelope] = envelopes.2
        return await TokenSaverBestOfThreeSelector.select(
            canonicalHuman: human,
            humanOutboundPrompt: human,
            humanEffectiveEnvelope: human,
            target: target,
            candidates: [rcw1, rcs1],
            counter: .init(counter: .init(
                id: "fixture-counter",
                revision: "1",
                encoding: "fixture-exact",
                provider: "codex",
                resolvedModel: "gpt-test",
                quality: .exactLocalTokenizer
            )) { text in
                guard let value = counts[text] else { throw NSError(domain: "counter", code: 1) }
                return value
            }
        )
    }

    private func candidate(_ format: TokenSaverBestOfThreeSelector.Format) -> TokenSaverBestOfThreeSelector.Candidate {
        let payload = format == .rcw1 ? rcw1Payload : rcs1Payload
        let abi = format == .rcw1 ? "RCW1 ABI" : "RCS1 ABI"
        return .init(
            format: format,
            sourceSHA256: sha256(human),
            payload: payload,
            abi: abi,
            effectiveEnvelope: "SYSTEM:\(abi)\nUSER:\(payload)",
            handle: format == .rcw1 ? rcw1Handle : rcs1Handle,
            producerID: format == .rcw1 ? "remotecode-rcw1" : "remotecode-rcs1",
            producerRevision: "fixture-1",
            abiRevision: "fixture-abi-1",
            generation: .passed,
            structural: .passed,
            semantic: .passed,
            recovery: .passed
        )
    }

    private var target: TokenSaverBestOfThreeSelector.Target {
        .init(
            provider: "codex",
            resolvedModel: "gpt-test",
            counterID: "fixture-counter",
            counterRevision: "1",
            encoding: "fixture-exact"
        )
    }

    private func assertNoForbiddenContent(
        db: SQLiteDB,
        report: TokenSaverRequestSelectionReceipt.Report,
        secrets: [String]
    ) {
        var blobs: [String] = []
        for table in ["token_saver_run_winner_receipts", "token_saver_run_arm_receipts"] {
            let statement = try? db.prepare("SELECT * FROM \(table);")
            while (try? statement?.step()) == true {
                let count = Int(sqlite3_column_count(statement!.handle))
                for index in 0..<count {
                    let name = String(cString: sqlite3_column_name(statement!.handle, Int32(index)))
                    blobs.append(name)
                    if let text = statement?.columnText(Int32(index)) {
                        blobs.append(text)
                    }
                }
            }
        }
        if let encoded = try? TokenSaverRequestSelectionReceipt.encodeReport(report),
           let json = String(data: encoded, encoding: .utf8) {
            blobs.append(json)
        }
        let haystack = blobs.joined(separator: "\n")
        for secret in secrets where !secret.isEmpty {
            XCTAssertFalse(haystack.contains(secret), "forbidden content leaked: \(secret)")
        }
        XCTAssertFalse(haystack.contains("payloadSHA256"))
        XCTAssertFalse(haystack.contains("handleSHA256"))
        XCTAssertFalse(haystack.contains("abiSHA256"))
        XCTAssertFalse(haystack.contains("effectiveEnvelopeSHA256"))
        XCTAssertFalse(haystack.contains("selectedPayload"))
    }

    private func rowCount(_ db: SQLiteDB, _ table: String) throws -> Int {
        try scalar(db, "SELECT COUNT(*) FROM \(table);")
    }

    private func scalar(_ db: SQLiteDB, _ sql: String) throws -> Int {
        let statement = try db.prepare(sql)
        defer { statement.reset() }
        guard try statement.step() else { return 0 }
        return Int(statement.columnInt64(0))
    }

    private func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
