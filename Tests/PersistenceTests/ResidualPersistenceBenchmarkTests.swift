import XCTest
import CoreModel
@testable import Persistence

/// Opt-in, same-process A/B receipts for the three residual Persistence seams.
///
/// The legacy switches execute the exact pre-change branches inside the same
/// production methods as current. Fixture creation and semantic readback stay
/// outside the timer; each measured pair alternates AB/BA order to reduce drift.
final class ResidualPersistenceBenchmarkTests: XCTestCase {
    private static let warmupCount = 2
    private static let sampleCount = 7

    private struct TimedOperation {
        let run: () throws -> Void
        let signature: () throws -> String
        let cleanup: () -> Void
    }

    private struct Measurement {
        let milliseconds: Double
        let signature: String
    }

    private struct BenchmarkRecord: Codable {
        let id: String
        let warmups: Int
        let samples: Int
        let beforeRawMilliseconds: [Double]
        let afterRawMilliseconds: [Double]
        let beforeMedianMilliseconds: Double
        let afterMedianMilliseconds: Double
        let improvementPercent: Double
        let semanticEquivalence: Bool
        let comparisonOrder: String
        let fixture: String
    }

    private enum HarnessError: Error {
        case missingAbsoluteAppSupport
        case missingRow(String)
        case invalidStoredJSON(String)
    }

    func test_streamHostMetadata_exactLegacyVsCurrent() throws {
        try requireOptIn()
        let batches = (0..<64).map { batch in
            (0..<16).map { offset in
                let seq = batch * 16 + offset + 1
                return AgentRunRepository.StreamWriteIntent(
                    seq: seq,
                    kind: "itemDelta(i1)",
                    payloadJSON: #"{"itemDelta":{"itemId":"i1","seq":\#(seq)}}"#,
                    providerEvent: nil
                )
            }
        }
        try runBenchmark(
            id: "persist-stream-host-metadata-discriminator",
            fixture: "64 persistStreamBatch calls x 16 ordinary rows; in-memory SQLite; retention disabled",
            legacyFactory: { try self.makeStreamOperation(batches: batches, legacy: true) },
            currentFactory: { try self.makeStreamOperation(batches: batches, legacy: false) }
        )
    }

    func test_checkpointSummary_exactLegacyVsCurrent() throws {
        try requireOptIn()
        let segment = String(repeating: "quote-\"-slash-\\-emoji-🙂-", count: 10)
        let files = (0..<200).map {
            AgentTurnCheckpointFile(
                path: "Sources/\(segment)\($0).swift",
                kind: "modified",
                additions: $0,
                deletions: $0 / 2
            )
        }
        try runBenchmark(
            id: "checkpoint-summary-linear-encoding",
            fixture: "200 upserts of one checkpoint carrying the same 200-file authoritative array; in-memory SQLite",
            legacyFactory: { try self.makeCheckpointOperation(files: files, legacy: true) },
            currentFactory: { try self.makeCheckpointOperation(files: files, legacy: false) }
        )
    }

    func test_botRemoteSidecarFormatter_exactLegacyVsCurrent() throws {
        try requireOptIn()
        let supportRoot = try absoluteAppSupportRoot()
        try runBenchmark(
            id: "bot-remote-sidecar-formatter-reuse",
            fixture: "40 bot.settings.set dispatches x 3 durable sidecar rows; in-memory SQLite",
            legacyFactory: { try self.makeBotRemoteOperation(supportRoot: supportRoot, legacy: true) },
            currentFactory: { try self.makeBotRemoteOperation(supportRoot: supportRoot, legacy: false) }
        )
    }

    // MARK: - Bot sidecar write counts (always run: counts, not timings)

