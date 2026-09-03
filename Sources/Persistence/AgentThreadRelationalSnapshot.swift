import Foundation
import SQLite3
import CoreModel

/// Exact, transient SQLite rows owned by one thread-delete action.
/// The snapshot exists only for the UI undo window; it is never persisted.
public struct AgentThreadRelationalSnapshot: Sendable, Equatable {
    public struct Table: Sendable, Equatable {
        let name: String
        let columns: [String]
        let rows: [[Value]]
    }

    enum Value: Sendable, Equatable {
        case null
        case integer(Int64)
        case real(Double)
        case text(String)
        case blob(Data)
    }

    public let threads: [AgentThread]
    let tables: [Table]
}

public enum AgentThreadRelationalDeletionError: Error, Equatable {
    case forkRecoveryPending
}

public struct AgentThreadUndoGCPin: Sendable, Equatable {
    public let id: String
    public let expiresAt: Date

    public init(id: String, expiresAt: Date) {
        self.id = id
        self.expiresAt = expiresAt
    }
}

enum AgentThreadUndoGCPinTimestamp {
    static func expiryString(from date: Date) -> String {
        string(from: date, roundedMilliseconds: ceil)
    }

    static func cutoffString(from date: Date) -> String {
        string(from: date, roundedMilliseconds: floor)
    }

    static func timestampString(from date: Date) -> String {
        string(from: date, roundedMilliseconds: floor)
    }

    // PERF: ISO8601DateFormatter construction is expensive. Share one fractional
    // formatter under a short lock (formatter is not thread-safe; undo GC and
    // thread-delete paths can run concurrently across repositories).
    private static let fractionalLock = NSLock()
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func string(
        from date: Date,
        roundedMilliseconds: (Double) -> Double
    ) -> String {
        let milliseconds = roundedMilliseconds(date.timeIntervalSince1970 * 1_000)
        let safeDate = Date(timeIntervalSince1970: milliseconds / 1_000)
        fractionalLock.lock()
        let text = fractionalFormatter.string(from: safeDate)
        fractionalLock.unlock()
        return text
    }
}

public extension AgentThreadRepository {
    /// Capture the complete thread-owned relational graph and delete its parent
    /// rows in one transaction. A failed capture or delete rolls back everything.
    func deleteWithRelationalSnapshot(
        ids: [AgentThreadID],
        undoGCPin: AgentThreadUndoGCPin? = nil
    ) throws -> AgentThreadRelationalSnapshot {
        let rawIDs = ids.map { $0.value.uuidString }
        guard !rawIDs.isEmpty else { return AgentThreadRelationalSnapshot(threads: [], tables: []) }
        return try db.performSync { database in
            try database.transaction {
                let forkPredicate = Self.forkIntentPredicate(rawIDs.count)
                let recoverableFork = try database.prepare("""
                    SELECT 1 FROM agent_thread_fork_intents
                    WHERE (\(forkPredicate))
                      AND state IN ('prepared', 'provider_created', 'compensating')
                    LIMIT 1;
                    """)
                try Self.bind(rawIDs + rawIDs, to: recoverableFork)
                guard try recoverableFork.step() == false else {
                    throw AgentThreadRelationalDeletionError.forkRecoveryPending
                }
                let threads = try ids.compactMap { try self.get(id: $0) }
                let snapshot = try Self.captureRelationalSnapshot(
                    database: database,
                    threadIDs: rawIDs,
                    threads: threads
                )
                if let undoGCPin {
                    try Self.persistUndoGCPin(undoGCPin, snapshot: snapshot, database: database)
                }
                let forkDelete = try database.prepare(
                    "DELETE FROM agent_thread_fork_intents WHERE \(forkPredicate);"
                )
                try Self.bind(rawIDs + rawIDs, to: forkDelete)
                _ = try forkDelete.step()
                let statement = try database.prepare(
                    "DELETE FROM agent_threads WHERE id IN (\(Self.placeholders(rawIDs.count)));"
                )
                try Self.bind(rawIDs, to: statement)
                _ = try statement.step()
                return snapshot
            }
        }
    }

