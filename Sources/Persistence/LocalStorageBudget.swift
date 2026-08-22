import Foundation
import CoreModel

public enum LocalStorageClass: String, CaseIterable, Sendable {
    case reversibleContent
    case attachmentBlobs
    case streamEvents
    case providerLogs

    public var displayName: String {
        switch self {
        case .reversibleContent: return "Reversible content"
        case .attachmentBlobs: return "Attachment blobs"
        case .streamEvents: return "Stream events"
        case .providerLogs: return "Provider logs"
        }
    }
}

/// One authority for evictable Agent transcript/log retention. Count protects
/// row/decoder overhead; encoded-byte limits protect large provider payloads.
/// Sized for a 16 GB MacBook class machine. When a thread or global budget is
/// near full, oldest rows are deleted so new events always admit — never a
/// user-facing "omitted / Retry" for ordinary large tool frames.
public struct AgentEventRetentionPolicy: Sendable, Equatable {
    public var streamEventCountPerThread: Int
    public var streamEventBytesPerThread: Int64
    public var providerLogCountPerThread: Int
    public var providerLogBytesPerThread: Int64
    public var streamEventBytesGlobal: Int64
    public var providerLogBytesGlobal: Int64
    public var pruneQuantumRows: Int
    public var pruneQuantumBytes: Int64

    public init(
        // Keep only recent "movements" per thread (aligned with message retention).
        streamEventCountPerThread: Int = 100,
        streamEventBytesPerThread: Int64 = 8 * 1_024 * 1_024,
        providerLogCountPerThread: Int = 100,
        providerLogBytesPerThread: Int64 = 8 * 1_024 * 1_024,
        streamEventBytesGlobal: Int64 = 64 * 1_024 * 1_024,
        providerLogBytesGlobal: Int64 = 64 * 1_024 * 1_024,
        pruneQuantumRows: Int = 64,
        pruneQuantumBytes: Int64 = 2 * 1_024 * 1_024
    ) {
        self.streamEventCountPerThread = max(1, streamEventCountPerThread)
        self.streamEventBytesPerThread = max(1, streamEventBytesPerThread)
        self.providerLogCountPerThread = max(1, providerLogCountPerThread)
        self.providerLogBytesPerThread = max(1, providerLogBytesPerThread)
        self.streamEventBytesGlobal = max(1, streamEventBytesGlobal)
        self.providerLogBytesGlobal = max(1, providerLogBytesGlobal)
        self.pruneQuantumRows = max(1, pruneQuantumRows)
        self.pruneQuantumBytes = max(1, pruneQuantumBytes)
    }

    public static let production = AgentEventRetentionPolicy()
}

public struct LocalStorageClassUsage: Sendable, Equatable {
    public let storageClass: LocalStorageClass
    public let payloadBytes: Int64
    public let rowCount: Int
    public let payloadQuotaBytes: Int64
    public let retentionDays: Int

    public init(
        storageClass: LocalStorageClass,
        payloadBytes: Int64,
        rowCount: Int,
        payloadQuotaBytes: Int64,
        retentionDays: Int
    ) {
        self.storageClass = storageClass
        self.payloadBytes = payloadBytes
        self.rowCount = rowCount
        self.payloadQuotaBytes = payloadQuotaBytes
        self.retentionDays = retentionDays
    }
}

public struct LocalStorageSnapshot: Sendable, Equatable {
    /// Logical SQLite allocation (`page_size * page_count`).
    public let databaseBytes: Int64
    /// Physical main database file size on disk.
    public let databaseFileBytes: Int64
    public let walBytes: Int64
    public let sharedMemoryBytes: Int64
    public let physicalBytes: Int64
    public let reclaimableBytes: Int64
    public let classes: [LocalStorageClassUsage]
    public let generatedAt: Date