    /// WHY: a Bot mutation (send, pin, select a conversation) answers the phone
    /// only after its sidecar persist, and the production database commits with
    /// full fsync. Rewriting all 17 sidecar rows as 17 commits made every ack
    /// wait on 17 durable commits. A mutation must commit once and write only
    /// the rows it changed, and a relaunch must still read back exactly what
    /// the phone was told.
    func test_botRemoteSidecar_mutationCommitsOnlyItsChangedRowsOnce() throws {
        let fixture = try makeSidecarFixture()
        defer { try? FileManager.default.removeItem(at: fixture.support) }
        let created = try fixture.authority.dispatch(method: "bot.create", params: [
            "client_request_id": "sidecar-count-create", "name": "Sidecar",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)

        let counter = SidecarWriteCounter()
        counter.attach(to: fixture.db)
        let pinned = try fixture.authority.dispatch(method: "bot.set_pinned", params: [
            "client_request_id": "sidecar-count-pin", "bot_id": botID, "pinned": true,
        ])
        XCTAssertEqual(counter.commits, 1, "bot.set_pinned must persist its sidecar rows in one commit")
        XCTAssertGreaterThanOrEqual(counter.rowWrites, 1, "the mutation's own receipt must be persisted")
        XCTAssertLessThanOrEqual(counter.rowWrites, 3, "bot.set_pinned must not rewrite sidecar rows it did not change")

        counter.reset()
        let conversation = try fixture.authority.dispatch(method: "bot.conversation.create", params: [
            "client_request_id": "sidecar-count-conversation", "bot_id": botID, "title": "Counted",
        ])
        XCTAssertEqual(counter.commits, 1, "bot.conversation.create must persist its sidecar rows in one commit")
        XCTAssertGreaterThanOrEqual(counter.rowWrites, 1, "the mutation's own receipt must be persisted")
        XCTAssertLessThanOrEqual(counter.rowWrites, 3, "bot.conversation.create must not rewrite sidecar rows it did not change")
        counter.detach(from: fixture.db)

        let relaunched = BotRemoteControlAuthority(
            db: fixture.db,
            store: fixture.store,
            settings: fixture.settings,
            appSupportDirectory: fixture.support
        )
        for receipt in [pinned, conversation] {
            let requestID = try XCTUnwrap(receipt["request_id"] as? String)
            let replayed = try relaunched.dispatch(method: "bot.receipt.status", params: [
                "client_request_id": requestID,
            ])
            XCTAssertEqual(
                replayed as NSDictionary,
                receipt as NSDictionary,
                "\(requestID) must replay after relaunch exactly as it was answered"
            )
        }
        let conversationID = try XCTUnwrap(
            (conversation["readback"] as? [String: Any])?["conversation_id"] as? String
        )
        let listed = try relaunched.dispatch(method: "bot.conversation.list", params: ["bot_id": botID])
        XCTAssertEqual(
            listed["selected_id"] as? String,
            conversationID,
            "a row written by an earlier mutation must survive later mutations that skipped it"
        )
    }

    /// WHY: writing only changed rows must never turn a failed write into a
    /// lost one. A row SQLite rejected has to travel with the next mutation,
    /// still in one commit, even though that mutation did not touch it; and
    /// one rejected row must not take the mutation's receipt down with it.
    func test_botRemoteSidecar_rejectedRowIsWrittenAgainByNextMutation() throws {
        let fixture = try makeSidecarFixture()
        defer { try? FileManager.default.removeItem(at: fixture.support) }
        let created = try fixture.authority.dispatch(method: "bot.create", params: [
            "client_request_id": "sidecar-retry-create", "name": "Sidecar",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        try fixture.db.execute("""
            CREATE TRIGGER fail_selection_sidecar
            BEFORE UPDATE ON settings
            WHEN OLD.key = 'bot.remote.selected_conversations'
            BEGIN SELECT RAISE(ABORT, 'injected selection sidecar failure'); END;
            """)
        let conversation = try fixture.authority.dispatch(method: "bot.conversation.create", params: [
            "client_request_id": "sidecar-retry-conversation", "bot_id": botID, "title": "Retried",
        ])
        let conversationID = try XCTUnwrap(
            (conversation["readback"] as? [String: Any])?["conversation_id"] as? String
        )
        XCTAssertNil(
            try sidecarObject(fixture.db, key: "bot.remote.selected_conversations")[botID],
            "the injected failure must have rejected the selection row"
        )
        XCTAssertNotNil(
            try sidecarObject(fixture.db, key: "bot.remote.receipts")["sidecar-retry-conversation"],
            "the receipt must commit even when another row of the same persist is rejected"
        )
        try fixture.db.execute("DROP TRIGGER fail_selection_sidecar;")

        let counter = SidecarWriteCounter()
        counter.attach(to: fixture.db)
        _ = try fixture.authority.dispatch(method: "bot.set_pinned", params: [
            "client_request_id": "sidecar-retry-pin", "bot_id": botID, "pinned": true,
        ])
        counter.detach(from: fixture.db)

        XCTAssertEqual(
            try sidecarObject(fixture.db, key: "bot.remote.selected_conversations")[botID] as? String,
            conversationID,
            "the rejected row must be written by the next mutation"
        )
        XCTAssertEqual(counter.commits, 1, "the retried row must travel in the mutation's single commit")
        XCTAssertLessThanOrEqual(counter.rowWrites, 3, "only the receipt rows and the retried row are written")
    }

    private func requireOptIn() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RC2_RUN_RESIDUAL_PERSISTENCE_BENCHMARKS"] == "1",
            "Set RC2_RUN_RESIDUAL_PERSISTENCE_BENCHMARKS=1 to collect benchmark receipts."
        )
    }

    private func absoluteAppSupportRoot() throws -> URL {
        guard let raw = ProcessInfo.processInfo.environment["RC2_SANDBOX_APP_SUPPORT"],
              (raw as NSString).isAbsolutePath else {
            throw HarnessError.missingAbsoluteAppSupport
        }
        let root = URL(fileURLWithPath: raw, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func runBenchmark(
        id: String,
        fixture: String,
        legacyFactory: () throws -> TimedOperation,
        currentFactory: () throws -> TimedOperation
    ) throws {
        var semanticallyEquivalent = true
        for warmup in 0..<Self.warmupCount {
            let pair = try measurePair(
                currentFirst: !warmup.isMultiple(of: 2),
                legacyFactory: legacyFactory,
                currentFactory: currentFactory
            )
            if pair.legacy.signature != pair.current.signature {
                semanticallyEquivalent = false
                XCTFail("\(id) warmup changed durable semantics")
            }
        }

        var before: [Double] = []
        var after: [Double] = []
        before.reserveCapacity(Self.sampleCount)
        after.reserveCapacity(Self.sampleCount)
        for sample in 0..<Self.sampleCount {
            let pair = try measurePair(
                currentFirst: !sample.isMultiple(of: 2),
                legacyFactory: legacyFactory,
                currentFactory: currentFactory
            )
            if pair.legacy.signature != pair.current.signature {
                semanticallyEquivalent = false
                XCTFail("\(id) sample \(sample) changed durable semantics")
            }
            before.append(pair.legacy.milliseconds)
            after.append(pair.current.milliseconds)
        }

        let beforeMedian = median(before)
        let afterMedian = median(after)
        let improvement = ((beforeMedian - afterMedian) / beforeMedian) * 100
        let record = BenchmarkRecord(
            id: id,
            warmups: Self.warmupCount,
            samples: Self.sampleCount,
            beforeRawMilliseconds: before,
            afterRawMilliseconds: after,
            beforeMedianMilliseconds: beforeMedian,
            afterMedianMilliseconds: afterMedian,
            improvementPercent: improvement,
            semanticEquivalence: semanticallyEquivalent,
            comparisonOrder: "paired same-process AB/BA alternating; fixture setup and semantic readback excluded",
            fixture: fixture
        )
        try emit(record)
        XCTAssertTrue(semanticallyEquivalent, "\(id) must preserve the durable readback")
        XCTAssertGreaterThanOrEqual(
            improvement,
            5,
            "\(id) did not clear the frozen five-percent median gate"
        )
    }

    private func measurePair(
        currentFirst: Bool,
        legacyFactory: () throws -> TimedOperation,
        currentFactory: () throws -> TimedOperation
    ) throws -> (legacy: Measurement, current: Measurement) {
        if currentFirst {
            let current = try measure(currentFactory)
            let legacy = try measure(legacyFactory)
            return (legacy, current)
        }
        let legacy = try measure(legacyFactory)
        let current = try measure(currentFactory)
        return (legacy, current)
    }

    private func measure(_ factory: () throws -> TimedOperation) throws -> Measurement {
        let operation = try factory()
        defer { operation.cleanup() }
        let start = DispatchTime.now().uptimeNanoseconds
        try operation.run()
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        return Measurement(
            milliseconds: Double(elapsed) / 1_000_000,
            signature: try operation.signature()
        )
    }

    private func median(_ samples: [Double]) -> Double {
        samples.sorted()[samples.count / 2]
    }

    private func emit(_ record: BenchmarkRecord) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        print("RESIDUAL_PERSISTENCE_BENCHMARK \(String(decoding: data, as: UTF8.self))")
    }

    private func makeStreamOperation(
        batches: [[AgentRunRepository.StreamWriteIntent]],
        legacy: Bool
    ) throws -> TimedOperation {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        let thread = AgentThread(title: "residual-stream-benchmark", provider: .codex, model: "m")
        try AgentThreadRepository(db: db).upsert(thread)
        let run = AgentRun(threadId: thread.id, provider: .codex, model: "m")
        let repository = AgentRunRepository(db: db)
        repository.useLegacyDurableHostMetadataDecodingForBenchmark = legacy
        try repository.upsert(run)
        return TimedOperation(
            run: {
                for batch in batches {
                    try repository.persistStreamBatch(
                        runId: run.id,
                        threadId: thread.id,
                        items: batch,
                        shouldPruneStreamEvents: false
                    )
                }
            },
            signature: {
                let rows = try db.prepare(
                    "SELECT COUNT(*), COALESCE(MAX(seq), 0) FROM agent_stream_events WHERE run_id = ?;"
                )
                try rows.bind(1, run.id.value.uuidString)
                guard try rows.step() else { throw HarnessError.missingRow("stream rows") }
                let attestations = try self.scalar(
                    db,
                    sql: "SELECT COUNT(*) FROM agent_item_host_attestations WHERE run_id = ?;",
                    binding: run.id.value.uuidString
                )
                return "rows=\(rows.columnInt64(0));max=\(rows.columnInt64(1));attestations=\(attestations)"
            },
            cleanup: {}
        )
    }

    private func makeCheckpointOperation(
        files: [AgentTurnCheckpointFile],
        legacy: Bool
    ) throws -> TimedOperation {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        let thread = AgentThread(title: "residual-checkpoint-benchmark", provider: .codex, model: "m")
        try AgentThreadRepository(db: db).upsert(thread)
        let run = AgentRun(threadId: thread.id, provider: .codex, model: "m")
        try AgentRunRepository(db: db).upsert(run)
        let repository = AgentTurnCheckpointRepository(db: db)
        repository.useLegacyBoundedFileSummaryForBenchmark = legacy
        let checkpoint = AgentTurnCheckpointSummary(
            threadId: thread.id,
            runId: run.id,
            turnId: "residual-checkpoint-benchmark",
            checkpointTurnCount: 1,
            checkpointRef: "ref",
            status: .ready,
            files: files,
            completedAt: Date(timeIntervalSince1970: 1_700_000_050)
        )
        return TimedOperation(
            run: {
                for _ in 0..<200 {
                    try repository.upsert(checkpoint)
                }
            },
            signature: {
                let row = try db.prepare(
                    "SELECT files_json, files_summary_json, files_summary_truncated FROM agent_turn_checkpoints WHERE thread_id = ? AND turn_id = ?;"
                )
                try row.bind(1, thread.id.value.uuidString)
                try row.bind(2, checkpoint.turnId)
                guard try row.step(),
                      let filesJSON = row.columnText(0),
                      let summaryJSON = row.columnText(1),
                      let filesData = filesJSON.data(using: .utf8),
                      let summaryData = summaryJSON.data(using: .utf8) else {
                    throw HarnessError.missingRow("checkpoint summary")
                }
                guard let raw = try? JSONDecoder().decode([AgentTurnCheckpointFile].self, from: filesData),
                      let summary = try? JSONDecoder().decode([AgentTurnCheckpointFile].self, from: summaryData) else {
                    throw HarnessError.invalidStoredJSON("checkpoint summary")
                }
                return "raw=\(raw.count);summary=\(summary.map(\.path).joined(separator: "|"));bytes=\(summaryData.count);truncated=\(row.columnInt64(2))"
            },
            cleanup: {}
        )
    }

    private func makeBotRemoteOperation(
        supportRoot: URL,
        legacy: Bool
    ) throws -> TimedOperation {
        let support = supportRoot.appendingPathComponent(
            "ResidualPersistenceBenchmark-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        let settings = SettingsStore(db: db)
        let authority = BotRemoteControlAuthority(
            db: db,
            store: BotStore(db: db),
            settings: settings,
            appSupportDirectory: support
        )
        authority.useLegacySidecarDateFormatterForBenchmark = legacy
        return TimedOperation(
            run: {
                for index in 0..<40 {
                    _ = try authority.dispatch(method: "bot.settings.set", params: [
                        "client_request_id": "residual-benchmark-\(index)",
                        "key": "effects",
                        "value": index.isMultiple(of: 2),
                    ])
                }
            },
            signature: {
                let receiptData = try self.settingData(db, key: "bot.remote.receipts")
                guard let receipts = try JSONSerialization.jsonObject(with: receiptData) as? [String: Any] else {
                    throw HarnessError.invalidStoredJSON("bot.remote.receipts")
                }
                let sidecars = try self.scalar(
                    db,
                    sql: "SELECT COUNT(*) FROM settings WHERE key IN ('bot.remote.unpublished', 'bot.remote.receipts', 'bot.remote.files_location');"
                )
                let timestamps = try db.prepare(
                    "SELECT updated_at FROM settings WHERE key IN ('bot.remote.unpublished', 'bot.remote.receipts', 'bot.remote.files_location') ORDER BY key;"
                )
                let formatter = ISO8601DateFormatter()
                var validTimestampCount = 0
                while try timestamps.step() {
                    if let value = timestamps.columnText(0), formatter.date(from: value) != nil {
                        validTimestampCount += 1
                    }
                }
                return "sidecars=\(sidecars);receipts=\(receipts.count);timestamps=\(validTimestampCount);effects=\(settings.load().botsEffectsEnabled)"
            },
            cleanup: {
                try? FileManager.default.removeItem(at: support)
            }
        )
    }

    /// Counts writes to `settings` and the durable commits that carry them: a
    /// write outside a transaction is its own commit. The mutations measured
    /// with it write to `settings` only through the Bot sidecar.
    private final class SidecarWriteCounter {
        private(set) var rowWrites = 0
        private(set) var commits = 0
        private var transactionOpen = false
        private var rowWritesInTransaction = 0

        func attach(to db: SQLiteDB) {
            db.beforeExecuteForTesting = { [self] sql in
                if sql.hasPrefix("BEGIN") {
                    transactionOpen = true
                    rowWritesInTransaction = 0
                } else if sql.hasPrefix("COMMIT") {
                    if rowWritesInTransaction > 0 { commits += 1 }
                    transactionOpen = false
                } else if sql.hasPrefix("ROLLBACK") {
                    transactionOpen = false
                }
            }
            db.beforeStatementStepForTesting = { [self] sql in
                guard sql.contains("INTO settings") else { return }
                rowWrites += 1
                if transactionOpen {
                    rowWritesInTransaction += 1
                } else {
                    commits += 1
                }
            }
        }

        func detach(from db: SQLiteDB) {
            db.beforeExecuteForTesting = nil
            db.beforeStatementStepForTesting = nil
        }

        func reset() {
            rowWrites = 0
            commits = 0
        }
    }

    private func makeSidecarFixture() throws -> (
        db: SQLiteDB,
        store: BotStore,
        settings: SettingsStore,
        support: URL,
        authority: BotRemoteControlAuthority
    ) {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-bot-sidecar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        let store = BotStore(db: db)
        let settings = SettingsStore(db: db)
        let authority = BotRemoteControlAuthority(
            db: db,
            store: store,
            settings: settings,
            appSupportDirectory: support
        )
        return (db, store, settings, support, authority)
    }

    private func sidecarObject(_ db: SQLiteDB, key: String) throws -> [String: Any] {
        let data = try settingData(db, key: key)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HarnessError.invalidStoredJSON(key)
        }
        return object
    }

    private func scalar(
        _ db: SQLiteDB,
        sql: String,
        binding: String? = nil
    ) throws -> Int64 {
        let statement = try db.prepare(sql)
        if let binding { try statement.bind(1, binding) }
        guard try statement.step() else { throw HarnessError.missingRow(sql) }
        return statement.columnInt64(0)
    }

    private func settingData(_ db: SQLiteDB, key: String) throws -> Data {
        let statement = try db.prepare("SELECT value FROM settings WHERE key = ? LIMIT 1;")
        try statement.bind(1, key)
        guard try statement.step(),
              let value = statement.columnText(0),
              let data = value.data(using: .utf8) else {
            throw HarnessError.missingRow(key)
        }
        return data
    }
}