    /// Compatibility wrapper for callers that do not consume retention victims.
    /// Restore still enforces the hard workspace cap atomically.
    func restore(_ snapshot: AgentThreadRelationalSnapshot) throws {
        _ = try restoreEnforcingWorkspaceThreadLimit(snapshot)
    }

    /// Restore every captured row and enforce each affected workspace's hard cap
    /// in the same transaction. Restored IDs are never eligible victims. Any
    /// conflict, corrupt row, victim-delete failure, or protected saturation
    /// rolls the restored graph and every tentative victim delete back together.
    @discardableResult
    func restoreEnforcingWorkspaceThreadLimit(
        _ snapshot: AgentThreadRelationalSnapshot,
        limit: Int = AgentThreadRepository.maxThreadsPerWorkspace
    ) throws -> [AgentThreadID] {
        try db.performSync { database in
            try database.transaction {
                try Self.restoreRelationalSnapshotInCurrentTransaction(snapshot, database: database)
                var restoredIDs = Set<AgentThreadID>()
                restoredIDs.reserveCapacity(snapshot.threads.count)
                var workspaceIDSet = Set<WorkspaceID>()
                for thread in snapshot.threads {
                    restoredIDs.insert(thread.id)
                    if let workspaceId = thread.workspaceId { workspaceIDSet.insert(workspaceId) }
                }
                let workspaceIDs = workspaceIDSet.sorted {
                    $0.value.uuidString < $1.value.uuidString
                }
                var prunedThreadIDs: [AgentThreadID] = []
                for workspaceID in workspaceIDs {
                    prunedThreadIDs.append(contentsOf: try enforceWorkspaceThreadLimitInCurrentTransaction(
                        workspaceId: workspaceID,
                        limit: limit,
                        excluding: restoredIDs
                    ))
                }
                return prunedThreadIDs
            }
        }
    }

    func removeUndoGCPin(id: String) throws {
        let statement = try db.prepare(
            "DELETE FROM agent_thread_undo_gc_pins WHERE owner_id = ?;"
        )
        try statement.bind(1, id)
        _ = try statement.step()
    }
}

private extension AgentThreadRepository {
    struct TableSpec {
        let name: String
        let predicate: String
        let bindingRepeats: Int

        init(name: String, predicate: String, bindingRepeats: Int = 1) {
            self.name = name
            self.predicate = predicate
            self.bindingRepeats = bindingRepeats
        }
    }

    static let relationalTableSpecs: [TableSpec] = [
        TableSpec(name: "agent_threads", predicate: "id IN (%@)"),
        TableSpec(name: "agent_messages", predicate: "thread_id IN (%@)"),
        TableSpec(name: "agent_message_rcw1_requests", predicate: "message_id IN (SELECT id FROM agent_messages WHERE thread_id IN (%@))"),
        TableSpec(name: "agent_message_rcw1_responses", predicate: "message_id IN (SELECT id FROM agent_messages WHERE thread_id IN (%@))"),
        TableSpec(name: "agent_message_token_saver_display_preferences", predicate: "message_id IN (SELECT id FROM agent_messages WHERE thread_id IN (%@))"),
        TableSpec(name: "agent_runs", predicate: "thread_id IN (%@)"),
        TableSpec(name: "token_saver_run_winner_receipts", predicate: "run_id IN (SELECT id FROM agent_runs WHERE thread_id IN (%@))"),
        TableSpec(name: "token_saver_run_arm_receipts", predicate: "run_id IN (SELECT run_id FROM token_saver_run_winner_receipts WHERE thread_id IN (%@))"),
        TableSpec(name: "token_saver_context_slot_receipts", predicate: "run_id IN (SELECT id FROM agent_runs WHERE thread_id IN (%@))"),
        TableSpec(name: "token_saver_context_slot_arm_receipts", predicate: "run_id IN (SELECT run_id FROM token_saver_context_slot_receipts WHERE run_id IN (SELECT id FROM agent_runs WHERE thread_id IN (%@)))"),
        TableSpec(name: "agent_stream_events", predicate: "run_id IN (SELECT id FROM agent_runs WHERE thread_id IN (%@))"),
        TableSpec(name: "agent_item_host_attestations", predicate: "run_id IN (SELECT id FROM agent_runs WHERE thread_id IN (%@))"),
        TableSpec(name: "agent_turn_snapshots", predicate: "thread_id IN (%@)"),
        TableSpec(name: "provider_session_runtime", predicate: "thread_id IN (%@)"),
        TableSpec(name: "provider_pending_callbacks", predicate: "thread_id IN (%@)"),
        TableSpec(name: "agent_proposed_plans", predicate: "thread_id IN (%@)"),
        TableSpec(name: "agent_turn_checkpoints", predicate: "thread_id IN (%@)"),
        TableSpec(name: "agent_provider_event_logs", predicate: "thread_id IN (%@)"),
        TableSpec(name: "agent_queued_messages", predicate: "thread_id IN (%@)"),
        TableSpec(name: "agent_thread_drafts", predicate: "thread_id IN (%@)"),
        TableSpec(
            name: "agent_thread_fork_intents",
            predicate: "source_thread_id IN (%@) OR child_thread_id IN (%@)",
            bindingRepeats: 2
        )
    ]