    public init(
        databaseBytes: Int64,
        databaseFileBytes: Int64? = nil,
        walBytes: Int64 = 0,
        sharedMemoryBytes: Int64 = 0,
        reclaimableBytes: Int64,
        classes: [LocalStorageClassUsage],
        generatedAt: Date
    ) {
        self.databaseBytes = databaseBytes
        self.databaseFileBytes = databaseFileBytes ?? databaseBytes
        self.walBytes = walBytes
        self.sharedMemoryBytes = sharedMemoryBytes
        self.physicalBytes = max(0, databaseFileBytes ?? databaseBytes) + max(0, walBytes) + max(0, sharedMemoryBytes)
        self.reclaimableBytes = reclaimableBytes
        self.classes = classes
        self.generatedAt = generatedAt
    }
}

public struct LocalStoragePassiveCheckpointResult: Sendable, Equatable {
    public let busyReaders: Int
    public let walFrames: Int
    public let checkpointedFrames: Int
    public let snapshot: LocalStorageSnapshot

    public init(busyReaders: Int, walFrames: Int, checkpointedFrames: Int, snapshot: LocalStorageSnapshot) {
        self.busyReaders = busyReaders
        self.walFrames = walFrames
        self.checkpointedFrames = checkpointedFrames
        self.snapshot = snapshot
    }
}

public enum LocalStorageCompactionSkippedReason: String, Sendable, Equatable {
    case activeAgentRun
    case inMemoryDatabase
    case noReclaimablePages
    case walBusy
    case freeSpaceUnavailable
    case insufficientFreeSpace

    public var message: String {
        switch self {
        case .activeAgentRun: return "Compaction skipped while an agent is running."
        case .inMemoryDatabase: return "Compaction is unavailable for an in-memory database."
        case .noReclaimablePages: return "No free database pages need compaction."
        case .walBusy: return "Compaction skipped because another database connection is active."
        case .freeSpaceUnavailable: return "Compaction skipped because free disk space could not be verified."
        case .insufficientFreeSpace: return "Compaction skipped because there is not enough free disk space."
        }
    }
}

public struct LocalStorageCleanupResult: Sendable, Equatable {
    public let removedRows: [LocalStorageClass: Int]
    public let compacted: Bool
    public let compactionSkippedReason: LocalStorageCompactionSkippedReason?
    public let snapshot: LocalStorageSnapshot

    public init(
        removedRows: [LocalStorageClass: Int],
        compacted: Bool,
        compactionSkippedReason: LocalStorageCompactionSkippedReason?,
        snapshot: LocalStorageSnapshot
    ) {
        self.removedRows = removedRows
        self.compacted = compacted
        self.compactionSkippedReason = compactionSkippedReason
        self.snapshot = snapshot
    }
}

public struct LocalStorageReferenceColumn: Sendable, Hashable {
    public let table: String
    public let column: String

    public init(table: String, column: String) {
        self.table = table
        self.column = column
    }
}

/// Production-owned registry of durable fields that can keep a reversible
/// original reachable. Cleanup consumes this registry directly; schema fixtures
/// verify every registered table/column exists and representative marker, BLOB,
/// and bare-handle references survive cleanup.
public enum LocalStorageRecoveryReferenceRegistry {
    public static let markerColumns: [LocalStorageReferenceColumn] = [
        .init(table: "agent_messages", column: "content"),
        .init(table: "agent_stream_events", column: "payload_json"),
        .init(table: "agent_provider_event_logs", column: "payload_json"),
        .init(table: "agent_turn_snapshots", column: "payload_json"),
        .init(table: "session_snapshots", column: "payload_json"),
        .init(table: "events", column: "payload_json"),
        .init(table: "provider_session_runtime", column: "runtime_payload_json"),
        .init(table: "provider_pending_callbacks", column: "payload_json"),
        .init(table: "agent_proposed_plans", column: "markdown"),
        .init(table: "agent_turn_checkpoints", column: "checkpoint_ref"),
        .init(table: "agent_turn_checkpoints", column: "files_json"),
        .init(table: "agent_turn_checkpoints", column: "file_snapshots_json"),
        .init(table: "agent_turn_checkpoints", column: "diff_patch"),
        .init(table: "agent_turn_checkpoints", column: "file_diffs_json"),
        .init(table: "agent_queued_messages", column: "text"),
        .init(table: "agent_queued_messages", column: "attachments_json"),
        .init(table: "agent_thread_drafts", column: "text"),
        .init(table: "agent_thread_drafts", column: "attachments_json"),
        .init(table: "command_receipts", column: "result_json"),
        .init(table: "settings", column: "value"),
        .init(table: "terminal_output_chunks", column: "data"),
        .init(table: "shared_memory_blocks", column: "preview"),
        .init(table: "shared_memory_blocks", column: "metadata_json"),
        .init(table: "notifications", column: "body"),
        .init(table: "audit_log", column: "detail"),
        .init(table: "agent_thread_undo_gc_pins", column: "opaque_payload")
    ]

