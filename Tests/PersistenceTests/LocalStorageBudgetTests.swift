import XCTest
import CoreModel
@testable import Persistence

final class LocalStorageBudgetTests: XCTestCase {
    private final class ErrorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var error: Error?

        func record(_ error: Error) {
            lock.lock()
            self.error = error
            lock.unlock()
        }

        func snapshot() -> Error? {
            lock.lock()
            defer { lock.unlock() }
            return error
        }
    }

    private struct Fixture {
        let directory: String
        let db: SQLiteDB
        let thread: AgentThread
        let run: AgentRun
    }

    private func makeFixture(runStatus: AgentRunStatus = .completed) throws -> Fixture {
        let directory = NSTemporaryDirectory() + "RC2StorageBudget-" + UUID().uuidString
        let databasePath = directory + "/remote-code.sqlite"
        let db = try SQLiteDB(path: databasePath)
        try Schema.migrate(db)

        let thread = AgentThread(title: "storage", provider: .codex, model: "test")
        var run = AgentRun(threadId: thread.id, provider: .codex, model: "test", status: runStatus)
        if runStatus != .pending && runStatus != .running {
            run.finishedAt = Date(timeIntervalSince1970: 2)
        }
        try AgentThreadRepository(db: db).upsert(thread)
        try AgentRunRepository(db: db).upsert(run)
        return Fixture(directory: directory, db: db, thread: thread, run: run)
    }

    private func classUsage(
        _ storageClass: LocalStorageClass,
        in snapshot: LocalStorageSnapshot,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> LocalStorageClassUsage {
        try XCTUnwrap(snapshot.classes.first { $0.storageClass == storageClass }, file: file, line: line)
    }

    func test_snapshotReportsUsageQuotaAndRetentionForEveryOperationalClass() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.directory) }
        let reversibleStore = ReversibleContentStore(db: fixture.db)
        _ = try reversibleStore.store(Data(repeating: 0x61, count: 128))
        try AgentRunRepository(db: fixture.db).appendStreamEvent(
            runId: fixture.run.id,
            seq: 1,
            kind: "assistantText",
            payloadJSON: #"{"text":"stream-payload"}"#
        )
        try AgentRunRepository(db: fixture.db).appendProviderEventLog(
            threadId: fixture.thread.id,
            runId: fixture.run.id,
            event: ProviderRuntimeEvent(
                id: "provider-event",
                provider: .codex,
                source: "test",
                method: "item/completed",
                payloadJSON: #"{"text":"provider-payload"}"#,
                receivedAtMs: 1
            )
        )

        let snapshot = try LocalStorageBudgetManager(db: fixture.db).snapshot()

        XCTAssertEqual(snapshot.classes.map(\.storageClass), LocalStorageClass.allCases)
        XCTAssertEqual(try classUsage(.reversibleContent, in: snapshot).rowCount, 1)
        XCTAssertEqual(try classUsage(.reversibleContent, in: snapshot).payloadBytes, 128)
        XCTAssertEqual(try classUsage(.streamEvents, in: snapshot).rowCount, 1)
        XCTAssertGreaterThan(try classUsage(.streamEvents, in: snapshot).payloadBytes, 0)
        XCTAssertEqual(try classUsage(.providerLogs, in: snapshot).rowCount, 1)
        XCTAssertGreaterThan(try classUsage(.providerLogs, in: snapshot).payloadBytes, 0)
        for usage in snapshot.classes {
            XCTAssertGreaterThan(usage.payloadQuotaBytes, 0, "\(usage.storageClass) needs an explicit payload quota")
            XCTAssertGreaterThan(usage.retentionDays, 0, "\(usage.storageClass) needs visible retention telemetry")
        }
        XCTAssertGreaterThan(snapshot.databaseBytes, 0)
        XCTAssertGreaterThanOrEqual(snapshot.reclaimableBytes, 0)
    }

    func test_snapshotAccountsMainWALAndSHMAndPassiveCheckpointRemainsNonVacuuming() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.directory) }
        let messages = AgentMessageRepository(db: fixture.db)
        for index in 0..<200 {
            try messages.append(AgentMessage(
                threadId: fixture.thread.id,
                role: .assistant,
                content: "row-\(index)-" + String(repeating: "x", count: 1_024)
            ))
        }
        let manager = LocalStorageBudgetManager(db: fixture.db)
        let before = try manager.snapshot()
        XCTAssertGreaterThan(before.databaseFileBytes, 0)
        XCTAssertEqual(before.physicalBytes, before.databaseFileBytes + before.walBytes + before.sharedMemoryBytes,
                       "physical accounting must include every SQLite sidecar, not only logical page_count")

        let checkpoint = try manager.passiveCheckpoint()
        XCTAssertGreaterThanOrEqual(checkpoint.busyReaders, 0)
        XCTAssertGreaterThanOrEqual(checkpoint.walFrames, checkpoint.checkpointedFrames)
        XCTAssertEqual(checkpoint.snapshot.physicalBytes,
                       checkpoint.snapshot.databaseFileBytes + checkpoint.snapshot.walBytes + checkpoint.snapshot.sharedMemoryBytes)
        XCTAssertGreaterThanOrEqual(checkpoint.snapshot.databaseBytes, before.databaseBytes,
                                    "PASSIVE checkpoint must not VACUUM or rewrite the logical database smaller")
    }

    func test_undoGCPinExpiryNeverRoundsEarlierThanFullPrecisionUndoWindow() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.directory) }
        let expiry = Date(timeIntervalSince1970: 1_000.0009)
        _ = try AgentThreadRepository(db: fixture.db).deleteWithRelationalSnapshot(
            ids: [fixture.thread.id],
            undoGCPin: AgentThreadUndoGCPin(id: "fractional-expiry", expiresAt: expiry)
        )

        func pinCount() throws -> Int64 {
            let statement = try fixture.db.prepare(
                "SELECT COUNT(*) FROM agent_thread_undo_gc_pins WHERE owner_id = 'fractional-expiry';"
            )
            guard try statement.step() else { return 0 }
            return statement.columnInt64(0)
        }

        _ = try LocalStorageBudgetManager(db: fixture.db).cleanupExpired(
            now: Date(timeIntervalSince1970: 1_000.0008),
            compact: false
        )
        XCTAssertEqual(try pinCount(), 1,
                       "GC must not round a fractional expiry down before the full-precision undo window ends")

        _ = try LocalStorageBudgetManager(db: fixture.db).cleanupExpired(
            now: Date(timeIntervalSince1970: 1_000.002),
            compact: false
        )
        XCTAssertEqual(try pinCount(), 0,
                       "the conservatively rounded pin must still expire immediately after its safety millisecond")
    }

    func test_attachmentUsageAndCleanupPreserveEveryDurableOwnerAndDeleteOnlyExpiredOrphan() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.directory) }
        let attachmentRoot = URL(fileURLWithPath: fixture.directory)
            .appendingPathComponent("agent-attachments", isDirectory: true)
        let incoming = URL(fileURLWithPath: fixture.directory)
            .appendingPathComponent("incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        let attachmentStore = AgentAttachmentStore(root: attachmentRoot)

        func stage(_ name: String, _ contents: String) throws -> AgentAttachment {
            let source = incoming.appendingPathComponent(name)
            try Data(contents.utf8).write(to: source)
            return try attachmentStore.stage(path: source.path)
        }

        let messageAttachment = try stage("message.txt", "message-owned")
        let queueAttachment = try stage("queue.txt", "queue-owned")
        let draftAttachment = try stage("draft.txt", "draft-owned")
        let checkpointAttachment = try stage("checkpoint.txt", "checkpoint-owned")
        let orphanAttachment = try stage("orphan.txt", "orphan")
        try AgentMessageRepository(db: fixture.db).append(AgentMessage(
            threadId: fixture.thread.id,
            role: .user,
            content: "message attachment",
            attachments: [messageAttachment]
        ))
        _ = try AgentQueuedMessageRepository(db: fixture.db).enqueue(
            threadId: fixture.thread.id,
            text: "queued attachment",
            attachments: [queueAttachment],
            interactionMode: .default
        )
        try AgentThreadDraftRepository(db: fixture.db).upsert(AgentThreadDraft(
            threadId: fixture.thread.id,
            providerInstanceId: "codex-default",
            text: "draft attachment",
            attachments: [draftAttachment]
        ))
        try AgentTurnCheckpointRepository(db: fixture.db).upsert(AgentTurnCheckpointSummary(
            threadId: fixture.thread.id,
            runId: fixture.run.id,
            turnId: "attachment-checkpoint",
            checkpointTurnCount: 1,
            checkpointRef: "managed attachment \(try XCTUnwrap(checkpointAttachment.sha256))",
            status: .ready,
            files: []
        ))
        let old = Date(timeIntervalSince1970: 1)
        for attachment in [messageAttachment, queueAttachment, draftAttachment, checkpointAttachment, orphanAttachment] {
            try FileManager.default.setAttributes(
                [.modificationDate: old],
                ofItemAtPath: attachment.path
            )
        }
        let manager = LocalStorageBudgetManager(
            db: fixture.db,
            attachmentRoot: attachmentRoot
        )

        let before = try classUsage(.attachmentBlobs, in: manager.snapshot())
        XCTAssertEqual(before.rowCount, 5)
        XCTAssertEqual(before.payloadQuotaBytes, LocalStorageBudgetManager.durableUserPayloadQuotaBytes,
                       "attachment telemetry must reuse the established durable-user-payload budget")
        XCTAssertEqual(before.retentionDays, LocalStorageBudgetManager.retentionDays)

        let result = try manager.cleanupExpired(
            now: Date(timeIntervalSince1970: 4_000_000),
            compact: false
        )

        XCTAssertEqual(result.removedRows[.attachmentBlobs], 1)
        for attachment in [messageAttachment, queueAttachment, draftAttachment, checkpointAttachment] {
            XCTAssertNoThrow(try attachmentStore.validatedForRetry(attachment),
                             "every canonical durable owner must retain its content-addressed blob")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanAttachment.path),
                       "only an expired blob with no durable owner is eligible for cleanup")
        XCTAssertEqual(try classUsage(.attachmentBlobs, in: result.snapshot).rowCount, 4)
    }

    func test_attachmentCleanupPreservesReferencedLegacyExtensionPath() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.directory) }
        let attachmentRoot = URL(fileURLWithPath: fixture.directory)
            .appendingPathComponent("agent-attachments", isDirectory: true)
        let source = URL(fileURLWithPath: fixture.directory).appendingPathComponent("legacy.txt")
        try Data("legacy content addressed bytes".utf8).write(to: source)
        let store = AgentAttachmentStore(root: attachmentRoot)
        let canonical = try store.stage(path: source.path)
        let legacyURL = URL(fileURLWithPath: canonical.path).appendingPathExtension("txt")
        try FileManager.default.moveItem(at: URL(fileURLWithPath: canonical.path), to: legacyURL)
        let legacy = AgentAttachment(
            id: canonical.id,
            path: legacyURL.path,
            displayName: canonical.displayName,
            kind: canonical.kind,
            mimeType: canonical.mimeType,
            sha256: canonical.sha256,
            sizeBytes: canonical.sizeBytes
        )
        try AgentMessageRepository(db: fixture.db).append(AgentMessage(
            threadId: fixture.thread.id,
            role: .user,
            content: "legacy managed path",
            attachments: [legacy]
        ))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)],
            ofItemAtPath: legacy.path
        )

        let result = try LocalStorageBudgetManager(
            db: fixture.db,
            attachmentRoot: attachmentRoot
        ).cleanupExpired(now: Date(timeIntervalSince1970: 4_000_000), compact: false)

        XCTAssertEqual(result.removedRows[.attachmentBlobs], 0)
        XCTAssertEqual(try store.validatedForRetry(legacy), legacy,
                       "upgrading to digest-only filenames must not break previously persisted retry paths")
    }

    func test_attachmentCleanupResolvesOpaqueReferenceIDToSharedBlobDigest() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.directory) }
        let attachmentRoot = URL(fileURLWithPath: fixture.directory)
            .appendingPathComponent("agent-attachments", isDirectory: true)
        let source = URL(fileURLWithPath: fixture.directory).appendingPathComponent("opaque-only.txt")
        try Data("opaque reference owned bytes".utf8).write(to: source)
        let store = AgentAttachmentStore(root: attachmentRoot)
        let staged = try store.stage(path: source.path)
        let opaqueOnly = AgentAttachment(
            id: staged.id,
            path: "",
            displayName: staged.displayName,
            kind: staged.kind,
            mimeType: staged.mimeType
        )
        try AgentMessageRepository(db: fixture.db).append(AgentMessage(
            threadId: fixture.thread.id,
            role: .user,
            content: "opaque attachment reference",
            attachments: [opaqueOnly]
        ))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)],
            ofItemAtPath: staged.path
        )

        let result = try LocalStorageBudgetManager(
            db: fixture.db,
            attachmentRoot: attachmentRoot
        ).cleanupExpired(now: Date(timeIntervalSince1970: 4_000_000), compact: false)

        XCTAssertEqual(result.removedRows[.attachmentBlobs], 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path),
                      "GC must resolve a durable opaque reference through host metadata before deleting its shared blob")
    }

    func test_attachmentStageRefreshLeaseWinsCleanupReferenceScanRace() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.directory) }
        let root = URL(fileURLWithPath: fixture.directory).appendingPathComponent("agent-attachments", isDirectory: true)
        let source = URL(fileURLWithPath: fixture.directory).appendingPathComponent("race.txt")
        let exact = Data("race-safe exact bytes".utf8)
        try exact.write(to: source)
        let store = AgentAttachmentStore(root: root)
        let attachment = try store.stage(path: source.path)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)],
            ofItemAtPath: attachment.path
        )
        let manager = LocalStorageBudgetManager(db: fixture.db, attachmentRoot: root)
        var stagedDuringGap: AgentAttachment?
        manager.beforeAttachmentCleanupLockForTesting = {
            stagedDuringGap = try? store.stage(path: source.path)
        }

        let result = try manager.cleanupExpired(now: Date(), compact: false)

        XCTAssertNotNil(stagedDuringGap)
        XCTAssertEqual(result.removedRows[.attachmentBlobs], 0,
                       "staging between reference scan and GC lock must refresh the blob lease")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: attachment.path)), exact)
    }

    func test_cleanupNeverDeletesReferencedRecoverableContentAndPrunesExpiredDiagnostics() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.directory) }
        let old = Date(timeIntervalSince1970: 1)
        let now = Date(timeIntervalSince1970: 4_000_000)
        let store = ReversibleContentStore(db: fixture.db)
        let protected = try store.store("must survive", at: old)
        let protectedByBlob = try store.store("terminal reference", at: old)
        let protectedByDirectHandle = try store.store("shared memory reference", at: old)
        let orphan = try store.store("expired orphan", at: old)
        try AgentMessageRepository(db: fixture.db).append(AgentMessage(
            threadId: fixture.thread.id,
            role: .assistant,
            content: "Recover with \(ReversibleContentStore.marker(for: protected))",
            createdAt: old
        ))
        try TerminalOutputRepository(db: fixture.db).append(
            surfaceID: "terminal",
            workspaceID: nil,
            chunkIndex: 1,
            data: Data("Recover with \(ReversibleContentStore.marker(for: protectedByBlob))".utf8)
        )
        let sharedMemory = try fixture.db.prepare("""
            INSERT INTO shared_memory_blocks(
                id, content_hash, reversible_handle, preview, byte_count,
                token_count_estimate, ref_count, metadata_json, created_at_ms, last_access_ms
            ) VALUES('block', 'hash', ?, '', 1, 1, 1, '{}', 1, 1);
            """)
        try sharedMemory.bind(1, protectedByDirectHandle)
        _ = try sharedMemory.step()
        try AgentRunRepository(db: fixture.db).appendStreamEvent(
            runId: fixture.run.id,
            seq: 1,
            kind: "old",
            payloadJSON: #"{"text":"expired stream"}"#
        )
        try AgentRunRepository(db: fixture.db).appendProviderEventLog(
            threadId: fixture.thread.id,
            runId: fixture.run.id,
            event: ProviderRuntimeEvent(
                id: "old-provider-event",
                provider: .codex,
                source: "test",
                method: "old",
                payloadJSON: #"{"text":"expired provider log"}"#,
                receivedAtMs: 1
            )
        )
        try fixture.db.execute("UPDATE agent_stream_events SET created_at = '1970-01-01T00:00:01Z';")
        try fixture.db.execute("UPDATE agent_provider_event_logs SET created_at = '1970-01-01T00:00:01Z';")

        let result = try LocalStorageBudgetManager(db: fixture.db).cleanupExpired(now: now, compact: false)

        XCTAssertEqual(result.removedRows[.reversibleContent], 1)
        XCTAssertEqual(result.removedRows[.streamEvents], 1)
        XCTAssertEqual(result.removedRows[.providerLogs], 1)
        XCTAssertEqual(try store.retrieveText(protected), "must survive",
                       "a durable [[rc:handle]] reference is stronger than stale age or a zero ref_count")
        XCTAssertEqual(try store.retrieveText(protectedByBlob), "terminal reference",
                       "markers in canonical BLOB output must protect their originals")
        XCTAssertEqual(try store.retrieveText(protectedByDirectHandle), "shared memory reference",
                       "a canonical bare-handle reference must protect its original")
        XCTAssertNil(try store.retrieve(orphan), "only stale content with no durable marker and ref_count=0 is eligible")
    }

    func test_cleanupPreservesRefCountEvenWithoutMarker() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.directory) }
        let store = ReversibleContentStore(db: fixture.db)
        let handle = try store.store("retained", at: Date(timeIntervalSince1970: 1))
        try store.retain(handle)

        let result = try LocalStorageBudgetManager(db: fixture.db).cleanupExpired(
            now: Date(timeIntervalSince1970: 4_000_000),
            compact: false
        )

        XCTAssertEqual(result.removedRows[.reversibleContent], 0)
        XCTAssertEqual(try store.retrieveText(handle), "retained")
    }

    func test_cleanupWaitsForConcurrentDurableReferenceWriterBeforeScanningAndDeleting() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.directory) }
        let store = ReversibleContentStore(db: fixture.db)
        let handle = try store.store("concurrent original", at: Date(timeIntervalSince1970: 1))
        let writerEnteredStep = DispatchSemaphore(value: 0)
        let allowWriterCommit = DispatchSemaphore(value: 0)
        let writerFinished = DispatchSemaphore(value: 0)
        let cleanupStarted = DispatchSemaphore(value: 0)
        let cleanupFinished = DispatchSemaphore(value: 0)
        let writerError = ErrorBox()
        let cleanupError = ErrorBox()

        fixture.db.beforeStatementStepForTesting = { sql in
            guard sql.contains("INSERT INTO agent_messages") else { return }
            writerEnteredStep.signal()
            _ = allowWriterCommit.wait(timeout: .now() + 2)
        }

        DispatchQueue.global().async {
            do {
                try AgentMessageRepository(db: fixture.db).append(AgentMessage(
                    threadId: fixture.thread.id,
                    role: .assistant,
                    content: "Recover with \(ReversibleContentStore.marker(for: handle))"
                ))
            } catch {
                writerError.record(error)
            }
            writerFinished.signal()
        }
        XCTAssertEqual(writerEnteredStep.wait(timeout: .now() + 2), .success)

        DispatchQueue.global().async {
            cleanupStarted.signal()
            do {
                _ = try LocalStorageBudgetManager(db: fixture.db).cleanupExpired(
                    now: Date(timeIntervalSince1970: 4_000_000),
                    compact: false
                )
            } catch {
                cleanupError.record(error)
            }
            cleanupFinished.signal()
        }
        XCTAssertEqual(cleanupStarted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(cleanupFinished.wait(timeout: .now() + 0.05), .timedOut,
                       "cleanup must not scan references while a durable writer owns the database operation gate")

        allowWriterCommit.signal()
        XCTAssertEqual(writerFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(cleanupFinished.wait(timeout: .now() + 2), .success)
        fixture.db.beforeStatementStepForTesting = nil

        XCTAssertNil(writerError.snapshot())
        XCTAssertNil(cleanupError.snapshot())
        XCTAssertEqual(try store.retrieveText(handle), "concurrent original",
                       "cleanup must see a reference committed by a writer that started first")
    }

    /// WHY: the launch/24 h pass builds the manager without an attachment root,
    /// so the digest + reference-ID regex over every checkpoint, snapshot and
    /// provider payload (~200 MB on a real database) fed a blob delete that
    /// returns 0 before reading it. That discarded scan was the 5-7 s launch
    /// freeze. Without a root (or without an expired blob) it must not run.
    func test_cleanupWithoutAttachmentRootNeverReadsAttachmentOwnerColumns() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.directory) }
        try AgentMessageRepository(db: fixture.db).append(AgentMessage(
            threadId: fixture.thread.id,
            role: .assistant,
            content: "no marker"
        ))
        var stepped: [String] = []
        fixture.db.beforeStatementStepForTesting = { stepped.append($0) }

        _ = try LocalStorageBudgetManager(db: fixture.db).cleanupExpired(
            now: Date(timeIntervalSince1970: 4_000_000),
            compact: false
        )
        fixture.db.beforeStatementStepForTesting = nil

        let structured = LocalStorageAttachmentReferenceRegistry.structuredColumns.map(\.column)
        XCTAssertFalse(stepped.contains { sql in structured.contains { sql.contains("SELECT \"\($0)\"") } },
                       "attachment owner columns feed only blob deletion, which has nothing to delete without a root")
        XCTAssertFalse(stepped.contains { $0.hasSuffix("IS NOT NULL;") },
                       "no registry column may be read whole (unfiltered and unbounded) when nothing can be deleted")
    }

    /// WHY: the reference scan used to run inside BEGIN IMMEDIATE on the single
    /// connection, so every main-thread read (SettingsRepository.get during
    /// window hydration) waited for the whole scan. With every expired original
    /// still referenced, the scan must read in bounded chunks outside the write
    /// transaction, keep the original, and never rescan under the writer lock.
    func test_referenceScanReadsInChunksOutsideTheWriteTransaction() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.directory) }
        let store = ReversibleContentStore(db: fixture.db)
        let handle = try store.store("referenced from terminal output", at: Date(timeIntervalSince1970: 1))
        let terminal = TerminalOutputRepository(db: fixture.db)
        let rows = LocalStorageBudgetManager.referenceScanChunkRows * 2 + 5
        for index in 1...rows {
            let text = index == rows ? "Recover with \(ReversibleContentStore.marker(for: handle))" : "plain output \(index)"
            try terminal.append(surfaceID: "terminal", workspaceID: nil, chunkIndex: Int64(index), data: Data(text.utf8))
        }
        var insideWriteTransaction = false
        var terminalScanSteps = 0
        var registryReadsInsideWriteTransaction: [String] = []
        let markerColumns = LocalStorageRecoveryReferenceRegistry.markerColumns.map(\.column)
        fixture.db.beforeExecuteForTesting = { sql in
            if sql.hasPrefix("BEGIN IMMEDIATE") { insideWriteTransaction = true }
            if sql.hasPrefix("COMMIT") || sql.hasPrefix("ROLLBACK") { insideWriteTransaction = false }
        }
        fixture.db.beforeStatementStepForTesting = { sql in
            if sql.contains("FROM \"terminal_output_chunks\"") { terminalScanSteps += 1 }
            if insideWriteTransaction, markerColumns.contains(where: { sql.contains("\"\($0)\"") }) {
                registryReadsInsideWriteTransaction.append(sql)
            }
        }

        let manager = LocalStorageBudgetManager(db: fixture.db)
        // Row-count chunking only: a loaded test host must not end chunks early.
        manager.referenceScanChunkBudgetNanoseconds = .max
        let result = try manager.cleanupExpired(now: Date(timeIntervalSince1970: 4_000_000), compact: false)
        fixture.db.beforeExecuteForTesting = nil
        fixture.db.beforeStatementStepForTesting = nil

        XCTAssertEqual(result.removedRows[.reversibleContent], 0)
        XCTAssertEqual(try store.retrieveText(handle), "referenced from terminal output",
                       "a marker in the last chunk must still protect its original")
        XCTAssertEqual(registryReadsInsideWriteTransaction, [],
                       "a fully referenced candidate set must not rescan the registry under the writer lock")
        // One step per row plus one end-of-chunk step per serialized read: at
        // least three reads for 2×chunk+5 rows, each releasing the gate.
        XCTAssertGreaterThanOrEqual(terminalScanSteps - rows, 3,
                                    "the scan must be split into bounded per-lock chunks")
        for reference in LocalStorageRecoveryReferenceRegistry.markerColumns
            + LocalStorageRecoveryReferenceRegistry.directHandleColumns {
            XCTAssertNoThrow(try fixture.db.prepare("SELECT rowid FROM \"\(reference.table)\" LIMIT 0;"),
                             "chunked scan pages by rowid; \(reference.table) must keep one")
        }
    }

    /// WHY: the chunked scan runs without the writer lock, and several registry
    /// columns are updated in place (session snapshots, drafts, provider
    /// runtime). A reference written after the scan saw "unreferenced" must
    /// still protect the original: a chunked view a commit has since made
    /// stale never decides a delete.
    func test_referenceWrittenInPlaceAfterChunkedScanStillProtectsOriginal() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.directory) }
        let store = ReversibleContentStore(db: fixture.db)
        let old = Date(timeIntervalSince1970: 1)
        let lateReferenced = try store.store("referenced after the scan", at: old)
        let orphan = try store.store("still an orphan", at: old)
        try fixture.db.execute(
            "INSERT INTO session_snapshots(version, payload_json, created_at) VALUES(1, '{}', '1970-01-01T00:00:01Z');"
        )
        let manager = LocalStorageBudgetManager(db: fixture.db)
        manager.beforeCleanupWriteTransactionForTesting = {
            let update = try? fixture.db.prepare("UPDATE session_snapshots SET payload_json = ?;")
            try? update?.bind(1, "{\"text\":\"\(ReversibleContentStore.marker(for: lateReferenced))\"}")
            _ = try? update?.step()
            update?.reset()
        }

        let result = try manager.cleanupExpired(now: Date(timeIntervalSince1970: 4_000_000), compact: false)

        XCTAssertEqual(result.removedRows[.reversibleContent], 1)
        XCTAssertEqual(try store.retrieveText(lateReferenced), "referenced after the scan",
                       "an in-place reference committed before the delete transaction must win")
        XCTAssertNil(try store.retrieve(orphan), "an original nobody references is still removed")
    }

    /// Records registry marker-column reads that run inside BEGIN IMMEDIATE.
    private final class WriterLockRegistryReads { var sql: [String] = [] }

    private func trackRegistryReadsUnderWriterLock(_ db: SQLiteDB) -> WriterLockRegistryReads {
        let reads = WriterLockRegistryReads()
        var insideWriteTransaction = false
        let markerColumns = LocalStorageRecoveryReferenceRegistry.markerColumns.map(\.column)
        db.beforeExecuteForTesting = { sql in
            if sql.hasPrefix("BEGIN IMMEDIATE") { insideWriteTransaction = true }
            if sql.hasPrefix("COMMIT") || sql.hasPrefix("ROLLBACK") { insideWriteTransaction = false }
        }
        db.beforeStatementStepForTesting = { sql in
            if insideWriteTransaction, markerColumns.contains(where: { sql.contains("\"\($0)\"") }) {
                reads.sql.append(sql)
            }
        }
        return reads
    }

    private func rowCount(_ db: SQLiteDB, _ table: String) throws -> Int64 {
        let statement = try db.prepare("SELECT COUNT(*) FROM \(table);")
        defer { statement.reset() }
        _ = try statement.step()
        return statement.columnInt64(0)
    }

    /// WHY: when the pass actually deletes an original, re-reading the whole
    /// registry (~300 MB of marker text on a real database) inside BEGIN
    /// IMMEDIATE held the single connection gate for 0.4-6 s and froze
    /// main-thread reads. With no commit since the chunked scan began, that
    /// scan is exact, so the delete transaction must not read the registry.
    func test_orphanDeleteTrustsChunkedScanWhenNothingWasWritten() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.directory) }
        let store = ReversibleContentStore(db: fixture.db)
        let old = Date(timeIntervalSince1970: 1)
        let referenced = try store.store("referenced from terminal output", at: old)
        let orphan = try store.store("nobody references this", at: old)
        try TerminalOutputRepository(db: fixture.db).append(
            surfaceID: "terminal", workspaceID: nil, chunkIndex: 1,
            data: Data("Recover with \(ReversibleContentStore.marker(for: referenced))".utf8)
        )
        let reads = trackRegistryReadsUnderWriterLock(fixture.db)

        let result = try LocalStorageBudgetManager(db: fixture.db).cleanupExpired(
            now: Date(timeIntervalSince1970: 4_000_000),
            compact: false
        )
        fixture.db.beforeExecuteForTesting = nil
        fixture.db.beforeStatementStepForTesting = nil

        XCTAssertEqual(result.removedRows[.reversibleContent], 1)
        XCTAssertNil(try store.retrieve(orphan), "the unreferenced original is deleted")
        XCTAssertEqual(try store.retrieveText(referenced), "referenced from terminal output")
        XCTAssertEqual(reads.sql, [],
                       "an unchanged database must not be rescanned under the writer lock to delete one orphan")
    }

    /// WHY: trusting the chunked scan is safe only if every commit since it
    /// began is noticed, including one from another connection on the same
    /// file, which this connection's `total_changes()` cannot see. That commit
    /// must send the pass back to a chunked rescan (gate released between
    /// chunks), never to a delete decided by the stale view.
    func test_referenceCommittedByAnotherConnectionMidScanTriggersChunkedRescan() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.directory) }
        let store = ReversibleContentStore(db: fixture.db)
        let old = Date(timeIntervalSince1970: 1)
        let lateReferenced = try store.store("referenced by another connection", at: old)
        let orphan = try store.store("still an orphan", at: old)
        let other = try SQLiteDB(path: fixture.db.path)
        let manager = LocalStorageBudgetManager(db: fixture.db)
        var scans = 0
        manager.beforeCleanupWriteTransactionForTesting = {
            scans += 1
            guard scans == 1 else { return }
            try? other.execute("""
                INSERT INTO session_snapshots(version, payload_json, created_at)
                VALUES(1, '{"text":"\(ReversibleContentStore.marker(for: lateReferenced))"}', '1970-01-01T00:00:01Z');
                """)
        }
        let reads = trackRegistryReadsUnderWriterLock(fixture.db)

        let result = try manager.cleanupExpired(now: Date(timeIntervalSince1970: 4_000_000), compact: false)
        fixture.db.beforeExecuteForTesting = nil
        fixture.db.beforeStatementStepForTesting = nil

        XCTAssertEqual(scans, 2, "a foreign commit must cost one more chunked scan")
        XCTAssertEqual(reads.sql, [], "the rescan runs in chunks, not under the writer lock")
        XCTAssertEqual(result.removedRows[.reversibleContent], 1)
        XCTAssertEqual(try store.retrieveText(lateReferenced), "referenced by another connection",
                       "a reference another connection committed after the first scan must win")
        XCTAssertNil(try store.retrieve(orphan))
    }

    /// WHY: chunked rescans must be bounded. While commits keep landing (an
    /// agent run streaming), the pass stops after `referenceScanAttempts`
    /// scans and decides with the exact registry under the writer lock, so a
    /// reference written right before that last transaction still wins.
    func test_commitsDuringEveryScanFallBackToExactRescanAfterBoundedAttempts() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.directory) }
        let store = ReversibleContentStore(db: fixture.db)
        let old = Date(timeIntervalSince1970: 1)
        let lateReferenced = try store.store("referenced before the last transaction", at: old)
        let orphan = try store.store("still an orphan", at: old)
        let manager = LocalStorageBudgetManager(db: fixture.db)
        var scans = 0
        manager.beforeCleanupWriteTransactionForTesting = {
            scans += 1
            let payload = scans == LocalStorageBudgetManager.referenceScanAttempts
                ? "{\"text\":\"\(ReversibleContentStore.marker(for: lateReferenced))\"}"
                : "{}"
            try? fixture.db.execute(
                "INSERT INTO session_snapshots(version, payload_json, created_at) VALUES(1, '\(payload)', '1970-01-01T00:00:01Z');"
            )
        }
        let reads = trackRegistryReadsUnderWriterLock(fixture.db)

        let result = try manager.cleanupExpired(now: Date(timeIntervalSince1970: 4_000_000), compact: false)
        fixture.db.beforeExecuteForTesting = nil
        fixture.db.beforeStatementStepForTesting = nil

        XCTAssertEqual(scans, LocalStorageBudgetManager.referenceScanAttempts,
                       "constant commits must not loop the chunked scan forever")
        XCTAssertFalse(reads.sql.isEmpty, "the last attempt re-checks the full registry under the writer lock")
        XCTAssertEqual(result.removedRows[.reversibleContent], 1)
        XCTAssertEqual(try store.retrieveText(lateReferenced), "referenced before the last transaction")
        XCTAssertNil(try store.retrieve(orphan))
    }

    /// WHY: the pass used to be one atomic transaction; it is now several
    /// commits. A read error in the chunked reference scan must reach the
    /// caller (runCCRRetention logs it) and delete nothing, because no original
    /// may go on an incomplete view of its references.
    func test_referenceScanFailureThrowsAndDeletesNothing() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.directory) }
        let store = ReversibleContentStore(db: fixture.db)
        let old = Date(timeIntervalSince1970: 1)
        _ = try store.store("orphan that must survive a failed scan", at: old)
        let referenced = try store.store("referenced", at: old)
        let terminal = TerminalOutputRepository(db: fixture.db)
        for index in 1...(LocalStorageBudgetManager.referenceScanChunkRows + 5) {
            try terminal.append(surfaceID: "terminal", workspaceID: nil, chunkIndex: Int64(index),
                                data: Data("Recover with \(ReversibleContentStore.marker(for: referenced))".utf8))
        }
        try AgentRunRepository(db: fixture.db).appendStreamEvent(
            runId: fixture.run.id, seq: 1, kind: "old", payloadJSON: "{}"
        )
        try fixture.db.execute("UPDATE agent_stream_events SET created_at = '1970-01-01T00:00:01Z';")
        var terminalScanSteps = 0
        fixture.db.beforeStatementStepForTesting = { sql in
            guard sql.contains("FROM \"terminal_output_chunks\"") else { return }
            terminalScanSteps += 1
            // Second chunk: the first one already released the gate.
            if terminalScanSteps == LocalStorageBudgetManager.referenceScanChunkRows + 2 {
                fixture.db.injectedResultCodesForTesting = [10] // SQLITE_IOERR
            }
        }
        let manager = LocalStorageBudgetManager(db: fixture.db)
        manager.referenceScanChunkBudgetNanoseconds = .max

        XCTAssertThrowsError(try manager.cleanupExpired(now: Date(timeIntervalSince1970: 4_000_000), compact: false))
        fixture.db.beforeStatementStepForTesting = nil

        XCTAssertGreaterThan(terminalScanSteps, LocalStorageBudgetManager.referenceScanChunkRows,
                             "the failure must hit mid-scan, after a chunk was read")
        XCTAssertEqual(try rowCount(fixture.db, "rc_reversible_content"), 2, "no original is deleted after a failed scan")
        XCTAssertEqual(try rowCount(fixture.db, "agent_stream_events"), 1,
                       "the pass stops at the failure; later stages do not run")
    }

    /// WHY: diagnostics rows are deleted in short per-batch transactions. A
    /// failure in a later batch must reach the caller, roll back only that
    /// batch, and leave earlier committed work (the orphan delete, the first
    /// batch) in place, never touching a referenced original.
    func test_streamDeleteBatchFailureThrowsAndKeepsOnlyCommittedBatches() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.directory) }
        let store = ReversibleContentStore(db: fixture.db)
        let old = Date(timeIntervalSince1970: 1)
        let orphan = try store.store("orphan", at: old)
        let referenced = try store.store("referenced", at: old)
        try TerminalOutputRepository(db: fixture.db).append(
            surfaceID: "terminal", workspaceID: nil, chunkIndex: 1,
            data: Data("Recover with \(ReversibleContentStore.marker(for: referenced))".utf8)
        )
        let chunk = LocalStorageBudgetManager.referenceScanChunkRows
        let expiredRows = chunk + 10
        let runs = AgentRunRepository(db: fixture.db)
        for seq in 1...expiredRows {
            try runs.appendStreamEvent(runId: fixture.run.id, seq: seq, kind: "old", payloadJSON: "{}")
        }
        try fixture.db.execute("UPDATE agent_stream_events SET created_at = '1970-01-01T00:00:01Z';")
        var streamDeleteSteps = 0
        fixture.db.beforeStatementStepForTesting = { sql in
            guard sql.contains("DELETE FROM \"agent_stream_events\"") else { return }
            streamDeleteSteps += 1
            // First row of the second batch.
            if streamDeleteSteps == chunk + 1 {
                fixture.db.injectedResultCodesForTesting = [10] // SQLITE_IOERR
            }
        }

        XCTAssertThrowsError(try LocalStorageBudgetManager(db: fixture.db).cleanupExpired(
            now: Date(timeIntervalSince1970: 4_000_000),
            compact: false
        ))
        fixture.db.beforeStatementStepForTesting = nil

        XCTAssertEqual(try rowCount(fixture.db, "agent_stream_events"), Int64(expiredRows - chunk),
                       "only the committed first batch is gone; the failed batch rolled back")
        XCTAssertEqual(try store.retrieveText(referenced), "referenced")
        XCTAssertNil(try store.retrieve(orphan), "the orphan delete committed before the failure stays done")
    }

    func test_attachmentCleanupWaitsForConcurrentDurableOwnerWriter() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.directory) }
        let attachmentRoot = URL(fileURLWithPath: fixture.directory)
            .appendingPathComponent("agent-attachments", isDirectory: true)
        let source = URL(fileURLWithPath: fixture.directory).appendingPathComponent("concurrent.txt")
        try Data("concurrent attachment".utf8).write(to: source)
        let store = AgentAttachmentStore(root: attachmentRoot)
        let attachment = try store.stage(path: source.path)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)],
            ofItemAtPath: attachment.path
        )
        let writerEnteredStep = DispatchSemaphore(value: 0)
        let allowWriterCommit = DispatchSemaphore(value: 0)
        let writerFinished = DispatchSemaphore(value: 0)
        let cleanupFinished = DispatchSemaphore(value: 0)
        let writerError = ErrorBox()
        let cleanupError = ErrorBox()

        fixture.db.beforeStatementStepForTesting = { sql in
            guard sql.contains("INSERT INTO agent_messages") else { return }
            writerEnteredStep.signal()
            _ = allowWriterCommit.wait(timeout: .now() + 2)
        }
        DispatchQueue.global().async {
            do {
                try AgentMessageRepository(db: fixture.db).append(AgentMessage(
                    threadId: fixture.thread.id,
                    role: .user,
                    content: "durable owner",
                    attachments: [attachment]
                ))
            } catch {
                writerError.record(error)
            }
            writerFinished.signal()
        }
        XCTAssertEqual(writerEnteredStep.wait(timeout: .now() + 2), .success)

        DispatchQueue.global().async {
            do {
                _ = try LocalStorageBudgetManager(
                    db: fixture.db,
                    attachmentRoot: attachmentRoot
                ).cleanupExpired(now: Date(timeIntervalSince1970: 4_000_000), compact: false)
            } catch {
                cleanupError.record(error)
            }
            cleanupFinished.signal()
        }
        XCTAssertEqual(cleanupFinished.wait(timeout: .now() + 0.05), .timedOut,
                       "attachment cleanup must not overtake a durable owner writer")

        allowWriterCommit.signal()
        XCTAssertEqual(writerFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(cleanupFinished.wait(timeout: .now() + 2), .success)
        fixture.db.beforeStatementStepForTesting = nil

        XCTAssertNil(writerError.snapshot())
        XCTAssertNil(cleanupError.snapshot())
        XCTAssertNoThrow(try store.validatedForRetry(attachment),
                         "cleanup must observe the owner that committed before its reference scan")
    }

    func test_compactionIsSkippedWhileAgentRunIsActive() throws {
        let fixture = try makeFixture(runStatus: .running)
        defer { try? FileManager.default.removeItem(atPath: fixture.directory) }
        let store = ReversibleContentStore(db: fixture.db)
        _ = try store.store(Data(repeating: 0x78, count: 128 * 1024), at: Date(timeIntervalSince1970: 1))

        let result = try LocalStorageBudgetManager(db: fixture.db).cleanupExpired(
            now: Date(timeIntervalSince1970: 4_000_000),
            compact: true
        )

        XCTAssertFalse(result.compacted)
        XCTAssertEqual(result.compactionSkippedReason, .activeAgentRun)
        XCTAssertEqual(result.removedRows[.reversibleContent], 1,
                       "cleanup commits before optional compaction and remains independently safe")
    }

    func test_diagnosticsCleanupUsesExplicitTerminalStatusAllowlist() throws {
        let allStatuses: [AgentRunStatus] = [.pending, .running, .completed, .failed, .cancelled, .interrupted]
        for status in allStatuses {
            let fixture = try makeFixture(runStatus: status)
            defer { try? FileManager.default.removeItem(atPath: fixture.directory) }
            try AgentRunRepository(db: fixture.db).appendStreamEvent(
                runId: fixture.run.id,
                seq: 1,
                kind: "old",
                payloadJSON: "{}"
            )
            try fixture.db.execute("UPDATE agent_stream_events SET created_at = '1970-01-01T00:00:01Z';")

            let result = try LocalStorageBudgetManager(db: fixture.db).cleanupExpired(
                now: Date(timeIntervalSince1970: 4_000_000),
                compact: false
            )

            let expected = LocalStorageBudgetManager.terminalRunStatuses.contains(status) ? 1 : 0
            XCTAssertEqual(result.removedRows[.streamEvents], expected,
                           "status \(status.rawValue) must follow the explicit production terminal allowlist")
        }
    }

    func test_cleanupCommitsThenCompactsFixtureDatabaseWithoutLosingLiveRows() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.directory) }
        let store = ReversibleContentStore(db: fixture.db)
        _ = try store.store(Data(repeating: 0x78, count: 256 * 1024), at: Date(timeIntervalSince1970: 1))
        let live = try store.store("live", at: Date(timeIntervalSince1970: 3_999_999))

        let result = try LocalStorageBudgetManager(db: fixture.db).cleanupExpired(
            now: Date(timeIntervalSince1970: 4_000_000),
            compact: true
        )

        XCTAssertTrue(result.compacted, "an idle file-backed fixture with enough disk must complete checkpoint + VACUUM")
        XCTAssertNil(result.compactionSkippedReason)
        XCTAssertEqual(try store.retrieveText(live), "live", "VACUUM must preserve non-expired content byte-for-byte")
    }

    func test_productionReferenceRegistryIsUniqueAndEveryColumnExistsInMigratedSchema() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.directory) }
        let registries = [
            LocalStorageRecoveryReferenceRegistry.markerColumns,
            LocalStorageRecoveryReferenceRegistry.directHandleColumns,
            LocalStorageAttachmentReferenceRegistry.structuredColumns,
            LocalStorageAttachmentReferenceRegistry.opaqueColumns
        ]

        for references in registries {
            XCTAssertFalse(references.isEmpty)
            XCTAssertEqual(Set(references).count, references.count,
                           "entries within one reference registry must not be duplicated")
            for reference in references {
                let statement = try fixture.db.prepare(
                    "SELECT \"\(reference.column)\" FROM \"\(reference.table)\" LIMIT 0;"
                )
                XCTAssertFalse(try statement.step())
            }
        }
    }

    func test_releaseGateSoakLargeDatabaseMultipleThreadsPreservesRecoverableData() throws {
        guard ProcessInfo.processInfo.environment["RC_AGENT_STORAGE_SOAK"] == "1" else {
            throw XCTSkip("Set RC_AGENT_STORAGE_SOAK=1 for the explicit AG-038 release-gate soak.")
        }

        let startedAt = Date()
        let directory = NSTemporaryDirectory() + "RC2StorageSoak-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let db = try SQLiteDB(path: directory + "/remote-code.sqlite")
        try Schema.migrate(db)
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let reversibleStore = ReversibleContentStore(db: db)
        let attachmentRoot = URL(fileURLWithPath: directory)
            .appendingPathComponent("agent-attachments", isDirectory: true)
        let attachmentIncoming = URL(fileURLWithPath: directory)
            .appendingPathComponent("attachment-incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: attachmentIncoming, withIntermediateDirectories: true)
        let attachmentStore = AgentAttachmentStore(root: attachmentRoot)
        let manager = LocalStorageBudgetManager(db: db, attachmentRoot: attachmentRoot)
        let old = Date(timeIntervalSince1970: 1)

        func stageAttachment(index: Int, bytes: Data) throws -> AgentAttachment {
            let source = attachmentIncoming.appendingPathComponent("\(index).bin")
            try bytes.write(to: source)
            let attachment = try attachmentStore.stage(path: source.path)
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: attachment.path)
            return attachment
        }

        var threads: [AgentThread] = []
        var runs: [AgentRun] = []
        for index in 0..<12 {
            var thread = AgentThread(title: "storage-soak-\(index)", provider: .codex, model: "test")
            thread.status = .completed
            var run = AgentRun(threadId: thread.id, provider: .codex, model: "test", status: .completed)
            run.finishedAt = Date(timeIntervalSince1970: 2)
            try threadRepo.upsert(thread)
            try runRepo.upsert(run)
            threads.append(thread)
            runs.append(run)
        }

        var protected: [(handle: String, bytes: Data, attachment: AgentAttachment)] = []
        for index in 0..<threads.count {
            let bytes = Data(repeating: UInt8(index + 1), count: 256 * 1_024)
            let handle = try reversibleStore.store(bytes, at: old)
            let attachment = try stageAttachment(index: index, bytes: bytes)
            try messageRepo.append(AgentMessage(
                threadId: threads[index].id,
                role: .assistant,
                content: "Recover with \(ReversibleContentStore.marker(for: handle))",
                createdAt: old,
                attachments: [attachment]
            ))
            protected.append((handle, bytes, attachment))
        }

        var orphanHandles: [String] = []
        var orphanAttachments: [AgentAttachment] = []
        for index in 0..<64 {
            let bytes = Data(repeating: UInt8(index + 64), count: 256 * 1_024)
            orphanHandles.append(try reversibleStore.store(bytes, at: old))
            orphanAttachments.append(try stageAttachment(index: 1_000 + index, bytes: bytes))
        }

        let oldTimestamp = "1970-01-01T00:00:01Z"
        let payload = #"{"blob":""# + String(repeating: "x", count: 2_048) + #""}"#
        try db.performSync { database in
            try database.transaction {
                let stream = try database.prepare("""
                    INSERT INTO agent_stream_events(run_id, seq, event_kind, payload_json, created_at)
                    VALUES(?, ?, 'soak.old', ?, ?);
                    """)
                let provider = try database.prepare("""
                    INSERT INTO agent_provider_event_logs(
                        thread_id, run_id, event_id, provider, source, method,
                        payload_json, received_at_ms, created_at
                    ) VALUES(?, ?, ?, 'codex', 'soak', 'item/completed', ?, 1, ?);
                    """)
                for index in threads.indices {
                    for seq in 1...400 {
                        stream.reset()
                        try stream.bind(1, runs[index].id.value.uuidString)
                        try stream.bind(2, Int64(seq))
                        try stream.bind(3, payload)
                        try stream.bind(4, oldTimestamp)
                        _ = try stream.step()
                    }
                    for eventIndex in 1...200 {
                        provider.reset()
                        try provider.bind(1, threads[index].id.value.uuidString)
                        try provider.bind(2, runs[index].id.value.uuidString)
                        try provider.bind(3, "old-\(index)-\(eventIndex)")
                        try provider.bind(4, payload)
                        try provider.bind(5, oldTimestamp)
                        _ = try provider.step()
                    }
                }
            }
        }

        let seeded = try manager.snapshot()
        XCTAssertGreaterThanOrEqual(seeded.databaseBytes, 16 * 1_024 * 1_024,
                                    "the release soak must exercise a genuinely large local database")
        XCTAssertEqual(try classUsage(.streamEvents, in: seeded).rowCount, 4_800)
        XCTAssertEqual(try classUsage(.providerLogs, in: seeded).rowCount, 2_400)
        XCTAssertEqual(try classUsage(.attachmentBlobs, in: seeded).rowCount, 76)
        XCTAssertGreaterThanOrEqual(try classUsage(.attachmentBlobs, in: seeded).payloadBytes, 16 * 1_024 * 1_024,
                                    "the release soak must exercise a large attachment store, not metadata only")

        let startGate = DispatchSemaphore(value: 0)
        let work = DispatchGroup()
        let errors = ErrorBox()
        for index in threads.indices {
            work.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { work.leave() }
                startGate.wait()
                do {
                    for offset in 0..<50 {
                        try runRepo.appendStreamEvent(
                            runId: runs[index].id,
                            seq: 10_000 + offset,
                            kind: "soak.live",
                            payloadJSON: payload
                        )
                    }
                    for offset in 0..<25 {
                        try runRepo.appendProviderEventLog(
                            threadId: threads[index].id,
                            runId: runs[index].id,
                            event: ProviderRuntimeEvent(
                                id: "live-\(index)-\(offset)",
                                provider: .codex,
                                source: "soak",
                                method: "item/completed",
                                payloadJSON: payload,
                                receivedAtMs: Int64(offset + 1)
                            )
                        )
                    }
                    try messageRepo.append(AgentMessage(
                        threadId: threads[index].id,
                        role: .assistant,
                        content: "Still recover \(ReversibleContentStore.marker(for: protected[index].handle))",
                        attachments: [protected[index].attachment]
                    ))
                } catch {
                    errors.record(error)
                }
            }
        }
        work.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { work.leave() }
            startGate.wait()
            do {
                _ = try manager.cleanupExpired(now: Date(), compact: false)
            } catch {
                errors.record(error)
            }
        }
        for _ in 0...threads.count { startGate.signal() }
        XCTAssertEqual(work.wait(timeout: .now() + 60), .success,
                       "multi-thread writes and cleanup must finish within the release-gate deadline")
        XCTAssertNil(errors.snapshot())

        let cleanup = try manager.cleanupExpired(now: Date(), compact: true)
        XCTAssertTrue(cleanup.compacted, "the idle large database must checkpoint and VACUUM after safe cleanup")
        XCTAssertNil(cleanup.compactionSkippedReason)
        for item in protected {
            XCTAssertEqual(try reversibleStore.retrieve(item.handle), item.bytes,
                           "every durably referenced original must survive cleanup and compaction byte-for-byte")
            XCTAssertNoThrow(try attachmentStore.validatedForRetry(item.attachment),
                             "every durably referenced attachment must survive concurrent cleanup byte-for-byte")
        }
        for handle in orphanHandles {
            XCTAssertNil(try reversibleStore.retrieve(handle),
                         "expired unreferenced originals must be reclaimed")
        }
        for attachment in orphanAttachments {
            XCTAssertFalse(FileManager.default.fileExists(atPath: attachment.path),
                           "expired unreferenced attachment blobs must be reclaimed")
        }
        XCTAssertEqual(try classUsage(.attachmentBlobs, in: cleanup.snapshot).rowCount, 12)
        XCTAssertEqual(try classUsage(.streamEvents, in: cleanup.snapshot).rowCount, 600,
                       "only the 50 live events from each of 12 writer threads may remain")
        XCTAssertEqual(try classUsage(.providerLogs, in: cleanup.snapshot).rowCount, 300,
                       "only the 25 live provider logs from each of 12 writer threads may remain")
        XCTAssertLessThan(cleanup.snapshot.databaseBytes, seeded.databaseBytes,
                          "VACUUM must return freed pages to the filesystem")

        let foreignKeys = try db.prepare("PRAGMA foreign_key_check;")
        XCTAssertFalse(try foreignKeys.step(), "the soak must finish with zero foreign-key violations")
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 90,
                          "the bounded release soak must not stall under concurrent maintenance")
    }
}