    static func restoreRelationalSnapshotInCurrentTransaction(
        _ snapshot: AgentThreadRelationalSnapshot,
        database: SQLiteDB
    ) throws {
        for table in snapshot.tables where !table.rows.isEmpty {
            let columns = table.columns.map { "\"\($0)\"" }.joined(separator: ", ")
            let values = placeholders(table.columns.count)
            let sql = "INSERT INTO \"\(table.name)\" (\(columns)) VALUES (\(values));"
            for row in table.rows {
                let statement = try database.prepare(sql)
                for (offset, value) in row.enumerated() {
                    try bind(value, at: Int32(offset + 1), to: statement)
                }
                _ = try statement.step()
            }
        }
    }

    static func captureRelationalSnapshot(
        database: SQLiteDB,
        threadIDs: [String],
        threads: [AgentThread]
    ) throws -> AgentThreadRelationalSnapshot {
        let placeholders = placeholders(threadIDs.count)
        let tables = try relationalTableSpecs.map { spec -> AgentThreadRelationalSnapshot.Table in
            let predicate = spec.bindingRepeats == 1
                ? String(format: spec.predicate, placeholders)
                : String(format: spec.predicate, placeholders, placeholders)
            let statement = try database.prepare(
                "SELECT * FROM \"\(spec.name)\" WHERE \(predicate) ORDER BY rowid ASC;"
            )
            try bind(Array(repeating: threadIDs, count: spec.bindingRepeats).flatMap { $0 }, to: statement)
            let columnCount = Int(sqlite3_column_count(statement.handle))
            let columns = (0..<columnCount).map { index in
                String(cString: sqlite3_column_name(statement.handle, Int32(index)))
            }
            var rows: [[AgentThreadRelationalSnapshot.Value]] = []
            while try statement.step() {
                rows.append((0..<columnCount).map { value(in: statement, at: Int32($0)) })
            }
            return .init(name: spec.name, columns: columns, rows: rows)
        }
        return AgentThreadRelationalSnapshot(threads: threads, tables: tables)
    }

    // PERF: persistUndoGCPin decoded structured attachment columns and encoded
    // the pin payload with fresh codecs on every thread-delete undo pin. Share
    // process-wide codecs under a short lock (JSONEncoder/Decoder are not
    // thread-safe; concurrent deletes can pin in parallel) so multi-row scans
    // avoid per-call construction while pin JSON is unchanged.
    private static let undoGCPinCodecLock = NSLock()
    private static let undoGCPinDecoder = JSONDecoder()
    private static let undoGCPinEncoder = JSONEncoder()