    public static let directHandleColumns: [LocalStorageReferenceColumn] = [
        .init(table: "shared_memory_blocks", column: "reversible_handle")
    ]
}

/// Durable fields that can retain a managed attachment blob. The three
/// structured columns are the canonical attachment owners. The opaque columns
/// are scanned conservatively for content digests so checkpoints and provider
/// recovery state cannot lose a blob they still identify.
public enum LocalStorageAttachmentReferenceRegistry {
    public static let structuredColumns: [LocalStorageReferenceColumn] = [
        .init(table: "agent_messages", column: "attachments_json"),
        .init(table: "agent_queued_messages", column: "attachments_json"),
        .init(table: "agent_thread_drafts", column: "attachments_json"),
        .init(table: "agent_thread_undo_gc_pins", column: "attachments_json")
    ]

    public static let opaqueColumns: [LocalStorageReferenceColumn] = [
        .init(table: "agent_turn_checkpoints", column: "checkpoint_ref"),
        .init(table: "agent_turn_checkpoints", column: "files_json"),
        .init(table: "agent_turn_checkpoints", column: "file_snapshots_json"),
        .init(table: "agent_turn_checkpoints", column: "diff_patch"),
        .init(table: "agent_turn_checkpoints", column: "file_diffs_json"),
        .init(table: "agent_turn_snapshots", column: "payload_json"),
        .init(table: "session_snapshots", column: "payload_json"),
        .init(table: "provider_session_runtime", column: "runtime_payload_json"),
        .init(table: "provider_pending_callbacks", column: "payload_json"),
        .init(table: "agent_thread_undo_gc_pins", column: "opaque_payload")
    ]
}

/// Operational budget and explicit cleanup for the large local-data classes.
/// Cleanup is age-based and conservative: quotas are warning thresholds, never an
/// instruction to delete live data. Reversible originals are removed only when old,
/// `ref_count == 0`, and absent from every canonical durable recovery surface below.
public final class LocalStorageBudgetManager: @unchecked Sendable {
    public static let retentionDays = 30
    /// Attachment blobs are durable user payload, so their warning threshold
    /// intentionally matches the existing reversible-content threshold. Quotas
    /// remain telemetry only and never authorize deletion of referenced data.
    public static let durableUserPayloadQuotaBytes: Int64 = 2 * 1_024 * 1_024 * 1_024
    public static let payloadQuotaBytes: [LocalStorageClass: Int64] = [
        .reversibleContent: durableUserPayloadQuotaBytes,
        .attachmentBlobs: durableUserPayloadQuotaBytes,
        .streamEvents: 256 * 1_024 * 1_024,
        .providerLogs: 256 * 1_024 * 1_024
    ]

    public static let terminalRunStatuses: Set<AgentRunStatus> = [
        .completed, .failed, .cancelled, .interrupted
    ]
    // PERF: terminal GC runs on every storage-budget check; avoid per-call map+sorted.
    private static let terminalRunStatusRawValuesSorted: [String] = terminalRunStatuses.map(\.rawValue).sorted()
    private static let terminalRunStatusPlaceholders: String = Array(repeating: "?", count: terminalRunStatuses.count).joined(separator: ", ")

    private static let markerRegex = try! NSRegularExpression(
        pattern: #"\[\[rc:([0-9a-fA-F]{64})\]\]"#
    )
    private static let digestRegex = try! NSRegularExpression(
        pattern: #"(?i)(?<![0-9a-f])([0-9a-f]{64})(?![0-9a-f])"#
    )
    private static let attachmentReferenceRegex = try! NSRegularExpression(
        pattern: #"(?i)(?<![0-9a-f])([0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})(?![0-9a-f])"#
    )
    private static let minimumVacuumHeadroomBytes: Int64 = 64 * 1_024 * 1_024

    private let db: SQLiteDB
    private let fileManager: FileManager
    private let attachmentRoot: URL?
    var beforeAttachmentCleanupLockForTesting: (() -> Void)?
    // PERF: durableReferencedAttachments allocated JSONDecoder per cleanup/snapshot
    // scan of structured attachment columns (many rows). Shared under a short lock
    // so concurrent budget managers avoid per-scan codec construction.
    private let attachmentReferenceCodecLock = NSLock()
    private let attachmentReferenceDecoder = JSONDecoder()

    public init(
        db: SQLiteDB,
        fileManager: FileManager = .default,
        attachmentRoot: URL? = nil
    ) {
        self.db = db
        self.fileManager = fileManager
        self.attachmentRoot = attachmentRoot?.standardizedFileURL
    }

    public func snapshot(now: Date = Date()) throws -> LocalStorageSnapshot {
        try db.performSync { database in
            let pageSize = try scalar(database, "PRAGMA page_size;")
            let pageCount = try scalar(database, "PRAGMA page_count;")
            let freePages = try scalar(database, "PRAGMA freelist_count;")
            let classes = try LocalStorageClass.allCases.map { storageClass in
                let values = storageClass == .attachmentBlobs
                    ? try attachmentUsage()
                    : try usage(database, storageClass: storageClass)
                return LocalStorageClassUsage(
                    storageClass: storageClass,
                    payloadBytes: values.bytes,
                    rowCount: values.rows,
                    payloadQuotaBytes: Self.payloadQuotaBytes[storageClass] ?? 0,
                    retentionDays: Self.retentionDays
                )
            }
            let physical = physicalDatabaseFiles()
            return LocalStorageSnapshot(
                databaseBytes: pageSize * pageCount,
                databaseFileBytes: physical.database,
                walBytes: physical.wal,
                sharedMemoryBytes: physical.sharedMemory,
                reclaimableBytes: pageSize * freePages,
                classes: classes,
                generatedAt: now
            )
        }
    }

    /// Non-blocking lifecycle maintenance. PASSIVE never waits for readers and
    /// never performs a VACUUM; SQLite reports any busy readers to the caller.
    public func passiveCheckpoint(now: Date = Date()) throws -> LocalStoragePassiveCheckpointResult {
        let values = try db.performSync { database -> (Int, Int, Int) in
            let statement = try database.prepare("PRAGMA wal_checkpoint(PASSIVE);")
            guard try statement.step() else { return (0, 0, 0) }
            return (
                Int(statement.columnInt64(0)),
                Int(statement.columnInt64(1)),
                Int(statement.columnInt64(2))
            )
        }
        return LocalStoragePassiveCheckpointResult(
            busyReaders: values.0,
            walFrames: values.1,
            checkpointedFrames: values.2,
            snapshot: try snapshot(now: now)
        )
    }

    private func physicalDatabaseFiles() -> (database: Int64, wal: Int64, sharedMemory: Int64) {
        guard db.path != ":memory:" else { return (0, 0, 0) }
        func size(_ path: String) -> Int64 {
            guard let raw = try? fileManager.attributesOfItem(atPath: path)[.size] as? NSNumber else { return 0 }
            return max(0, raw.int64Value)
        }
        return (size(db.path), size(db.path + "-wal"), size(db.path + "-shm"))
    }