    static func persistUndoGCPin(
        _ pin: AgentThreadUndoGCPin,
        snapshot: AgentThreadRelationalSnapshot,
        database: SQLiteDB
    ) throws {
        var attachments: [AgentAttachment] = []
        var opaqueParts: [String] = []
        let structured = Set(LocalStorageAttachmentReferenceRegistry.structuredColumns.map {
            "\($0.table).\($0.column)"
        })
        let opaque = Set(LocalStorageAttachmentReferenceRegistry.opaqueColumns.map {
            "\($0.table).\($0.column)"
        })

        for table in snapshot.tables {
            for (columnIndex, column) in table.columns.enumerated() {
                let key = "\(table.name).\(column)"
                guard structured.contains(key) || opaque.contains(key) else { continue }
                for row in table.rows {
                    guard row.indices.contains(columnIndex),
                          let data = data(from: row[columnIndex]) else { continue }
                    if structured.contains(key) {
                        undoGCPinCodecLock.lock()
                        let decoded = try? undoGCPinDecoder.decode(
                            [AgentAttachment].self,
                            from: data
                        )
                        undoGCPinCodecLock.unlock()
                        if let decoded {
                            attachments.append(contentsOf: decoded)
                        } else {
                            opaqueParts.append(String(decoding: data, as: UTF8.self))
                        }
                    } else {
                        opaqueParts.append(String(decoding: data, as: UTF8.self))
                    }
                }
            }
        }

        undoGCPinCodecLock.lock()
        let attachmentsData = try undoGCPinEncoder.encode(attachments)
        undoGCPinCodecLock.unlock()
        let attachmentsJSON = String(decoding: attachmentsData, as: UTF8.self)
        let statement = try database.prepare("""
            INSERT INTO agent_thread_undo_gc_pins(
                owner_id, attachments_json, opaque_payload, expires_at, created_at
            ) VALUES(?, ?, ?, ?, ?)
            ON CONFLICT(owner_id) DO UPDATE SET
                attachments_json=excluded.attachments_json,
                opaque_payload=excluded.opaque_payload,
                expires_at=excluded.expires_at;
            """)
        try statement.bind(1, pin.id)
        try statement.bind(2, attachmentsJSON)
        try statement.bind(3, opaqueParts.joined(separator: "\n"))
        try statement.bind(4, AgentThreadUndoGCPinTimestamp.expiryString(from: pin.expiresAt))
        try statement.bind(5, AgentThreadUndoGCPinTimestamp.timestampString(from: Date()))
        _ = try statement.step()
    }

    static func data(from value: AgentThreadRelationalSnapshot.Value) -> Data? {
        switch value {
        case .text(let text): return Data(text.utf8)
        case .blob(let data): return data
        case .null, .integer, .real: return nil
        }
    }

    static func value(
        in statement: SQLiteStatement,
        at index: Int32
    ) -> AgentThreadRelationalSnapshot.Value {
        switch sqlite3_column_type(statement.handle, index) {
        case SQLITE_INTEGER:
            return .integer(statement.columnInt64(index))
        case SQLITE_FLOAT:
            return .real(statement.columnDouble(index))
        case SQLITE_TEXT:
            return .text(statement.columnText(index) ?? "")
        case SQLITE_BLOB:
            return .blob(statement.columnBlob(index) ?? Data())
        default:
            return .null
        }
    }

    static func bind(_ values: [String], to statement: SQLiteStatement) throws {
        for (offset, value) in values.enumerated() {
            try statement.bind(Int32(offset + 1), value)
        }
    }

    static func bind(
        _ value: AgentThreadRelationalSnapshot.Value,
        at index: Int32,
        to statement: SQLiteStatement
    ) throws {
        switch value {
        case .null: try statement.bind(index, Optional<String>.none)
        case .integer(let value): try statement.bind(index, value)
        case .real(let value): try statement.bind(index, value)
        case .text(let value): try statement.bind(index, value)
        case .blob(let value): try statement.bind(index, value)
        }
    }

    static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    static func forkIntentPredicate(_ threadCount: Int) -> String {
        let values = placeholders(threadCount)
        return "source_thread_id IN (\(values)) OR child_thread_id IN (\(values))"
    }
}