    /// Delete expired rows in one transaction, then optionally compact only after
    /// the cleanup COMMIT. VACUUM failures throw; safety preflight failures return a
    /// visible skip reason while preserving the already-safe cleanup result.
    public func cleanupExpired(now: Date = Date(), compact: Bool = true) throws -> LocalStorageCleanupResult {
        let cutoffDate = now.addingTimeInterval(-Double(Self.retentionDays) * 86_400)
        let cutoffText = iso.string(from: cutoffDate)
        let cutoffMs = Int64(cutoffDate.timeIntervalSince1970 * 1_000)

        let removed = try db.performSync { database in
            try database.transaction {
                try deleteExpiredThreadUndoGCPins(database, expiresAtOrBefore: now)
                let referencedHandles = try durableReferencedHandles(database)
                let reversible = try deleteExpiredReversibleContent(
                    database,
                    cutoffMs: cutoffMs,
                    referencedHandles: referencedHandles
                )
                let streamEvents = try deleteExpiredTerminalRunRows(
                    database,
                    table: "agent_stream_events",
                    cutoffText: cutoffText
                )
                let providerLogs = try deleteExpiredTerminalRunRows(
                    database,
                    table: "agent_provider_event_logs",
                    cutoffText: cutoffText
                )
                let attachmentReferences = try durableReferencedAttachments(database)
                let attachmentBlobs = try deleteExpiredAttachmentBlobs(
                    cutoffDate: cutoffDate,
                    references: attachmentReferences
                )
                return [
                    LocalStorageClass.reversibleContent: reversible,
                    LocalStorageClass.attachmentBlobs: attachmentBlobs,
                    LocalStorageClass.streamEvents: streamEvents,
                    LocalStorageClass.providerLogs: providerLogs
                ]
            }
        }

        var compacted = false
        var skippedReason: LocalStorageCompactionSkippedReason?
        if compact {
            let decision = try compactDatabaseIfSafe()
            compacted = decision.compacted
            skippedReason = decision.reason
        }
        return LocalStorageCleanupResult(
            removedRows: removed,
            compacted: compacted,
            compactionSkippedReason: skippedReason,
            snapshot: try snapshot(now: now)
        )
    }

    private func deleteExpiredThreadUndoGCPins(
        _ database: SQLiteDB,
        expiresAtOrBefore date: Date
    ) throws {
        let statement = try database.prepare(
            "DELETE FROM agent_thread_undo_gc_pins WHERE expires_at <= ?;"
        )
        defer { statement.reset() }
        try statement.bind(1, AgentThreadUndoGCPinTimestamp.cutoffString(from: date))
        _ = try statement.step()
    }

    private func usage(_ database: SQLiteDB, storageClass: LocalStorageClass) throws -> (bytes: Int64, rows: Int) {
        let sql: String
        switch storageClass {
        case .reversibleContent:
            sql = "SELECT COALESCE(SUM(byte_count), 0), COUNT(*) FROM rc_reversible_content;"
        case .attachmentBlobs:
            preconditionFailure("Attachment usage is filesystem-backed.")
        case .streamEvents:
            sql = """
                SELECT COALESCE(SUM(
                    length(CAST(event_kind AS BLOB)) + length(CAST(payload_json AS BLOB))
                ), 0), COUNT(*) FROM agent_stream_events;
                """
        case .providerLogs:
            sql = """
                SELECT COALESCE(SUM(
                    length(CAST(source AS BLOB)) + length(CAST(method AS BLOB)) +
                    length(CAST(payload_json AS BLOB))
                ), 0), COUNT(*) FROM agent_provider_event_logs;
                """
        }
        let statement = try database.prepare(sql)
        defer { statement.reset() }
        guard try statement.step() else { return (0, 0) }
        return (statement.columnInt64(0), Int(statement.columnInt64(1)))
    }

    private func attachmentUsage() throws -> (bytes: Int64, rows: Int) {
        guard let attachmentRoot,
              fileManager.fileExists(atPath: attachmentRoot.path) else { return (0, 0) }
        return try AgentAttachmentStorageSynchronization.withLock(root: attachmentRoot) {
            var bytes: Int64 = 0
            var rows = 0
            for url in try attachmentFiles(in: attachmentRoot) {
                let values = try url.resourceValues(forKeys: [.fileSizeKey])
                bytes += Int64(values.fileSize ?? 0)
                rows += 1
            }
            return (bytes, rows)
        }
    }

    private func scalar(_ database: SQLiteDB, _ sql: String) throws -> Int64 {
        let statement = try database.prepare(sql)
        defer { statement.reset() }
        guard try statement.step() else { return 0 }
        return statement.columnInt64(0)
    }

    private func durableReferencedHandles(_ database: SQLiteDB) throws -> Set<String> {
        var handles = Set<String>()
        for reference in LocalStorageRecoveryReferenceRegistry.markerColumns {
            let statement = try database.prepare(
                "SELECT \(quoted(reference.column)) FROM \(quoted(reference.table)) WHERE \(quoted(reference.column)) IS NOT NULL;"
            )
            defer { statement.reset() }
            while try statement.step() {
                guard let data = statement.columnBlob(0) else { continue }
                handles.formUnion(Self.markerHandles(in: data))
            }
        }
        for reference in LocalStorageRecoveryReferenceRegistry.directHandleColumns {
            let statement = try database.prepare(
                "SELECT \(quoted(reference.column)) FROM \(quoted(reference.table)) WHERE \(quoted(reference.column)) IS NOT NULL;"
            )
            defer { statement.reset() }
            while try statement.step() {
                guard let raw = statement.columnText(0)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                      Self.isSHA256HexDigest(raw) else { continue }
                handles.insert(raw)
            }
        }
        return handles
    }

    private static func markerHandles(in data: Data) -> Set<String> {
        let text = String(decoding: data, as: UTF8.self)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var handles = Set<String>()
        markerRegex.enumerateMatches(in: text, range: range) { result, _, _ in
            guard let result,
                  let swiftRange = Range(result.range(at: 1), in: text) else { return }
            handles.insert(String(text[swiftRange]).lowercased())
        }
        return handles
    }

    private struct AttachmentReferences {
        var digests = Set<String>()
        var referenceIDs = Set<String>()
        var paths = Set<String>()
    }

    private func durableReferencedAttachments(_ database: SQLiteDB) throws -> AttachmentReferences {
        var references = AttachmentReferences()
        // Decode under one lock for the full structured-column scan so GC sweeps
        // do not re-enter the codec lock per attachment row.
        attachmentReferenceCodecLock.lock()
        defer { attachmentReferenceCodecLock.unlock() }
        for reference in LocalStorageAttachmentReferenceRegistry.structuredColumns {
            let statement = try database.prepare(
                "SELECT \(quoted(reference.column)) FROM \(quoted(reference.table)) WHERE \(quoted(reference.column)) IS NOT NULL;"
            )
            defer { statement.reset() }
            while try statement.step() {
                guard let data = statement.columnBlob(0) else { continue }
                if let attachments = try? attachmentReferenceDecoder.decode([AgentAttachment].self, from: data) {
                    for attachment in attachments {
                        if let digest = validDigest(attachment.sha256) {
                            references.digests.insert(digest)
                        }
                        if let digest = validDigest(attachment.id) {
                            references.digests.insert(digest)
                        } else if let referenceID = validAttachmentReferenceID(attachment.id) {
                            references.referenceIDs.insert(referenceID)
                        }
                        if let path = managedAttachmentPath(attachment.path) {
                            references.paths.insert(path)
                        }
                    }
                } else {
                    references.digests.formUnion(Self.digests(in: data))
                    references.referenceIDs.formUnion(Self.attachmentReferenceIDs(in: data))
                }
            }
        }
        for reference in LocalStorageAttachmentReferenceRegistry.opaqueColumns {
            let statement = try database.prepare(
                "SELECT \(quoted(reference.column)) FROM \(quoted(reference.table)) WHERE \(quoted(reference.column)) IS NOT NULL;"
            )
            defer { statement.reset() }
            while try statement.step() {
                guard let data = statement.columnBlob(0) else { continue }
                references.digests.formUnion(Self.digests(in: data))
                references.referenceIDs.formUnion(Self.attachmentReferenceIDs(in: data))
            }
        }
        return references
    }

    private static func digests(in data: Data) -> Set<String> {
        let text = String(decoding: data, as: UTF8.self)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var digests = Set<String>()
        digestRegex.enumerateMatches(in: text, range: range) { result, _, _ in
            guard let result,
                  let swiftRange = Range(result.range(at: 1), in: text) else { return }
            digests.insert(String(text[swiftRange]).lowercased())
        }
        return digests
    }

    private static func attachmentReferenceIDs(in data: Data) -> Set<String> {
        let text = String(decoding: data, as: UTF8.self)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var referenceIDs = Set<String>()
        attachmentReferenceRegex.enumerateMatches(in: text, range: range) { result, _, _ in
            guard let result,
                  let swiftRange = Range(result.range(at: 1), in: text) else { return }
            referenceIDs.insert(String(text[swiftRange]).lowercased())
        }
        return referenceIDs
    }

    private func deleteExpiredAttachmentBlobs(
        cutoffDate: Date,
        references: AttachmentReferences
    ) throws -> Int {
        guard let attachmentRoot,
              fileManager.fileExists(atPath: attachmentRoot.path) else { return 0 }
        beforeAttachmentCleanupLockForTesting?()
        return try AgentAttachmentStorageSynchronization.withLock(root: attachmentRoot) {
            var protectedDigests = references.digests
            protectedDigests.formUnion(
                try attachmentDigests(for: references.referenceIDs, at: attachmentRoot)
            )
            var removed = 0
            for url in try attachmentFiles(in: attachmentRoot) {
                // Read the timestamp under the same root lock as staging. A
                // reused digest refreshes this lease before cleanup can decide.
                let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
                guard let modifiedAt = values.contentModificationDate,
                      modifiedAt < cutoffDate else { continue }
                let path = url.standardizedFileURL.path
                let digest = validDigest(url.deletingPathExtension().lastPathComponent)
                guard !references.paths.contains(path),
                      !(digest.map(protectedDigests.contains) == true) else { continue }
                try fileManager.removeItem(at: url)
                if let digest {
                    removeAttachmentMetadata(for: digest, at: attachmentRoot)
                }
                removed += 1
            }
            return removed
        }
    }

    private func attachmentFiles(in root: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ).filter { url in
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
                return false
            }
            return values.isRegularFile == true && values.isSymbolicLink != true
        }
    }

    private func managedAttachmentPath(_ rawPath: String) -> String? {
        guard let attachmentRoot else { return nil }
        let candidate = URL(fileURLWithPath: rawPath).standardizedFileURL
        let rootPath = attachmentRoot.path.hasSuffix("/") ? attachmentRoot.path : attachmentRoot.path + "/"
        guard candidate.path.hasPrefix(rootPath) else { return nil }
        return candidate.path
    }

    /// PERF: O(1) length + linear hex scan (no recompiled `^[0-9a-f]{64}$` per row).
    private static func isSHA256HexDigest(_ value: String) -> Bool {
        guard value.utf8.count == 64 else { return false }
        return value.utf8.allSatisfy { b in
            (0x30...0x39).contains(b) || (0x61...0x66).contains(b)
        }
    }

    private func validDigest(_ rawValue: String?) -> String? {
        guard let value = rawValue?.lowercased(),
              Self.isSHA256HexDigest(value) else { return nil }
        return value
    }

    private func validAttachmentReferenceID(_ rawValue: String?) -> String? {
        guard let value = rawValue?.lowercased(),
              AgentAttachmentStore.isReferenceID(value) else { return nil }
        return value
    }

    private func attachmentDigests(for referenceIDs: Set<String>, at root: URL) throws -> Set<String> {
        let metadataRoot = root.appendingPathComponent(".metadata", isDirectory: true)
        var digests = Set<String>()
        for referenceID in referenceIDs {
            let url = metadataRoot.appendingPathComponent("\(referenceID).json")
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let digest = validDigest(object["digest"] as? String) else { continue }
            digests.insert(digest)
        }
        return digests
    }

    private func removeAttachmentMetadata(for digest: String, at root: URL) {
        let metadataRoot = root.appendingPathComponent(".metadata", isDirectory: true)
        guard let files = try? fileManager.contentsOfDirectory(
            at: metadataRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for url in files where url.pathExtension == "json" {
            let referenceID = url.deletingPathExtension().lastPathComponent.lowercased()
            if referenceID == digest {
                try? fileManager.removeItem(at: url)
                continue
            }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  validDigest(object["digest"] as? String) == digest else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    private func deleteExpiredReversibleContent(
        _ database: SQLiteDB,
        cutoffMs: Int64,
        referencedHandles: Set<String>
    ) throws -> Int {
        let candidates = try database.prepare("""
            SELECT handle FROM rc_reversible_content
            WHERE ref_count <= 0 AND last_access_ms < ?;
            """)
        defer { candidates.reset() }
        try candidates.bind(1, cutoffMs)
        var handlesToDelete: [String] = []
        while try candidates.step() {
            guard let handle = candidates.columnText(0)?.lowercased(),
                  !referencedHandles.contains(handle) else { continue }
            handlesToDelete.append(handle)
        }
        let delete = try database.prepare("""
            DELETE FROM rc_reversible_content
            WHERE handle = ? AND ref_count <= 0 AND last_access_ms < ?;
            """)
        defer { delete.reset() }
        var removed = 0
        for handle in handlesToDelete {
            delete.reset()
            try delete.bind(1, handle)
            try delete.bind(2, cutoffMs)
            _ = try delete.step()
            removed += Int(try scalar(database, "SELECT changes();"))
        }
        return removed
    }

    private func deleteExpiredTerminalRunRows(
        _ database: SQLiteDB,
        table: String,
        cutoffText: String
    ) throws -> Int {
        let statuses = Self.terminalRunStatusRawValuesSorted
        let placeholders = Self.terminalRunStatusPlaceholders
        let count = try database.prepare("""
            SELECT COUNT(*) FROM \(quoted(table)) AS storage_row
            JOIN agent_runs ON agent_runs.id = storage_row.run_id
            WHERE storage_row.created_at < ?
              AND agent_runs.status IN (\(placeholders));
            """)
        defer { count.reset() }
        try count.bind(1, cutoffText)
        for (offset, status) in statuses.enumerated() {
            try count.bind(Int32(offset + 2), status)
        }
        let removed = (try count.step()) ? Int(count.columnInt64(0)) : 0

        let delete = try database.prepare("""
            DELETE FROM \(quoted(table))
            WHERE created_at < ?
              AND run_id IN (
                  SELECT id FROM agent_runs WHERE status IN (\(placeholders))
              );
            """)
        defer { delete.reset() }
        try delete.bind(1, cutoffText)
        for (offset, status) in statuses.enumerated() {
            try delete.bind(Int32(offset + 2), status)
        }
        _ = try delete.step()
        return removed
    }

    private func compactDatabaseIfSafe() throws -> (compacted: Bool, reason: LocalStorageCompactionSkippedReason?) {
        guard db.path != ":memory:" else { return (false, .inMemoryDatabase) }
        let preflight = try db.performSync { database -> LocalStorageCompactionSkippedReason? in
            if try scalar(database, "SELECT COUNT(*) FROM agent_runs WHERE status IN ('pending', 'running');") > 0 {
                return .activeAgentRun
            }
            let freePages = try scalar(database, "PRAGMA freelist_count;")
            guard freePages > 0 else { return .noReclaimablePages }
            return nil
        }
        if let preflight { return (false, preflight) }

        let parent = (db.path as NSString).deletingLastPathComponent
        guard let attributes = try? fileManager.attributesOfFileSystem(forPath: parent),
              let freeBytes = (attributes[.systemFreeSize] as? NSNumber)?.int64Value else {
            return (false, .freeSpaceUnavailable)
        }
        let allocatedBytes = try snapshot().databaseBytes
        guard freeBytes >= allocatedBytes + Self.minimumVacuumHeadroomBytes else {
            return (false, .insufficientFreeSpace)
        }

        return try db.performSync { database in
            // Final active-run and freelist checks share one serialized closure
            // with checkpoint + VACUUM, closing the preflight/maintenance gap.
            if try scalar(database, "SELECT COUNT(*) FROM agent_runs WHERE status IN ('pending', 'running');") > 0 {
                return (false, .activeAgentRun)
            }
            if try scalar(database, "PRAGMA freelist_count;") <= 0 {
                return (false, .noReclaimablePages)
            }
            let checkpoint = try database.prepare("PRAGMA wal_checkpoint(TRUNCATE);")
            defer { checkpoint.reset() }
            guard try checkpoint.step(), checkpoint.columnInt64(0) == 0 else {
                return (false, .walBusy)
            }
            checkpoint.reset()

            // VACUUM starts its own SQLite transaction. It remains outside the
            // cleanup transaction and inside the serialized maintenance section.
            try database.execute("VACUUM;")
            return (true, nil)
        }
    }

    private func quoted(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
